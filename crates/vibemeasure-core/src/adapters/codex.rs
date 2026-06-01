use std::{
    fs::File,
    io::{BufRead, BufReader},
    path::Path,
};

use chrono::{DateTime, TimeZone, Utc};
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

        if value.pointer("/payload/type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }

        let occurred_at = parse_event_timestamp(&value)?;
        let source = SourceMeta::local("Codex CLI session JSONL token_count event", occurred_at);
        let last_usage = value
            .pointer("/payload/info/last_token_usage")
            .ok_or_else(|| {
                VibeError::InvalidData("Codex token_count missing last_token_usage".into())
            })?;

        let input_tokens = read_u64(last_usage, "input_tokens");
        let cached_input_tokens = read_u64(last_usage, "cached_input_tokens");
        let output_tokens = read_u64(last_usage, "output_tokens");
        let reasoning_output_tokens = read_u64(last_usage, "reasoning_output_tokens");
        let total_tokens = read_u64(last_usage, "total_tokens")
            .max(input_tokens + cached_input_tokens + output_tokens + reasoning_output_tokens);

        output.usage_events.push(UsageEvent {
            tool_id: "codex".to_string(),
            occurred_at,
            model_name: None,
            input_tokens,
            cached_input_tokens,
            output_tokens,
            reasoning_output_tokens,
            total_tokens,
            source: source.clone(),
        });

        for limit_name in ["primary", "secondary"] {
            if let Some(window) = parse_limit_window(&value, limit_name, source.clone())? {
                output.limit_windows.push(window);
            }
        }
    }

    Ok(output)
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
    let starts_at = reset_at - chrono::Duration::minutes(window_minutes);
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

fn read_u64(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use crate::model::WindowKind;

    use super::parse_codex_jsonl;

    #[test]
    fn parses_sanitized_codex_token_count_events() {
        let output =
            parse_codex_jsonl(Path::new("../../tests/fixtures/codex/token_count.jsonl")).unwrap();

        assert_eq!(output.usage_events.len(), 1);
        assert_eq!(output.usage_events[0].tool_id, "codex");
        assert_eq!(output.usage_events[0].input_tokens, 100);
        assert_eq!(output.usage_events[0].cached_input_tokens, 20);
        assert_eq!(output.usage_events[0].output_tokens, 30);
        assert_eq!(output.usage_events[0].total_tokens, 155);

        assert_eq!(output.limit_windows.len(), 2);
        assert_eq!(output.limit_windows[0].window_kind, WindowKind::FiveHours);
        assert_eq!(output.limit_windows[1].window_kind, WindowKind::OneWeek);
    }
}
