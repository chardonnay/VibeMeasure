use std::{
    path::Path,
    process::{Command, Output},
};

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
