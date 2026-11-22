use std::{fs, path::Path, process::Command};

use chrono::{Duration, Utc};
use serde_json::{Value, json};

fn write(root: &Path, path: &str, value: &Value) {
    let file = root.join(path);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, value.to_string()).unwrap();
}

fn cli(root: &Path, command: &str, extra: &[&str]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
        .args([command, "--db"])
        .arg(root.join("usage/measure.sqlite"))
        .args(extra)
        .env("USERPROFILE", root)
        .env("APPDATA", root.join("Roaming"))
        .env("LOCALAPPDATA", root.join("Local"))
        .env("PATH", "")
        .env_remove("CLINE_DIR")
        .env_remove("AUGMENT_HOME")
        .env_remove("AMP_DATA_DIR")
        .env_remove("XDG_DATA_HOME")
        .env_remove("VIBEMEASURE_FACTORY_ACCESS_TOKEN")
        .env_remove("VIBEMEASURE_ANTIGRAVITY_PATH")
        .env_remove("VIBEMEASURE_FACTORY_DROID_PATH")
        .env_remove("VIBEMEASURE_CLINE_PATH")
        .env_remove("VIBEMEASURE_AUGGIE_PATH")
        .env_remove("VIBEMEASURE_AMP_PATH")
        .env_remove("VIBEMEASURE_OPENHANDS_PATH")
        .env_remove("VIBEMEASURE_AUGGIE_COMMAND")
        .env_remove("VIBEMEASURE_AMP_COMMAND")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn provider<'a>(snapshot: &'a Value, id: &str) -> &'a Value {
    snapshot["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["tool_id"] == id)
        .unwrap()
}

