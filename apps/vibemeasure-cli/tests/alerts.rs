use std::io::Write;
use std::process::{Command, Output, Stdio};

use chrono::{Duration, Local, Utc};
use tempfile::tempdir;
use vibemeasure_core::{
    model::{LimitWindow, SourceMeta, WindowKind},
    store::VibeStore,
};

#[test]
fn saves_rules_retries_failed_delivery_and_remembers_cycles_across_processes() {
    let dir = tempdir().unwrap();
    let db = dir.path().join("profile/usage.sqlite");
    let cli = |args: &[&str], input: &str| -> Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_vibemeasure-cli"))
            .args(args)
            .arg("--db")
            .arg(&db)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
    };
    let today = Local::now().date_naive();
    let end = (today + Duration::days(7)).to_string();
    assert!(
        cli(
            &[
                "set-alert",
                "--tool",
                "codex",
                "--end-date",
                &end,
                "--days-before",
                "7",
                "--used-percent",
                "90"
            ],
            ""
        )
        .status
        .success()
    );
    assert!(
        !cli(
            &["set-alert", "--tool", "codex", "--used-percent", "101"],
            ""
        )
        .status
        .success()
    );
    assert!(
        !cli(&["set-alert", "--tool", "codex", "--days-before", "7"], "")
            .status
            .success()
    );
    let rules: serde_json::Value =
        serde_json::from_slice(&cli(&["alert-settings"], "").stdout).unwrap();
    let codex = rules
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == "codex")
        .unwrap();
    assert_eq!(codex["rule"]["end_date"], end);
    assert_eq!(codex["rule"]["used_percent"], 90);

    let now = Utc::now() - Duration::seconds(5);
    let mut window = LimitWindow {
        tool_id: "codex".into(),
        window_kind: WindowKind::FiveHours,
        starts_at: now - Duration::hours(1),
        ends_at: now + Duration::hours(4),
        reset_at: now + Duration::hours(4),
        used_percent: Some(89.9),
        used_tokens: None,
        token_limit: None,
        source: SourceMeta::local("test", now),
    };
    let store = VibeStore::open_existing(&db).unwrap();
    store.insert_limit_window(&window).unwrap();
    let check = |ack| cli(&["check-alerts", "--desktop-pipe"], ack);
    assert!(!check("").status.success());
    let expiry = check("ok\n");
    assert!(expiry.status.success());
    let body: String = serde_json::from_slice(&expiry.stdout).unwrap();
    assert!(body.contains("7 days remaining"));
    assert!(!body.contains("% used"));
    window.used_percent = Some(90.0);
    store.insert_limit_window(&window).unwrap();
    assert!(
        String::from_utf8(check("ok\n").stdout)
            .unwrap()
            .contains("90.0% used")
    );
    assert!(check("").stdout.is_empty());
    window.reset_at += Duration::hours(5);
    window.ends_at = window.reset_at;
    store.insert_limit_window(&window).unwrap();
    assert!(
        String::from_utf8(check("ok\n").stdout)
            .unwrap()
            .contains("90.0% used")
    );
    assert!(cli(&["set-alert", "--tool", "codex"], "").status.success());
    assert!(check("").stdout.is_empty());
}

#[test]
fn expiry_only_checks_the_inclusive_local_date_range() {
    use chrono::TimeZone;
    use vibemeasure_core::alerts::{AlertRule, check_alerts};
    let store = VibeStore::open_memory().unwrap();
    let now = Local
        .with_ymd_and_hms(2026, 3, 28, 23, 45, 0)
        .single()
        .unwrap();
    let end = now.date_naive() + Duration::days(1);
    for (days, expected) in [(0, 0), (1, 1)] {
        AlertRule {
            end_date: Some(end),
            days_before: Some(days),
            used_percent: None,
        }
        .save(&store, "amp")
        .unwrap();
        let mut count = 0;
        check_alerts(&store, now.into(), |_| {
            count += 1;
            Ok(())
        })
        .unwrap();
        assert_eq!(count, expected);
    }
    AlertRule {
        end_date: Some(now.date_naive()),
        days_before: Some(0),
        used_percent: None,
    }
    .save(&store, "amp")
    .unwrap();
    check_alerts(&store, (now + Duration::days(2)).into(), |_| {
        panic!("past end date")
    })
    .unwrap();
    let mut count = 0;
    check_alerts(&store, now.into(), |_| {
        count += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(count, 1);
}
