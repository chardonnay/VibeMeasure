use std::{
    fs::File,
    io::{BufRead, BufReader},
    path::Path,
};

use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;
use serde_json::Value;

use crate::{
    Result, VibeError,
    adapters::{AdapterOutput, ProviderAdapter},
    model::{LimitWindow, SourceMeta, UsageEvent},
    windows::infer_window_kind_from_minutes,
};

#[derive(Clone, Debug, Default)]
pub struct CodexAdapter;

impl ProviderAdapter for CodexAdapter {
    fn tool_id(&self) -> &'static str {
        "codex"
    }

    fn collect_from_path(&self, path: &Path) -> Result<AdapterOutput> {
        parse_codex_jsonl(path)
    }
}

pub fn parse_codex_jsonl(path: &Path) -> Result<AdapterOutput> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let mut output = AdapterOutput::default();
    let mut usage_tracker = UsageTracker::default();
    let mut model_name = None;

    for (line_index, line) in reader.lines().enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let value: Value = serde_json::from_str(&line).map_err(|error| {
            VibeError::InvalidData(format!(
                "invalid Codex JSONL on line {}: {error}",
                line_index + 1
            ))
        })?;

        match value.get("type").and_then(Value::as_str) {
            Some("session_meta") if output.session_id.is_none() => {
                output.session_id = value
                    .pointer("/payload/id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.is_empty())
                    .map(str::to_owned);
            }
            Some("turn_context") => {
                model_name = value
                    .pointer("/payload/model")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
            }
            _ => {}
        }
        if value.pointer("/payload/type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }

        let occurred_at = parse_event_timestamp(&value)?;
        let source = SourceMeta::local("Codex CLI session JSONL token_count event", occurred_at);
        let last = TokenUsage::parse(value.pointer("/payload/info/last_token_usage"))?;
        let cumulative = TokenUsage::parse(value.pointer("/payload/info/total_token_usage"))?;
        let usage = usage_tracker.increment(last, cumulative)?;
        if let Some(legacy) = last.and_then(|last| last.superseded_by(usage)) {
            output.superseded_usage.push(legacy.event(None, &source));
        }
        if let Some(usage) = usage {
            output
                .usage_events
                .push(usage.event(model_name.clone(), &source));
        }

        for limit_name in ["primary", "secondary"] {
            if let Some(window) = parse_limit_window(&value, limit_name, source.clone())? {
                output.limit_windows.push(window);
            }
        }
    }

    Ok(output)
}

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(default)]
struct TokenUsage {
    input_tokens: u64,
    cached_input_tokens: u64,
    output_tokens: u64,
    reasoning_output_tokens: u64,
    total_tokens: u64,
}

impl TokenUsage {
    fn event(self, model_name: Option<String>, source: &SourceMeta) -> UsageEvent {
        UsageEvent {
            tool_id: "codex".to_string(),
            occurred_at: source.fetched_at,
            model_name,
            input_tokens: self.input_tokens,
            cached_input_tokens: self.cached_input_tokens,
            output_tokens: self.output_tokens,
            reasoning_output_tokens: self.reasoning_output_tokens,
            total_tokens: self.total_tokens,
            source: source.clone(),
        }
    }

    fn parse(value: Option<&Value>) -> Result<Option<Self>> {
        let Some(value) = value.filter(|value| !value.is_null()) else {
            return Ok(None);
        };
        let mut usage = Self::deserialize(value)?;
        if value.get("total_tokens").is_none() {
            // Cached input and reasoning output are subsets of their respective totals.
            usage.total_tokens = usage
                .input_tokens
                .checked_add(usage.output_tokens)
                .ok_or_else(|| VibeError::InvalidData("Codex token total exceeds u64".into()))?;
        }
        Ok(Some(usage))
    }

