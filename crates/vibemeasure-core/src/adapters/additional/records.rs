use std::{collections::HashSet, path::Path};

use chrono::{DateTime, Duration, Utc};
use serde_json::Value;

use super::{Provider, Reading, amount, count, finite, parse_file, timestamp};
use crate::model::{ProviderPlan, ReportedQuota, ReportedQuotaUnit, SourceMeta};

const CLINE_FIELDS: &[&str] = &[
    "inputTokens",
    "outputTokens",
    "cacheReadTokens",
    "cacheWriteTokens",
];
const SNAKE_FIELDS: &[&str] = &[
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
];

pub(super) fn read(
    provider: Provider,
    data: &Value,
    file: &Path,
    now: DateTime<Utc>,
    seen: &mut HashSet<String>,
    reading: &mut Reading,
) {
    let fallback = file
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let fallback = fallback.strip_suffix(".settings.json").unwrap_or(fallback);
    match provider {
        Provider::Antigravity => antigravity(data, now, seen, reading),
        Provider::Droid => droid(data, fallback, seen, reading),
        Provider::Cline => cline(data, file, seen, reading),
        Provider::Auggie => auggie(data, fallback, seen, reading),
        Provider::Amp => amp(data, seen, reading),
        Provider::OpenHands => openhands(data, seen, reading),
    }
}

fn rows(value: &Value) -> &[Value] {
    value.as_array().map_or(&[], Vec::as_slice)
}

fn sum_tokens(values: impl IntoIterator<Item = u64>) -> Option<u64> {
    let mut values = values.into_iter();
    let first = values.next()?;
    values.try_fold(first, u64::checked_add)
}

fn sum_fields(record: &Value, fields: &[&str]) -> Option<u64> {
    sum_tokens(fields.iter().filter_map(|key| count(&record[*key])))
}

fn antigravity(
    data: &Value,
    now: DateTime<Utc>,
    seen: &mut HashSet<String>,
    reading: &mut Reading,
) {
    if data["product"] != "antigravity" || !seen.insert("status-snapshot".into()) {
        return;
    }
    let captured = timestamp(&data["captured_at"]).filter(|date| *date <= now);
    reading.plan = data["plan_tier"]
        .as_str()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(|name| ProviderPlan {
            name: name.chars().take(100).collect(),
            source: SourceMeta::local("Antigravity status line", captured.unwrap_or(now)),
        });
    reading.conversation_tokens = sum_fields(
        &data["context_window"],
        &["total_input_tokens", "total_output_tokens"],
    );
    reading.add_usd(amount(&data["cost"]["total_usd"]));
    if let Some(quota) = data["quota"].as_object() {
        for (key, bucket) in quota {
            if bucket["disabled"] == true {
                continue;
            }
            let reset = timestamp(&bucket["reset_time"]).or_else(|| {
                let seconds = amount(&bucket["reset_in_seconds"])?;
                (seconds <= 366.0 * 86_400.0).then_some(())?;
                captured?.checked_add_signed(Duration::milliseconds((seconds * 1000.0) as i64))
            });
            let remaining = amount(&bucket["remaining_fraction"]).filter(|value| *value <= 1.0);
            let balance = amount(&bucket["remaining_amount"]).filter(|_| remaining.is_none());
            if remaining.is_some() || balance.is_some() {
                reading.quotas.push(ReportedQuota {
                    name: format!("{} quota", key.chars().take(80).collect::<String>()),
                    used_percent: remaining.map(|value| (1.0 - value) * 100.0),
                    resets_at: reset,
                    value: balance,
                    unit: balance.map(|_| ReportedQuotaUnit::Remaining),
                    detail: "Antigravity status line".into(),
                });
            }
        }
    }
}