#[test]
fn refreshes_six_providers_and_keeps_session_totals_separate_from_dated_usage() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path();
    let now = Utc::now();
    let earlier = now - Duration::minutes(5);
    let later = now + Duration::hours(2);
    let antigravity = ".gemini/antigravity-cli/vibemeasure-usage.json";
    write(
        root,
        antigravity,
        &json!({
            "product": "antigravity", "captured_at": earlier, "plan_tier": "Pro",
            "context_window": {"total_input_tokens": 70, "total_output_tokens": 20},
            "cost": {"total_usd": 2.55},
            "quota": {
                "fast": {"remaining_fraction": 0.75, "reset_time": later},
                "stale": {"remaining_fraction": 0.25, "reset_time": earlier},
                "disabled": {"remaining_fraction": 0.5, "disabled": true}
            }
        }),
    );
    write(
        root,
        ".factory/sessions/one.settings.json",
        &json!({
            "sessionId": "one", "tokenUsage": {"inputTokens": 70, "outputTokens": 20, "factoryCredits": 7},
            "inclusiveTokenUsage": {"inputTokens": 700}
        }),
    );
    write(
        root,
        ".factory/sessions/factory-limits.json",
        &json!({
            "limits": {"standard": {"weekly": {"usedPercent": 23, "windowEnd": later}},
                       "core": {"weekly": {"usedPercent": 0}}},
            "extraUsageAllowed": true, "extraUsageBalanceCents": 205
        }),
    );
    write(
        root,
        ".cline/data/sessions/one.json",
        &json!({
            "session_id": "cline", "metadata": {"usage": {"inputTokens": 90, "outputTokens": 10, "totalCost": 0}}
        }),
    );
    let message = json!({"id": "same", "role": "assistant", "ts": earlier.timestamp_millis(),
                          "metrics": {"inputTokens": 8, "outputTokens": 2}});
    write(
        root,
        ".cline/data/sessions/one.messages.json",
        &json!({"messages": [message, message]}),
    );
    write(
        root,
        "Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/state/taskHistory.json",
        &json!([{"id": "cline", "tokensIn": 90, "tokensOut": 10, "totalCost": 0},
                  {"id": "vscode-only", "tokensIn": 4, "totalCost": 0.5},
                  {"id": "vscode-only", "tokensIn": 4, "totalCost": 0.5}]),
    );
    let amp = ".local/share/amp/threads/one.json";
    let amp_thread = |tokens| {
        json!({
            "id": "amp", "usageLedger": {"events": [
                {"id": "event", "tokens": {"total": tokens}, "timestamp": earlier, "credits": 2},
                {"id": "event", "tokens": {"total": tokens}, "timestamp": earlier, "credits": 2},
            ]},
            "messages": [{"role": "assistant", "usage": {"totalTokens": tokens}}]
        })
    };
    write(root, amp, &amp_thread(16));
    write(
        root,
        ".augment/sessions/one.json",
        &json!({
            "sessionId": "augment", "creditUsage": 7, "chatHistory": [{"exchange": {
                "request_id": "request", "response_nodes": [
                    {"type": 8, "id": 1, "token_usage": {"input_tokens": 100}},
                    {"type": 10, "id": 2, "timestamp_ms": earlier.timestamp_millis(), "token_usage": {"input_tokens": 13, "output_tokens": 2}},
                    {"type": 10, "id": 2, "timestamp_ms": earlier.timestamp_millis(), "token_usage": {"input_tokens": 13, "output_tokens": 2}},
                    {"type": 9, "id": 3, "billing_metadata": {"transaction_id": "ignored", "credits_consumed": 10}}
                ]
            }}]
        }),
    );
    write(
        root,
        ".openhands/conversations/one/base_state.json",
        &json!({
            "id": "open", "max_budget_per_run": 10, "stats": {"usage_to_metrics": {
                "default": {"accumulated_cost": 2, "accumulated_token_usage": {
                    "prompt_tokens": 60, "completion_tokens": 15, "cache_read_tokens": 10
                }}
            }}
        }),
    );

    assert_eq!(cli(root, "sync-providers", &[])["providers_updated"], 6);
    let snapshot = cli(
        root,
        "snapshot",
        &["--mode", "five-hours", "--currency", "EUR"],
    );
    let gravity = provider(&snapshot, "antigravity");
    assert_eq!(gravity["plan"]["name"], "Pro");
    assert_eq!(gravity["reported"]["conversation_tokens"], true);
    assert_eq!(gravity["reported"]["tokens"], 90);
    assert_eq!(gravity["reported"]["estimated_usd"], 2.55);
    assert_eq!(gravity["reported"]["quotas"][0]["used_percent"], 25.0);
    assert!(gravity["reported"]["quotas"][1]["used_percent"].is_null());
    let droid = &provider(&snapshot, "factory-droid")["reported"];
    assert_eq!(droid["tokens"], 90);
    assert_eq!(droid["credits"], 7.0);
    assert!(droid["estimated_usd"].is_null());
    assert_eq!(droid["quotas"][0]["used_percent"], 23.0);
    assert_eq!(droid["quotas"][1]["used_percent"], 0.0);
    assert_eq!(droid["quotas"][2]["value"], 2.05);
    let cline = provider(&snapshot, "cline");
    assert_eq!(cline["reported"]["tokens"], 104);
    assert_eq!(cline["reported"]["estimated_usd"], 0.5);
    assert_eq!(cline["usage"]["total_tokens"], 10);
    let auggie = provider(&snapshot, "auggie");
    assert_eq!(auggie["usage"]["total_tokens"], 15);
    assert_eq!(auggie["reported"]["credits"], 7.0);
    let amp_reading = provider(&snapshot, "amp");
    assert_eq!(amp_reading["usage"]["total_tokens"], 16);
    assert_eq!(amp_reading["reported"]["credits"], 2.0);
    let openhands = &provider(&snapshot, "openhands")["reported"];
    assert_eq!(openhands["tokens"], 75);
    assert_eq!(openhands["estimated_usd"], 2.0);
    assert_eq!(openhands["quotas"][0]["used_percent"], 20.0);

    write(root, amp, &amp_thread(24));
    fs::write(root.join(antigravity), "{").unwrap();
    assert_eq!(cli(root, "sync-providers", &[])["unreadable_files"], 1);
    let snapshot = cli(root, "snapshot", &[]);
    assert_eq!(provider(&snapshot, "amp")["usage"]["total_tokens"], 24);
    assert_eq!(
        provider(&snapshot, "antigravity")["reported"]["estimated_usd"],
        2.55
    );

    fs::remove_file(root.join(antigravity)).unwrap();
    assert_eq!(cli(root, "sync-providers", &[])["providers_updated"], 5);
    let snapshot = cli(root, "snapshot", &[]);
    assert!(provider(&snapshot, "antigravity")["reported"].is_null());
}