    fn combine(self, other: Self, op: fn(u64, u64) -> Option<u64>) -> Option<Self> {
        Some(Self {
            input_tokens: op(self.input_tokens, other.input_tokens)?,
            cached_input_tokens: op(self.cached_input_tokens, other.cached_input_tokens)?,
            output_tokens: op(self.output_tokens, other.output_tokens)?,
            reasoning_output_tokens: op(
                self.reasoning_output_tokens,
                other.reasoning_output_tokens,
            )?,
            total_tokens: op(self.total_tokens, other.total_tokens)?,
        })
    }

    fn components(self) -> [u64; 4] {
        [
            self.input_tokens,
            self.cached_input_tokens,
            self.output_tokens,
            self.reasoning_output_tokens,
        ]
    }

    fn superseded_by(self, replacement: Option<Self>) -> Option<Self> {
        // Reconstruct exactly the measurement written by the old last-usage parser.
        let components = self.components();
        let legacy_sum = components.into_iter().try_fold(0, u64::checked_add)?;
        let total_tokens = self.total_tokens.max(legacy_sum);
        if total_tokens == 0 || total_tokens > i64::MAX as u64 {
            return None;
        }
        if replacement.is_some_and(|new| {
            new.components() == components
                && (new.total_tokens == total_tokens || legacy_sum == total_tokens)
        }) {
            // The regular import can adopt this row and correct its total in place.
            return None;
        }
        Some(Self {
            total_tokens,
            ..self
        })
    }
}

#[derive(Default)]
struct UsageTracker {
    accounted: TokenUsage,
    saw_cumulative: bool,
}

impl UsageTracker {
    fn increment(
        &mut self,
        last: Option<TokenUsage>,
        cumulative: Option<TokenUsage>,
    ) -> Result<Option<TokenUsage>> {
        let usage = match (cumulative, last) {
            (Some(current), last) => {
                let previous = std::mem::replace(&mut self.accounted, current);
                let first_snapshot = !self.saw_cumulative;
                self.saw_cumulative = true;
                let delta = current.total_tokens.checked_sub(previous.total_tokens);
                if delta == Some(0) {
                    // A rate-limit update can rebroadcast the last nonzero usage unchanged.
                    None
                } else if last
                    .is_some_and(|last| first_snapshot || Some(last.total_tokens) == delta)
                {
                    // A partial log may begin with a total that includes earlier turns.
                    last
                } else if let Some(total_tokens) = delta {
                    // Older snapshots may omit the breakdown. Keep the provider's delta
                    // even when its category counters cannot be differenced reliably.
                    let measured = current.combine(previous, u64::checked_sub).filter(|usage| {
                        usage
                            .input_tokens
                            .checked_add(usage.output_tokens)
                            .is_some_and(|sum| sum <= total_tokens)
                    });
                    Some(measured.unwrap_or(TokenUsage {
                        total_tokens,
                        ..Default::default()
                    }))
                } else {
                    last
                }
            }
            (None, Some(last)) => {
                // Include legacy last-only records in the baseline for the next cumulative delta.
                self.accounted =
                    self.accounted
                        .combine(last, u64::checked_add)
                        .ok_or_else(|| {
                            VibeError::InvalidData("Codex token total exceeds u64".into())
                        })?;
                Some(last)
            }
            (None, None) => None,
        };
        Ok(usage.filter(|usage| usage.total_tokens > 0))
    }
}

fn parse_event_timestamp(value: &Value) -> Result<DateTime<Utc>> {
    let raw = value
        .get("timestamp")
        .and_then(Value::as_str)
        .ok_or_else(|| VibeError::InvalidData("Codex event missing timestamp".into()))?;
    DateTime::parse_from_rfc3339(raw)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| VibeError::InvalidData(format!("invalid Codex timestamp: {error}")))
}

