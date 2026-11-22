use std::{fs, path::Path, process::Command};

use chrono::{Duration, Utc};
use serde_json::{Value, json};

fn import(db: &Path, source: &Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
        .args(["import-codex", "--db"])
        .arg(db)
        .arg("--jsonl")
        .arg(source)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn imports_each_session_once_even_when_rollout_is_copied_or_appended() {
    let work = tempfile::tempdir().unwrap();
    let db = work.path().join("usage.sqlite");
    let first = work.path().join("original.jsonl");
    let copy = work.path().join("copy.jsonl");
    let event = r#"{"timestamp":"2026-06-01T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"total_tokens":5}}}}"#;
    let first_session =
        format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"first\"}}}}\n{event}\n");
    fs::write(&first, &first_session).unwrap();
    assert!(import(&db, &first).starts_with("imported 1 usage"));
    fs::copy(&first, &copy).unwrap();
    assert!(import(&db, &copy).starts_with("imported 0 usage"));
    fs::write(
        &copy,
        format!("{first_session}{}\n", event.replace("12:00", "12:02")),
    )
    .unwrap();
    assert!(import(&db, &copy).starts_with("imported 1 usage"));
    fs::write(&copy, first_session.replace("first", "second")).unwrap();
    assert!(import(&db, &copy).starts_with("imported 1 usage"));
    assert!(import(&db, &copy).starts_with("imported 0 usage"));
}

#[test]
fn anonymous_fixture_can_be_reimported_and_snapshot_does_not_create_missing_databases() {
    let work = tempfile::tempdir().unwrap();
    let db = work.path().join("missing.sqlite");
    let snapshot = Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
        .args(["snapshot", "--db"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(!snapshot.status.success());
    assert!(!db.exists());
    let source = work.path().join("anonymous.jsonl");
    let fixture = include_str!("../../../tests/fixtures/codex/token_count.jsonl");
    let event = fixture
        .lines()
        .find(|line| line.contains("\"token_count\""))
        .unwrap();
    fs::write(&source, event).unwrap();
    assert_eq!(
        import(&db, &source).trim(),
        "imported 1 usage events and 2 limit windows"
    );
    assert_eq!(
        import(&db, &source).trim(),
        "imported 0 usage events and 0 limit windows"
    );
}

fn cli_json(db: &Path, command: &str, args: &[&str]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
        .args([command, "--db"])
        .arg(db)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn automatic_import_retries_partial_logs_and_updates_priced_snapshots_without_duplicates() {
    let directory = tempfile::tempdir().unwrap();
    let db = directory.path().join("profile").join("usage.sqlite");
    let root = directory.path().join("codex");
    let sessions = root.join("sessions").join("2026");
    let archive = root.join("archived_sessions");
    let sync = || cli_json(&db, "sync-codex", &["--codex-home", root.to_str().unwrap()]);
    assert_eq!(sync()["source_found"], false);
    assert!(!db.exists());
    fs::create_dir_all(&sessions).unwrap();
    fs::create_dir_all(&archive).unwrap();

    let now = Utc::now();
    let event = |minutes: i64, last: u64, total: u64| {
        json!({
            "type": "event_msg",
            "timestamp": (now - Duration::minutes(minutes)).to_rfc3339(),
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {"input_tokens": last, "total_tokens": last},
                    "total_token_usage": {"input_tokens": total, "total_tokens": total}
                },
                "rate_limits": {
                    "plan_type": "plus",
                    "primary": {
                        "window_minutes": 300,
                        "used_percent": 33,
                        "resets_at": (now + Duration::hours(3)).timestamp()
                    },
                    "secondary": {
                        "window_minutes": 0,
                        "used_percent": 0,
                        "resets_at": (now + Duration::hours(3)).timestamp()
                    }
                }
            }
        })
        .to_string()
    };
    let first = event(3, 100, 100);
    let append = event(1, 50, 150);
    let head = format!(
        "{}\n{}\n{first}\n",
        json!({"type": "session_meta", "payload": {"id": "automatic"}}),
        json!({"type": "turn_context", "payload": {"model": "fixture-model"}}),
    );
    let path = sessions.join("rollout-first.jsonl");
    fs::write(&path, format!("{head}{}", &append[..append.len() / 2])).unwrap();
    let invalid = archive.join("rollout-invalid.jsonl");
    fs::write(&invalid, "{\"type\":\"token_count\" broken}\n").unwrap();
    fs::write(sessions.join("other.jsonl"), &first).unwrap();

    let initial = sync();
    assert_eq!(initial["imported_files"], 1);
    assert_eq!(initial["deferred_files"], 1);
    assert_eq!(initial["unreadable_files"], 1);
    assert_eq!(sync()["imported_files"], 0);

    let price = Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
        .args(["set-price", "--db"])
        .arg(&db)
        .args([
            "--tool",
            "codex",
            "--provider",
            "fixture",
            "--model",
            "fixture-model",
            "--input",
            "2",
        ])
        .output()
        .unwrap();
    assert!(
        price.status.success(),
        "{}",
        String::from_utf8_lossy(&price.stderr)
    );

    let codex = || {
        cli_json(&db, "snapshot", &[])["providers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|provider| provider["tool_id"] == "codex")
            .unwrap()
            .clone()
    };
    assert_eq!(codex()["usage"]["total_tokens"], 100);
    fs::write(&path, format!("{head}{append}")).unwrap();
    let changed = sync();
    assert_eq!(changed["imported_files"], 1);
    assert_eq!(changed["deferred_files"], 0);
    assert_eq!(codex()["usage"]["total_tokens"], 150);
    assert_eq!(codex()["plan"]["name"], "Plus");
    assert_eq!(codex()["windows"].as_array().unwrap().len(), 1);
    assert!((codex()["estimated_cost"]["amount"].as_f64().unwrap() - 0.0003).abs() < 1e-10);

    fs::rename(&path, archive.join("rollout-first.jsonl")).unwrap();
    assert_eq!(sync()["imported_files"], 1);
    assert_eq!(sync()["imported_files"], 0);
    assert_eq!(codex()["usage"]["total_tokens"], 150);
}
