use std::{
    fs,
    path::Path,
    process::{Command, Output},
};

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde_json::Value;

fn run(db: &Path, command: &str, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
        .args([command, "--db"])
        .arg(db)
        .args(args)
        .output()
        .unwrap()
}

fn success(db: &Path, command: &str, args: &[&str]) -> Vec<u8> {
    let output = run(db, command, args);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

fn report_cost(db: &Path, currency: Option<&str>) -> Value {
    let mut args = vec![
        "--start",
        "2026-06-01T00:00:00Z",
        "--end",
        "2026-06-02T00:00:00Z",
    ];
    if let Some(currency) = currency {
        args.extend(["--currency", currency]);
    }
    let report: Value = serde_json::from_slice(&success(db, "report", &args)).unwrap();
    report["costs"]["codex"].clone()
}

fn codex_snapshot(db: &Path, mode: &str, currency: &str) -> Value {
    let snapshot: Value = serde_json::from_slice(&success(
        db,
        "snapshot",
        &["--mode", mode, "--currency", currency],
    ))
    .unwrap();
    assert_eq!(snapshot["currency"], currency);
    snapshot["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|provider| provider["tool_id"] == "codex")
        .unwrap()
        .clone()
}

fn write_rollout(path: &Path, at: DateTime<Utc>, id: &str, plan: &str) {
    let mut events: Vec<Value> = include_str!("../../../tests/fixtures/codex/token_count.jsonl")
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    for event in &mut events {
        event["timestamp"] = at.to_rfc3339_opts(SecondsFormat::Secs, true).into();
    }
    events[0]["payload"]["id"] = id.into();
    let limits = &mut events[2]["payload"]["rate_limits"];
    limits["plan_type"] = plan.into();
    limits["primary"]["resets_at"] = (at + Duration::hours(4)).timestamp().into();
    limits["secondary"]["resets_at"] = (at + Duration::days(6)).timestamp().into();
    fs::write(
        path,
        events
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .unwrap();
}

#[test]
fn snapshot_uses_the_latest_reported_plan_and_prices_each_period_independently() {
    let directory = tempfile::tempdir().unwrap();
    let db = directory.path().join("usage.sqlite");
    success(&db, "set-plan", &["--tool", "codex", "--name", "Team"]);
    assert_eq!(
        codex_snapshot(&db, "provider-cycles", "USD")["plan"]["source"]["kind"],
        "manual"
    );

    let recent = directory.path().join("recent.jsonl");
    let earlier = directory.path().join("earlier.jsonl");
    let now = Utc::now();
    write_rollout(&recent, now - Duration::minutes(5), "recent", "plus");
    write_rollout(&earlier, now - Duration::hours(6), "earlier", "free");
    for path in [&recent, &earlier, &recent] {
        success(&db, "import-codex", &["--jsonl", path.to_str().unwrap()]);
    }

    let unpriced = codex_snapshot(&db, "provider-cycles", "USD");
    assert_eq!(unpriced["plan"]["name"], "Plus");
    assert_eq!(unpriced["plan"]["source"]["kind"], "local_evidence");
    assert_eq!(unpriced["estimated_cost"]["status"], "unknown");
    assert_eq!(unpriced["usage"]["total_tokens"], 260);

    success(
        &db,
        "set-price",
        &[
            "--tool",
            "codex",
            "--provider",
            "fixture",
            "--model",
            "fixture-model",
            "--input",
            "2",
            "--cached-input",
            "0.4",
            "--output",
            "8",
        ],
    );
    let cycles = codex_snapshot(&db, "provider-cycles", "USD");
    let assert_cost = |cost: &Value, expected: f64| {
        assert_eq!(cost["status"], "api_equivalent_estimate");
        assert!((cost["amount"].as_f64().unwrap() - expected).abs() < 1e-10);
    };
    assert_cost(&cycles["estimated_cost"], 0.000816);
    for (kind, amount) in [("five_hours", 0.000408), ("one_week", 0.000816)] {
        let window = cycles["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|window| window["window_kind"] == kind)
            .unwrap();
        assert_cost(&window["estimated_cost"], amount);
    }
    assert_eq!(
        codex_snapshot(&db, "five-hours", "EUR")["estimated_cost"]["status"],
        "unknown"
    );
    success(&db, "set-rate", &["--quote", "EUR", "--rate", "0.5"]);
    let comparison = codex_snapshot(&db, "five-hours", "EUR");
    assert!(comparison["windows"].as_array().unwrap().is_empty());
    assert_cost(&comparison["estimated_cost"], 0.000204);
}

#[test]
fn manual_configuration_reaches_real_reports_in_usd_and_foreign_currency() {
    let directory = tempfile::tempdir().unwrap();
    let db = directory.path().join("usage.sqlite");
    success(
        &db,
        "import-codex",
        &["--jsonl", "../../tests/fixtures/codex/token_count.jsonl"],
    );
    success(
        &db,
        "set-price",
        &[
            "--tool",
            "codex",
            "--provider",
            "fixture",
            "--model",
            "fixture-model",
            "--input",
            "2",
            "--cached-input",
            "0.4",
            "--output",
            "8",
            "--source",
            "test price",
        ],
    );
    let usd = report_cost(&db, None);
    assert_eq!(usd["status"], "api_equivalent_estimate");
    assert_eq!(usd["pricing_sources"][0]["kind"], "manual");
    assert_eq!(usd["pricing_sources"][0]["label"], "test price");
    assert!((usd["amount"].as_f64().unwrap() - 0.000408).abs() < 1e-10);
    assert_eq!(report_cost(&db, Some("eur"))["status"], "unknown");
    success(
        &db,
        "set-rate",
        &["--quote", "eur", "--rate", "0.5", "--source", "test rate"],
    );
    let eur = report_cost(&db, Some("eur"));
    assert_eq!(eur["exchange_rate_sources"][0]["status"], "manual");
    assert_eq!(eur["exchange_rate_sources"][0]["label"], "test rate");
    assert!((eur["amount"].as_f64().unwrap() - 0.000204).abs() < 1e-10);
    success(
        &db,
        "set-rate",
        &["--base", "usd", "--quote", "eur", "--rate", "0.75"],
    );
    assert!((report_cost(&db, Some("eur"))["amount"].as_f64().unwrap() - 0.000306).abs() < 1e-10);
}

#[test]
fn invalid_manual_inputs_fail_before_writing_a_database() {
    let directory = tempfile::tempdir().unwrap();
    let db = directory.path().join("prices.sqlite");
    for args in [
        vec!["set-price", "--tool", "codex", "--provider", "fixture"],
        vec![
            "set-price",
            "--tool",
            "unknown-tool",
            "--provider",
            "fixture",
            "--output",
            "8",
        ],
        vec![
            "set-price",
            "--tool",
            "codex",
            "--provider",
            "fixture",
            "--input",
            "NaN",
        ],
        vec![
            "set-price",
            "--tool",
            "codex",
            "--provider",
            "fixture",
            "--input=-1",
        ],
        vec!["set-rate", "--quote", "EUR", "--rate", "0"],
        vec!["set-rate", "--quote", "EUR", "--rate", "inf"],
        vec!["set-rate", "--quote", "US", "--rate", "1"],
        vec!["set-rate", "--quote", "usd", "--rate", "1"],
    ] {
        assert!(!run(&db, args[0], &args[1..]).status.success(), "{args:?}");
        assert!(!db.exists(), "{args:?}");
    }
}