fn droid(data: &Value, fallback: &str, seen: &mut HashSet<String>, reading: &mut Reading) {
    if data["limits"].is_object() {
        for quota in factory_quotas(data) {
            if !reading
                .quotas
                .iter()
                .any(|current| current.name == quota.name)
            {
                reading.quotas.push(quota);
            }
        }
    } else if data["tokenUsage"].is_object() {
        let id = data["sessionId"].as_str().unwrap_or(fallback);
        if seen.insert(id.to_owned()) {
            let usage = &data["tokenUsage"];
            // Inclusive usage also counts child sessions.
            reading.add_tokens(
                sum_fields(
                    usage,
                    &[
                        "inputTokens",
                        "outputTokens",
                        "cacheReadTokens",
                        "cacheCreationTokens",
                    ],
                ),
                None,
            );
            reading.add_credits(amount(&usage["factoryCredits"]));
        }
    } else if data["type"] == "result" && data["usage"].is_object() {
        let id = data["session_id"].as_str().unwrap_or(fallback);
        if seen.insert(id.to_owned()) {
            reading.add_tokens(sum_fields(&data["usage"], SNAKE_FIELDS), None);
            reading.add_credits(amount(&data["usage"]["factory_credits"]));
        }
    }
}

pub(super) fn factory_quotas(data: &Value) -> Vec<ReportedQuota> {
    let mut quotas = Vec::new();
    for (pool, label) in [("standard", "Standard"), ("core", "Droid Core")] {
        for (cycle, name) in [
            ("fiveHour", "5-hour"),
            ("weekly", "Weekly"),
            ("monthly", "Monthly"),
        ] {
            let item = &data["limits"][pool][cycle];
            if let Some(percent) = amount(&item["usedPercent"]).filter(|value| *value <= 100.0) {
                quotas.push(ReportedQuota {
                    name: format!("{label} · {name}"),
                    used_percent: Some(percent),
                    resets_at: timestamp(&item["windowEnd"]),
                    value: None,
                    unit: None,
                    detail: "Factory account limit".into(),
                });
            }
        }
    }
    if data["extraUsageAllowed"] == true
        && let Some(cents) = amount(&data["extraUsageBalanceCents"])
    {
        quotas.push(ReportedQuota {
            name: "Extra usage balance".into(),
            used_percent: None,
            resets_at: None,
            value: Some(cents / 100.0),
            unit: Some(ReportedQuotaUnit::UsdRemaining),
            detail: "Factory prepaid credit".into(),
        });
    }
    quotas
}

fn cline(data: &Value, file: &Path, seen: &mut HashSet<String>, reading: &mut Reading) {
    if let Some(tasks) = data.as_array().or_else(|| data["taskHistory"].as_array()) {
        for task in tasks {
            if let Some(id) = task["id"].as_str()
                && seen.insert(format!("aggregate:{id}"))
            {
                reading.add_tokens(
                    sum_fields(
                        task,
                        &["tokensIn", "tokensOut", "cacheReads", "cacheWrites"],
                    ),
                    None,
                );
                reading.add_usd(amount(&task["totalCost"]));
            }
        }
        return;
    }
    let Some(id) = data["session_id"].as_str() else {
        return;
    };
    if !seen.insert(format!("transcript:{id}")) {
        return;
    }
    let meta = &data["metadata"];
    let usage = meta
        .get("usage")
        .or_else(|| meta.get("aggregateUsage"))
        .unwrap_or(&Value::Null);
    let mut history = Vec::new();
    if let Ok(transcript) = parse_file(&file.with_extension("messages.json")) {
        let mut messages = HashSet::new();
        for message in rows(&transcript["messages"]) {
            if message["role"] == "assistant"
                && let (Some(tokens), Some(date)) = (
                    sum_fields(&message["metrics"], CLINE_FIELDS),
                    timestamp(&message["ts"]),
                )
                && message["id"].as_str().is_none_or(|id| messages.insert(id))
            {
                history.push((date, tokens));
            }
        }
    }
    for (date, tokens) in &history {
        let total = reading.history.entry(*date).or_default();
        *total = total.saturating_add(*tokens);
    }
    if seen.insert(format!("aggregate:{id}")) {
        reading.add_tokens(
            sum_fields(usage, CLINE_FIELDS)
                .or_else(|| sum_tokens(history.into_iter().map(|(_, tokens)| tokens))),
            None,
        );
        reading.add_usd(amount(&usage["totalCost"]).or_else(|| amount(&meta["totalCost"])));
    }
}