fn parse_limit_window(
    value: &Value,
    limit_name: &str,
    source: SourceMeta,
) -> Result<Option<LimitWindow>> {
    let base = format!("/payload/rate_limits/{limit_name}");
    let Some(window_minutes) = value
        .pointer(&format!("{base}/window_minutes"))
        .and_then(Value::as_i64)
    else {
        return Ok(None);
    };
    let Some(resets_at) = value
        .pointer(&format!("{base}/resets_at"))
        .and_then(Value::as_i64)
    else {
        return Ok(None);
    };

    let reset_at = Utc.timestamp_opt(resets_at, 0).single().ok_or_else(|| {
        VibeError::InvalidData(format!("invalid Codex {limit_name} reset timestamp"))
    })?;
    let starts_at = chrono::Duration::try_minutes(window_minutes)
        .filter(|duration| *duration > chrono::Duration::zero())
        .and_then(|duration| reset_at.checked_sub_signed(duration))
        .ok_or_else(|| {
            VibeError::InvalidData(format!("invalid Codex {limit_name} window duration"))
        })?;
    let used_percent = value
        .pointer(&format!("{base}/used_percent"))
        .and_then(Value::as_f64);

    Ok(Some(LimitWindow {
        tool_id: "codex".to_string(),
        window_kind: infer_window_kind_from_minutes(window_minutes),
        starts_at,
        ends_at: reset_at,
        reset_at,
        used_percent,
        used_tokens: None,
        token_limit: None,
        source,
    }))
}

#[cfg(test)]
mod tests {
    use std::{io::Write, path::Path};

    use serde_json::{Value, json};
    use tempfile::NamedTempFile;

    use crate::model::WindowKind;

    use super::{AdapterOutput, parse_codex_jsonl};

    fn parse_events(events: &[Value]) -> AdapterOutput {
        let mut file = NamedTempFile::new().unwrap();
        for (index, payload) in events.iter().enumerate() {
            let envelope = json!({
                "timestamp": format!("2026-06-01T10:00:{index:02}Z"),
                "type": "event_msg",
                "payload": payload,
            });
            writeln!(file, "{envelope}").unwrap();
        }
        parse_codex_jsonl(file.path()).unwrap()
    }

    #[test]
    fn parses_sanitized_codex_token_count_events() {
        let output =
            parse_codex_jsonl(Path::new("../../tests/fixtures/codex/token_count.jsonl")).unwrap();

        assert_eq!(
            output.session_id.as_deref(),
            Some("00000000-0000-4000-8000-000000000001")
        );
        assert_eq!(output.usage_events.len(), 1);
        assert_eq!(output.usage_events[0].tool_id, "codex");
        assert_eq!(
            output.usage_events[0].model_name.as_deref(),
            Some("fixture-model")
        );
        assert_eq!(output.usage_events[0].input_tokens, 100);
        assert_eq!(output.usage_events[0].cached_input_tokens, 20);
        assert_eq!(output.usage_events[0].output_tokens, 30);
        assert_eq!(output.usage_events[0].total_tokens, 130);

        assert_eq!(output.limit_windows.len(), 2);
        assert_eq!(output.limit_windows[0].window_kind, WindowKind::FiveHours);
        assert_eq!(output.limit_windows[1].window_kind, WindowKind::OneWeek);
    }

