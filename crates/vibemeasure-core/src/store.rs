use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::{
    Result,
    model::{
        CurrencyRate, LimitWindow, PricingRule, SourceMeta, UsageEvent, UsageSummary, WindowKind,
    },
};

pub struct VibeStore {
    connection: Connection,
}

impl VibeStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path)?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub fn open_memory() -> Result<Self> {
        let connection = Connection::open_in_memory()?;
        let store = Self { connection };
        store.migrate()?;
        Ok(store)
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

    pub fn usage_between(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Result<Vec<UsageEvent>> {
        let mut statement = self.connection.prepare(
            r#"
            SELECT tool_id, occurred_at, model_name, input_tokens, cached_input_tokens,
                   output_tokens, reasoning_output_tokens, total_tokens, source_json
            FROM usage_events
            WHERE occurred_at >= ?1 AND occurred_at < ?2
            ORDER BY occurred_at ASC
            "#,
        )?;
        let rows = statement.query_map(params![start.to_rfc3339(), end.to_rfc3339()], |row| {
            Ok(UsageEvent {
                tool_id: row.get(0)?,
                occurred_at: parse_rfc3339(row.get::<_, String>(1)?),
                model_name: row.get(2)?,
                input_tokens: row_u64(row, 3)?,
                cached_input_tokens: row_u64(row, 4)?,
                output_tokens: row_u64(row, 5)?,
                reasoning_output_tokens: row_u64(row, 6)?,
                total_tokens: row_u64(row, 7)?,
                source: serde_json::from_str::<SourceMeta>(&row.get::<_, String>(8)?)
                    .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?,
            })
        })?;

        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(Into::into)
    }

    pub fn latest_limit_windows(&self) -> Result<Vec<LimitWindow>> {
        let mut statement = self.connection.prepare(
            r#"
            SELECT tool_id, window_kind_json, starts_at, ends_at, reset_at, used_percent,
                   used_tokens, token_limit, source_json
            FROM limit_windows
            WHERE id IN (
                SELECT MAX(id) FROM limit_windows GROUP BY tool_id, window_kind_json
            )
            ORDER BY tool_id ASC, reset_at ASC
            "#,
        )?;
        let rows = statement.query_map([], |row| {
            Ok(LimitWindow {
                tool_id: row.get(0)?,
                window_kind: serde_json::from_str::<WindowKind>(&row.get::<_, String>(1)?)
                    .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?,
                starts_at: parse_rfc3339(row.get::<_, String>(2)?),
                ends_at: parse_rfc3339(row.get::<_, String>(3)?),
                reset_at: parse_rfc3339(row.get::<_, String>(4)?),
                used_percent: row.get(5)?,
                used_tokens: row_optional_u64(row, 6)?,
                token_limit: row_optional_u64(row, 7)?,
                source: serde_json::from_str::<SourceMeta>(&row.get::<_, String>(8)?)
                    .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?,
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

fn parse_rfc3339(value: String) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(&value)
        .expect("timestamps written by VibeStore are RFC3339")
        .with_timezone(&Utc)
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
    use chrono::{TimeZone, Utc};

    use crate::{
        model::{SourceMeta, UsageEvent},
        store::VibeStore,
    };

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
