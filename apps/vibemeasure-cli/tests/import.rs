use std::{fs, path::Path, process::Command};

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