fn auggie(data: &Value, fallback: &str, seen: &mut HashSet<String>, reading: &mut Reading) {
    let Some(turns) = data["chatHistory"].as_array() else {
        return;
    };
    let id = data["sessionId"].as_str().unwrap_or(fallback);
    if !seen.insert(id.to_owned()) {
        return;
    }
    let credits = amount(&data["creditUsage"]);
    reading.add_credits(credits);
    let mut transactions = HashSet::new();
    let mut usage_nodes = HashSet::new();
    for (turn, item) in turns.iter().enumerate() {
        let exchange = &item["exchange"];
        let nodes = rows(&exchange["response_nodes"]);
        let usage_type = if nodes
            .iter()
            .any(|node| node["type"] == 10 && node["token_usage"].is_object())
        {
            10
        } else {
            8
        };
        let request = exchange["request_id"].as_str();
        for (index, node) in nodes.iter().enumerate() {
            if count(&node["type"]) == Some(usage_type)
                && node["token_usage"].is_object()
                && usage_nodes.insert((
                    request.ok_or(turn),
                    count(&node["id"]).unwrap_or(index as u64),
                ))
            {
                reading.add_tokens(
                    sum_fields(&node["token_usage"], SNAKE_FIELDS),
                    timestamp(&node["timestamp_ms"]),
                );
            }
            let metadata = &node["billing_metadata"];
            if credits.is_none()
                && let Some(transaction) = metadata["transaction_id"].as_str()
                && let Some(value) = amount(&metadata["credits_consumed"])
                && transactions.insert(transaction)
            {
                reading.add_credits(Some(value));
            }
        }
    }
}

fn amp(data: &Value, seen: &mut HashSet<String>, reading: &mut Reading) {
    let Some(id) = data["id"].as_str() else {
        return;
    };
    if !seen.insert(id.to_owned()) {
        return;
    }
    let mut has_ledger_tokens = false;
    let mut seen_events = HashSet::new();
    for event in rows(&data["usageLedger"]["events"]) {
        if event["id"]
            .as_str()
            .is_some_and(|id| !seen_events.insert(id))
        {
            continue;
        }
        if let Some(tokens) = count(&event["tokens"]["total"]) {
            has_ledger_tokens = true;
            reading.add_tokens(Some(tokens), timestamp(&event["timestamp"]));
        }
        reading.add_credits(amount(&event["credits"]));
    }
    if !has_ledger_tokens {
        for message in rows(&data["messages"])
            .iter()
            .filter(|item| item["role"] == "assistant")
        {
            let usage = &message["usage"];
            let total = count(&usage["totalTokens"]).or_else(|| {
                let input = count(&usage["totalInputTokens"]);
                if let Some(input) = input {
                    input.checked_add(count(&usage["outputTokens"]).unwrap_or(0))
                } else {
                    sum_fields(
                        usage,
                        &[
                            "inputTokens",
                            "outputTokens",
                            "cacheReadInputTokens",
                            "cacheCreationInputTokens",
                        ],
                    )
                }
            });
            let time = timestamp(&usage["timestamp"]).or_else(|| timestamp(&message["timestamp"]));
            reading.add_tokens(total, time);
        }
    }
}

fn openhands(data: &Value, seen: &mut HashSet<String>, reading: &mut Reading) {
    let (Some(id), Some(metrics)) = (
        data["id"].as_str(),
        data["stats"]["usage_to_metrics"].as_object(),
    ) else {
        return;
    };
    if !seen.insert(id.to_owned()) {
        return;
    }
    let cost = if metrics.is_empty() {
        None
    } else {
        metrics.values().try_fold(0.0, |total, item| {
            finite(total + amount(&item["accumulated_cost"])?)
        })
    };
    reading.add_usd(cost);
    for item in metrics.values() {
        reading.add_tokens(
            sum_fields(
                &item["accumulated_token_usage"],
                &["prompt_tokens", "completion_tokens"],
            ),
            None,
        );
    }
    if reading.quotas.is_empty()
        && let Some(cost) = cost
        && let Some(budget) = amount(&data["max_budget_per_run"]).filter(|budget| *budget > 0.0)
    {
        reading.quotas.push(ReportedQuota {
            name: "Conversation budget".into(),
            used_percent: Some((cost / budget).min(1.0) * 100.0),
            resets_at: None,
            value: Some(cost),
            unit: Some(ReportedQuotaUnit::UsdSpent),
            detail: format!("OpenHands conversation cap: {budget:.2} USD"),
        });
    }
}
