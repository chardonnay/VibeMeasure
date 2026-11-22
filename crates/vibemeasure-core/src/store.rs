use std::{collections::HashMap, path::Path};

use chrono::{DateTime, Utc};
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Row, Transaction, TransactionBehavior, params,
};

use crate::{
    Result,
    adapters::AdapterOutput,
    model::{CurrencyRate, LimitWindow, PricingRule, ProviderPlan, UsageEvent, UsageSummary},
};

pub struct VibeStore {
    connection: Connection,
}

impl VibeStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path)?;
        Self::from_connection(connection)
    }

    pub fn open_existing(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        Self::from_connection(connection)
    }

    fn from_connection(connection: Connection) -> Result<Self> {
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub fn open_memory() -> Result<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    pub fn migrate(&self) -> Result<()> {
        self.connection.execute_batch(
            r#"
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS usage_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool_id TEXT NOT NULL,
                occurred_at TEXT NOT NULL,
                model_name TEXT,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                source_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_usage_events_time
                ON usage_events (occurred_at, tool_id);

            CREATE TABLE IF NOT EXISTS limit_windows (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool_id TEXT NOT NULL,
                window_kind_json TEXT NOT NULL,
                starts_at TEXT NOT NULL,
                ends_at TEXT NOT NULL,
                reset_at TEXT NOT NULL,
                used_percent REAL,
                used_tokens INTEGER,
                token_limit INTEGER,
                source_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_limit_windows_latest
                ON limit_windows (tool_id, reset_at);
            CREATE INDEX IF NOT EXISTS idx_limit_windows_observation
                ON limit_windows (tool_id, reset_at, source_json);

            CREATE TABLE IF NOT EXISTS codex_import_records (
                session_key TEXT NOT NULL,
                record_kind TEXT NOT NULL,
                measurement TEXT NOT NULL,
                occurrence INTEGER NOT NULL,
                target_id INTEGER NOT NULL,
                PRIMARY KEY (session_key, record_kind, measurement, occurrence),
                UNIQUE (record_kind, target_id)
            ) WITHOUT ROWID;

            CREATE VIEW IF NOT EXISTS reportable_usage_events AS
                SELECT e.* FROM usage_events e
                WHERE NOT EXISTS (
                    SELECT 1 FROM codex_import_records r
                    WHERE r.record_kind='superseded_usage' AND r.target_id=e.id
                );

            CREATE TABLE IF NOT EXISTS pricing_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tool_id TEXT NOT NULL,
                provider_name TEXT NOT NULL,
                model_name TEXT,
                input_per_million_usd REAL,
                cached_input_per_million_usd REAL,
                output_per_million_usd REAL,
                billing_window_json TEXT,
                source_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS currency_rates (
                base_currency TEXT NOT NULL,
                quote_currency TEXT NOT NULL,
                rate REAL NOT NULL,
                source_json TEXT NOT NULL,
                PRIMARY KEY (base_currency, quote_currency)
            );

            CREATE TABLE IF NOT EXISTS app_settings (
                key TEXT PRIMARY KEY,
                value_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS widget_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                generated_at TEXT NOT NULL,
                snapshot_json TEXT NOT NULL
            );
            "#,
        )?;
        Ok(())
    }

    pub fn insert_usage_event(&self, event: &UsageEvent) -> Result<()> {
        let input_tokens = i64_from_u64("input_tokens", event.input_tokens)?;
        let cached_input_tokens = i64_from_u64("cached_input_tokens", event.cached_input_tokens)?;
        let output_tokens = i64_from_u64("output_tokens", event.output_tokens)?;
        let reasoning_output_tokens =
            i64_from_u64("reasoning_output_tokens", event.reasoning_output_tokens)?;
        let total_tokens = i64_from_u64("total_tokens", event.total_tokens)?;

        self.connection.execute(
            r#"
            INSERT INTO usage_events (
                tool_id, occurred_at, model_name, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens, source_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                event.tool_id,
                event.occurred_at.to_rfc3339(),
                event.model_name,
                input_tokens,
                cached_input_tokens,
                output_tokens,
                reasoning_output_tokens,
                total_tokens,
                serde_json::to_string(&event.source)?,
            ],
        )?;
        Ok(())
    }

    pub fn insert_limit_window(&self, window: &LimitWindow) -> Result<()> {
        let used_tokens = optional_i64_from_u64("used_tokens", window.used_tokens)?;
        let token_limit = optional_i64_from_u64("token_limit", window.token_limit)?;

        self.connection.execute(
            r#"
            INSERT INTO limit_windows (
                tool_id, window_kind_json, starts_at, ends_at, reset_at, used_percent,
                used_tokens, token_limit, source_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                window.tool_id,
                serde_json::to_string(&window.window_kind)?,
                window.starts_at.to_rfc3339(),
                window.ends_at.to_rfc3339(),
                window.reset_at.to_rfc3339(),
                window.used_percent,
                used_tokens,
                token_limit,
                serde_json::to_string(&window.source)?,
            ],
        )?;
        Ok(())
    }

    /// One file contributes either all its new measurements or none. Session identity keeps
    /// simultaneous requests in independent rollouts distinct, including copied rollout files.
    pub fn import_codex_session(
        &self,
        session_key: &str,
        output: &AdapterOutput,
    ) -> Result<(usize, usize)> {
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)?;
        let mut usage_occurrences = HashMap::new();
        let mut window_occurrences = HashMap::new();
        let mut added_events = 0;
        let mut added_windows = 0;

        for event in &output.usage_events {
            let key = usage_measurement_key(event)?;
            added_events +=
                self.import_record(session_key, "usage", key, &mut usage_occurrences, || {
                    self.store_imported_usage(event).map(Some)
                })?;
        }

        for window in &output.limit_windows {
            let key = serde_json::to_string(&(
                &window.window_kind,
                window.source.fetched_at,
                window.starts_at,
                window.ends_at,
                window.reset_at,
                window.used_percent,
                window.used_tokens,
                window.token_limit,
            ))?;
            added_windows +=
                self.import_record(session_key, "window", key, &mut window_occurrences, || {
                    self.store_imported_window(window).map(Some)
                })?;
        }
        // Repeated cumulative counters were originally saved as new usage. Hide exactly
        // the legacy rows corroborated by this rollout, while retaining them for audit.
        let mut superseded_occurrences = HashMap::new();
        for event in &output.superseded_usage {
            self.import_record(
                session_key,
                "superseded_usage",
                usage_measurement_key(event)?,
                &mut superseded_occurrences,
                || Ok(self.legacy_usage_id(event)?.map(|id| (id, false))),
            )?;
        }
        if let Some(plan) = &output.reported_plan {
            let key = "plan.reported.codex";
            let previous: Option<ProviderPlan> = self.load_setting(key)?;
            if previous.is_none_or(|current| current.source.fetched_at < plan.source.fetched_at) {
                self.save_setting(key, plan)?;
            }
        }
        transaction.commit()?;
        Ok((added_events, added_windows))
    }

    fn legacy_usage_id(&self, event: &UsageEvent) -> Result<Option<i64>> {
        let total = i64_from_u64("total_tokens", event.total_tokens)?;
        let old_sum = event
            .input_tokens
            .checked_add(event.cached_input_tokens)
            .and_then(|v| v.checked_add(event.output_tokens))
            .and_then(|v| v.checked_add(event.reasoning_output_tokens))
            .and_then(|v| i64::try_from(v).ok());
        // Older imports sometimes added cached and reasoning tokens to their parent counters.
        // Adopt at most one unclaimed row with the same observed counters, time and provenance.
        let mut legacy = self.connection.prepare_cached(
            "SELECT e.id FROM usage_events e WHERE tool_id=?1 AND occurred_at=?2
             AND (model_name IS NULL OR model_name IS ?3) AND input_tokens=?4
             AND cached_input_tokens=?5 AND output_tokens=?6 AND reasoning_output_tokens=?7
             AND (total_tokens=?8 OR total_tokens=?9) AND source_json=?10
             AND NOT EXISTS (
                 SELECT 1 FROM codex_import_records r WHERE r.record_kind IN ('usage', 'superseded_usage') AND r.target_id=e.id
             )
             ORDER BY e.id LIMIT 1"
        )?;
        let id: Option<i64> = legacy
            .query_row(
                params![
                    event.tool_id,
                    event.occurred_at.to_rfc3339(),
                    event.model_name,
                    i64_from_u64("input_tokens", event.input_tokens)?,
                    i64_from_u64("cached_input_tokens", event.cached_input_tokens)?,
                    i64_from_u64("output_tokens", event.output_tokens)?,
                    i64_from_u64("reasoning_output_tokens", event.reasoning_output_tokens)?,
                    total,
                    old_sum,
                    serde_json::to_string(&event.source)?,
                ],
                |row| row.get(0),
            )
            .optional()?;
        Ok(id)
    }

    fn store_imported_usage(&self, event: &UsageEvent) -> Result<(i64, bool)> {
        let total = i64_from_u64("total_tokens", event.total_tokens)?;
        let id = self.legacy_usage_id(event)?;
        if let Some(id) = id {
            self.connection.execute(
                "UPDATE usage_events SET total_tokens=?1, model_name=?2 WHERE id=?3",
                params![total, event.model_name, id],
            )?;
            return Ok((id, false));
        }
        self.insert_usage_event(event)?;
        Ok((self.connection.last_insert_rowid(), true))
    }

    fn store_imported_window(&self, window: &LimitWindow) -> Result<(i64, bool)> {
        let mut legacy = self.connection.prepare_cached(
            "SELECT w.id FROM limit_windows w WHERE tool_id=?1 AND window_kind_json=?2
             AND starts_at=?3 AND ends_at=?4 AND reset_at=?5 AND used_percent IS ?6
             AND used_tokens IS ?7 AND token_limit IS ?8 AND source_json=?9
             AND NOT EXISTS (
                 SELECT 1 FROM codex_import_records r WHERE r.record_kind='window' AND r.target_id=w.id
             )
             ORDER BY w.id LIMIT 1"
        )?;
        let id: Option<i64> = legacy
            .query_row(
                params![
                    window.tool_id,
                    serde_json::to_string(&window.window_kind)?,
                    window.starts_at.to_rfc3339(),
                    window.ends_at.to_rfc3339(),
                    window.reset_at.to_rfc3339(),
                    window.used_percent,
                    optional_i64_from_u64("used_tokens", window.used_tokens)?,
                    optional_i64_from_u64("token_limit", window.token_limit)?,
                    serde_json::to_string(&window.source)?,
                ],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(id) = id {
            return Ok((id, false));
        }
        self.insert_limit_window(window)?;
        Ok((self.connection.last_insert_rowid(), true))
    }

    fn import_record(
        &self,
        session: &str,
        kind: &str,
        measurement: String,
        occurrences: &mut HashMap<String, i64>,
        write: impl FnOnce() -> Result<Option<(i64, bool)>>,
    ) -> Result<usize> {
        let occurrence = occurrences.entry(measurement.clone()).or_default();
        *occurrence += 1;
        let key = params![session, kind, measurement, *occurrence];
        if self
            .connection
            .prepare_cached(
                "SELECT 1 FROM codex_import_records
                WHERE session_key=?1 AND record_kind=?2 AND measurement=?3 AND occurrence=?4",
            )?
            .exists(key)?
        {
            return Ok(0);
        }
        let Some((id, added)) = write()? else {
            return Ok(0);
        };
        self.connection
            .prepare_cached(
                "INSERT INTO codex_import_records
            (session_key, record_kind, measurement, occurrence, target_id) VALUES (?1,?2,?3,?4,?5)",
            )?
            .execute(params![session, kind, measurement, *occurrence, id])?;
        Ok(usize::from(added))
    }

    pub fn save_currency_rate(&self, rate: &CurrencyRate) -> Result<()> {
        self.connection.execute(
            r#"
            INSERT INTO currency_rates (base_currency, quote_currency, rate, source_json)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(base_currency, quote_currency)
            DO UPDATE SET rate = excluded.rate, source_json = excluded.source_json
            "#,
            params![
                rate.base_currency,
                rate.quote_currency,
                rate.rate,
                serde_json::to_string(&rate.source)?,
            ],
        )?;
        Ok(())
    }

    pub fn save_pricing_rule(&self, rule: &PricingRule) -> Result<()> {
        self.connection.execute(
            r#"
            INSERT INTO pricing_rules (
                tool_id, provider_name, model_name, input_per_million_usd,
                cached_input_per_million_usd, output_per_million_usd,
                billing_window_json, source_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
            params![
                rule.tool_id,
                rule.provider_name,
                rule.model_name,
                rule.input_per_million_usd,
                rule.cached_input_per_million_usd,
                rule.output_per_million_usd,
                rule.billing_window
                    .as_ref()
                    .map(serde_json::to_string)
                    .transpose()?,
                serde_json::to_string(&rule.source)?,
            ],
        )?;
        Ok(())
    }

    pub fn report_pricing(&self) -> Result<(Vec<PricingRule>, Vec<CurrencyRate>)> {
        let mut statement = self.connection.prepare(
            "SELECT tool_id, provider_name, model_name, input_per_million_usd, cached_input_per_million_usd,
                    output_per_million_usd, billing_window_json, source_json FROM pricing_rules ORDER BY id DESC")?;
        let rules = statement
            .query_map([], |row| {
                Ok(PricingRule {
                    tool_id: row.get(0)?,
                    provider_name: row.get(1)?,
                    model_name: row.get(2)?,
                    input_per_million_usd: row.get(3)?,
                    cached_input_per_million_usd: row.get(4)?,
                    output_per_million_usd: row.get(5)?,
                    billing_window: row
                        .get::<_, Option<String>>(6)?
                        .map(|json| parse_json(6, &json))
                        .transpose()?,
                    source: parse_json(7, &row.get::<_, String>(7)?)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut statement = self.connection.prepare(
            "SELECT base_currency, quote_currency, rate, source_json FROM currency_rates ORDER BY base_currency, quote_currency")?;
        let rates = statement
            .query_map([], |row| {
                Ok(CurrencyRate {
                    base_currency: row.get(0)?,
                    quote_currency: row.get(1)?,
                    rate: row.get(2)?,
                    source: parse_json(3, &row.get::<_, String>(3)?)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok((rules, rates))
    }

    pub fn save_setting<T: serde::Serialize>(&self, key: &str, value: &T) -> Result<()> {
        self.connection.execute(
            r#"
            INSERT INTO app_settings (key, value_json)
            VALUES (?1, ?2)
            ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
            "#,
            params![key, serde_json::to_string(value)?],
        )?;
        Ok(())
    }

    pub fn load_setting<T: serde::de::DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let raw: Option<String> = self
            .connection
            .query_row(
                "SELECT value_json FROM app_settings WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()?;
        raw.map(|value| serde_json::from_str(&value))
            .transpose()
            .map_err(Into::into)
    }

    pub fn save_manual_plan(&self, tool_id: &str, plan: &ProviderPlan) -> Result<()> {
        self.save_setting(&format!("plan.manual.{tool_id}"), plan)
    }

    pub fn provider_plan(&self, tool_id: &str, now: DateTime<Utc>) -> Result<Option<ProviderPlan>> {
        let reported: Option<ProviderPlan> =
            self.load_setting(&format!("plan.reported.{tool_id}"))?;
        if let Some(plan) = reported.filter(|plan| plan.source.fetched_at <= now) {
            return Ok(Some(plan));
        }
        self.load_setting(&format!("plan.manual.{tool_id}"))
    }

    pub fn usage_between(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<UsageEvent>> {
        let mut statement = self.connection.prepare(
            r#"
            SELECT tool_id, occurred_at, model_name, input_tokens, cached_input_tokens,
                   output_tokens, reasoning_output_tokens, total_tokens, source_json
            FROM reportable_usage_events
            WHERE occurred_at >= ?1 AND occurred_at < ?2
            ORDER BY occurred_at ASC
            "#,
        )?;
        let rows = statement.query_map(params![start.to_rfc3339(), end.to_rfc3339()], |row| {
            Ok(UsageEvent {
                tool_id: row.get(0)?,
                occurred_at: row_datetime(row, 1)?,
                model_name: row.get(2)?,
                input_tokens: row_u64(row, 3)?,
                cached_input_tokens: row_u64(row, 4)?,
                output_tokens: row_u64(row, 5)?,
                reasoning_output_tokens: row_u64(row, 6)?,
                total_tokens: row_u64(row, 7)?,
                source: parse_json(8, &row.get::<_, String>(8)?)?,
            })
        })?;

        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(Into::into)
    }

    pub fn latest_limit_windows(&self) -> Result<Vec<LimitWindow>> {
        self.limit_windows_at(None)
    }

    pub fn active_limit_windows_at(&self, at: DateTime<Utc>) -> Result<Vec<LimitWindow>> {
        self.limit_windows_at(Some(at))
    }

    fn limit_windows_at(&self, at: Option<DateTime<Utc>>) -> Result<Vec<LimitWindow>> {
        let mut statement = self.connection.prepare(
            r#"
            WITH observations AS (
                SELECT *, rtrim(json_extract(source_json, '$.fetched_at'), 'Z') AS observed_at
                FROM limit_windows
            ), ranked AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY tool_id, window_kind_json ORDER BY observed_at DESC, id DESC
                ) AS rank FROM observations
                WHERE ?1 IS NULL OR (
                    starts_at <= ?1 AND ends_at > ?1 AND reset_at > ?1 AND observed_at <= ?2
                )
            )
            SELECT tool_id, window_kind_json, starts_at, ends_at, reset_at, used_percent,
                   used_tokens, token_limit, source_json
            FROM ranked WHERE rank = 1
            ORDER BY tool_id ASC, reset_at ASC
            "#,
        )?;
        let observed_until = at.map(|t| t.naive_utc().format("%Y-%m-%dT%H:%M:%S%.f").to_string());
        let rows =
            statement.query_map(params![at.map(|t| t.to_rfc3339()), observed_until], |row| {
                Ok(LimitWindow {
                    tool_id: row.get(0)?,
                    window_kind: parse_json(1, &row.get::<_, String>(1)?)?,
                    starts_at: row_datetime(row, 2)?,
                    ends_at: row_datetime(row, 3)?,
                    reset_at: row_datetime(row, 4)?,
                    used_percent: row.get(5)?,
                    used_tokens: row_optional_u64(row, 6)?,
                    token_limit: row_optional_u64(row, 7)?,
                    source: parse_json(8, &row.get::<_, String>(8)?)?,
                })
            })?;

        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(Into::into)
    }

    pub fn aggregate_usage(events: &[UsageEvent], tool_id: &str) -> UsageSummary {
        let mut summary = UsageSummary {
            tool_id: tool_id.to_string(),
            input_tokens: 0,
            cached_input_tokens: 0,
            output_tokens: 0,
            reasoning_output_tokens: 0,
            total_tokens: 0,
            source_labels: Vec::new(),
        };

        for event in events.iter().filter(|event| event.tool_id == tool_id) {
            summary.input_tokens += event.input_tokens;
            summary.cached_input_tokens += event.cached_input_tokens;
            summary.output_tokens += event.output_tokens;
            summary.reasoning_output_tokens += event.reasoning_output_tokens;
            summary.total_tokens += event.total_tokens;
            if !summary.source_labels.contains(&event.source.label) {
                summary.source_labels.push(event.source.label.clone());
            }
        }

        summary
    }
}

fn usage_measurement_key(event: &UsageEvent) -> Result<String> {
    Ok(serde_json::to_string(&(
        event.occurred_at,
        event.input_tokens,
        event.cached_input_tokens,
        event.output_tokens,
        event.reasoning_output_tokens,
        event.total_tokens,
    ))?)
}

fn parse_json<T: serde::de::DeserializeOwned>(column: usize, json: &str) -> rusqlite::Result<T> {
    serde_json::from_str(json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn row_datetime(row: &Row<'_>, index: usize) -> rusqlite::Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(&row.get::<_, String>(index)?)
        .map(|time| time.with_timezone(&Utc))
        .map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                index,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })
}

fn i64_from_u64(label: &str, value: u64) -> Result<i64> {
    i64::try_from(value)
        .map_err(|_| crate::VibeError::InvalidData(format!("{label} exceeds SQLite INTEGER range")))
}

fn optional_i64_from_u64(label: &str, value: Option<u64>) -> Result<Option<i64>> {
    value.map(|value| i64_from_u64(label, value)).transpose()
}

fn row_u64(row: &Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value = row.get::<_, i64>(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}

fn row_optional_u64(row: &Row<'_>, index: usize) -> rusqlite::Result<Option<u64>> {
    let value = row.get::<_, Option<i64>>(index)?;
    value
        .map(|value| {
            u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use chrono::{Duration, TimeZone, Utc};

    use crate::{
        adapters::{AdapterOutput, codex::parse_codex_jsonl},
        model::{SourceMeta, UsageEvent},
        store::VibeStore,
    };

    fn session() -> AdapterOutput {
        parse_codex_jsonl(Path::new("../../tests/fixtures/codex/token_count.jsonl")).unwrap()
    }

    fn row_counts(store: &VibeStore) -> (i64, i64, i64) {
        store
            .connection
            .query_row(
                "SELECT (SELECT COUNT(*) FROM usage_events), (SELECT COUNT(*) FROM limit_windows),
                    (SELECT COUNT(*) FROM codex_import_records)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap()
    }

    #[test]
    fn failed_import_rolls_back_new_measurements_and_identity_records() {
        let store = VibeStore::open_memory().unwrap();
        let mut data = session();
        data.limit_windows[1].token_limit = Some(u64::MAX);
        assert!(store.import_codex_session("a", &data).is_err());
        assert_eq!(row_counts(&store), (0, 0, 0));
        assert_eq!(store.import_codex_session("a", &session()).unwrap(), (1, 2));
        assert_eq!(row_counts(&store), (1, 2, 3));
    }

    #[test]
    fn identical_measurements_keep_multiplicity_within_and_across_sessions() {
        let store = VibeStore::open_memory().unwrap();
        let mut data = session();
        data.usage_events.push(data.usage_events[0].clone());
        assert_eq!(store.import_codex_session("a", &data).unwrap(), (2, 2));
        assert_eq!(store.import_codex_session("a", &data).unwrap(), (0, 0));
        assert_eq!(store.import_codex_session("b", &data).unwrap(), (2, 2));
        assert_eq!(row_counts(&store), (4, 4, 8));
    }

    #[test]
    fn reimport_adopts_matching_legacy_rows_and_preserves_unattributed_history() {
        let store = VibeStore::open_memory().unwrap();
        let data = session();
        let mut legacy = data.usage_events[0].clone();
        legacy.model_name = None;
        legacy.total_tokens = legacy.input_tokens
            + legacy.cached_input_tokens
            + legacy.output_tokens
            + legacy.reasoning_output_tokens;
        store.insert_usage_event(&legacy).unwrap();
        let mut unrelated = legacy.clone();
        unrelated.occurred_at -= Duration::days(1);
        store.insert_usage_event(&unrelated).unwrap();
        store.insert_limit_window(&data.limit_windows[0]).unwrap();
        assert_eq!(store.import_codex_session("a", &data).unwrap(), (0, 1));
        assert_eq!(store.import_codex_session("a", &data).unwrap(), (0, 0));
        let events = store
            .usage_between(
                unrelated.occurred_at,
                legacy.occurred_at + Duration::seconds(1),
            )
            .unwrap();
        assert_eq!(events, vec![unrelated, data.usage_events[0].clone()]);
        assert_eq!(row_counts(&store), (2, 2, 3));
    }

    #[test]
    fn snapshots_use_measurement_time_and_skip_expired_or_future_windows() {
        let store = VibeStore::open_memory().unwrap();
        let mut newer = session().limit_windows.remove(0);
        let at = newer.source.fetched_at + Duration::hours(1);
        newer.starts_at = at - Duration::hours(2);
        newer.ends_at = at + Duration::hours(3);
        newer.reset_at = newer.ends_at;
        newer.used_percent = Some(46.0);
        newer.source.fetched_at += Duration::microseconds(1);
        let mut older = newer.clone();
        older.source.fetched_at -= Duration::microseconds(1);
        older.used_percent = Some(30.0);
        store.insert_limit_window(&newer).unwrap();
        store.insert_limit_window(&older).unwrap();
        let mut future = newer.clone();
        future.source.fetched_at = at + Duration::milliseconds(1);
        store.insert_limit_window(&future).unwrap();
        assert_eq!(store.latest_limit_windows().unwrap(), vec![future]);
        assert_eq!(
            store.active_limit_windows_at(at).unwrap(),
            vec![newer.clone()]
        );
        assert!(
            store
                .active_limit_windows_at(newer.reset_at)
                .unwrap()
                .is_empty()
        );
        assert!(
            store
                .active_limit_windows_at(newer.starts_at - Duration::seconds(1))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn excludes_only_corroborated_legacy_replays_without_deleting_history() {
        let store = VibeStore::open_memory().unwrap();
        let mut data = session();
        let mut replay = data.usage_events[0].clone();
        replay.occurred_at += Duration::seconds(1);
        replay.source.fetched_at = replay.occurred_at;
        replay.model_name = None;
        replay.total_tokens = 155;
        data.superseded_usage.push(replay.clone());
        store.insert_usage_event(&replay).unwrap();
        store.insert_usage_event(&replay).unwrap();
        assert_eq!(store.import_codex_session("a", &data).unwrap(), (1, 2));
        assert_eq!(store.import_codex_session("a", &data).unwrap(), (0, 0));
        assert_eq!(row_counts(&store), (3, 2, 4));
        let events = store
            .usage_between(
                data.usage_events[0].occurred_at,
                replay.occurred_at + Duration::seconds(1),
            )
            .unwrap();
        assert_eq!(events, vec![data.usage_events[0].clone(), replay]);
    }

    #[test]
    fn stores_and_aggregates_usage_events() {
        let store = VibeStore::open_memory().unwrap();
        let now = Utc.with_ymd_and_hms(2026, 6, 1, 10, 0, 0).single().unwrap();
        store
            .insert_usage_event(&UsageEvent {
                tool_id: "codex".to_string(),
                occurred_at: now,
                model_name: None,
                input_tokens: 10,
                cached_input_tokens: 2,
                output_tokens: 3,
                reasoning_output_tokens: 1,
                total_tokens: 16,
                source: SourceMeta::local("test double", now),
            })
            .unwrap();

        let events = store
            .usage_between(
                Utc.with_ymd_and_hms(2026, 6, 1, 9, 0, 0).single().unwrap(),
                Utc.with_ymd_and_hms(2026, 6, 1, 11, 0, 0).single().unwrap(),
            )
            .unwrap();
        let summary = VibeStore::aggregate_usage(&events, "codex");

        assert_eq!(summary.total_tokens, 16);
        assert_eq!(summary.source_labels, vec!["test double"]);
    }
}