    #[test]
    fn quota_updates_survive_missing_and_repeated_usage() {
        let counts = json!({"input_tokens": 70, "cached_input_tokens": 10, "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 90});
        let info = json!({"last_token_usage": counts, "total_token_usage": counts});
        let window = |used| json!({"primary": {"window_minutes": 300, "resets_at": 1780308000, "used_percent": used}});
        let output = parse_events(&[
            json!({"type":"token_count", "info":null, "rate_limits":window(10)}),
            json!({"type":"token_count", "info":info, "rate_limits":null}),
            json!({"type":"token_count", "rate_limits":window(11)}),
            json!({"type":"token_count", "info":info, "rate_limits":window(12)}),
        ]);
        assert_eq!(output.usage_events.len(), 1);
        assert_eq!(output.usage_events[0].total_tokens, 90);
        assert_eq!(output.superseded_usage.len(), 1);
        let stale = &output.superseded_usage[0];
        assert_eq!(stale.total_tokens, 105);
        assert!(stale.occurred_at > output.usage_events[0].occurred_at);
        assert!(stale.model_name.is_none());
        assert_eq!(output.limit_windows.len(), 3);
        assert_eq!(output.limit_windows[2].used_percent, Some(12.0));
    }

    #[test]
    fn derives_usage_from_cumulative_snapshots_and_handles_counter_reset() {
        let cumulative = |input, cached, output| json!({"input_tokens":input, "cached_input_tokens":cached, "output_tokens":output});
        let first = cumulative(100, 20, 30);
        let second = cumulative(180, 40, 50);
        let reset = cumulative(10, 0, 5);
        let output = parse_events(&[
            json!({"type":"token_count","info":{"total_token_usage":first}}),
            json!({"type":"token_count","info":{"total_token_usage":second}}),
            json!({"type":"token_count","info":{"total_token_usage":reset,"last_token_usage":reset}}),
            json!({"type":"token_count","info":{"total_token_usage":reset,"last_token_usage":reset}}),
        ]);
        let totals: Vec<_> = output
            .usage_events
            .iter()
            .map(|e| {
                (
                    e.input_tokens,
                    e.cached_input_tokens,
                    e.output_tokens,
                    e.total_tokens,
                )
            })
            .collect();
        assert_eq!(
            totals,
            [(100, 20, 30, 130), (80, 20, 20, 100), (10, 0, 5, 15)]
        );
    }

    #[test]
    fn a_partial_log_starts_with_the_reported_increment() {
        let output = parse_events(&[json!({"type":"token_count","info":{
            "last_token_usage":{"total_tokens":90}, "total_token_usage":{"total_tokens":900}
        }})]);
        assert_eq!(output.usage_events[0].total_tokens, 90);
    }

    #[test]
    fn cumulative_delta_survives_missing_or_restored_breakdowns() {
        let snapshot = |total| json!({"type":"token_count","info":{"total_token_usage":total}});
        let output = parse_events(&[
            snapshot(
                json!({"input_tokens":70,"cached_input_tokens":10,"output_tokens":20,"total_tokens":90}),
            ),
            snapshot(json!({"total_tokens":120})),
            snapshot(
                json!({"input_tokens":100,"cached_input_tokens":20,"output_tokens":40,"total_tokens":140}),
            ),
        ]);
        let totals: Vec<_> = output
            .usage_events
            .iter()
            .map(|event| event.total_tokens)
            .collect();
        assert_eq!(totals, [90, 30, 20]);
        assert_eq!(output.usage_events[2].input_tokens, 0);
    }

    #[test]
    fn legacy_last_only_reports_do_not_merge_equal_turns() {
        let event = json!({"type":"token_count","info":{"last_token_usage":{
            "input_tokens":70, "cached_input_tokens":10, "output_tokens":20, "reasoning_output_tokens":5
        }}});
        let output = parse_events(&[event.clone(), event]);
        assert_eq!(output.usage_events.len(), 2);
        assert!(output.usage_events.iter().all(|e| e.total_tokens == 90));
    }

    #[test]
    fn mixed_log_counts_legacy_events_once_between_cumulative_snapshots() {
        let cumulative = |total| json!({"type":"token_count","info":{"total_token_usage":{"total_tokens":total}}});
        let last = |total| json!({"type":"token_count","info":{"last_token_usage":{"total_tokens":total}}});
        let output = parse_events(&[last(30), cumulative(50), last(10), cumulative(100)]);
        let totals: Vec<_> = output
            .usage_events
            .iter()
            .map(|event| event.total_tokens)
            .collect();
        assert_eq!(totals, [30, 20, 10, 40]);
    }
}
