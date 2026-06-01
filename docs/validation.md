# Validation

## Core

```bash
cargo fmt --check
cargo test
cargo run -p vibemeasure-cli -- catalog
```

## Codex Parser

```bash
cargo run -p vibemeasure-cli -- init-db --db vibemeasure.sqlite
cargo run -p vibemeasure-cli -- import-codex \
  --db vibemeasure.sqlite \
  --jsonl tests/fixtures/codex/token_count.jsonl
cargo run -p vibemeasure-cli -- snapshot --db vibemeasure.sqlite --mode provider-cycles
```

What to check:

- `codex` has local usage data.
- Unknown providers are still present and marked for manual setup.
- 5-hour and weekly Codex windows come from the fixture, not from guessed defaults.

## Currency Refresh

```bash
cargo run -p vibemeasure-cli -- refresh-ecb-rates --db vibemeasure.sqlite
```

What to check:

- Rates are stored with ECB source metadata.
- Unsupported currencies still require manual entry.

## Reports

```bash
cargo run -p vibemeasure-cli -- report \
  --db vibemeasure.sqlite \
  --start 2026-06-01T00:00:00Z \
  --end 2026-06-02T00:00:00Z \
  --currency USD \
  --xlsx report.xlsx \
  --pdf report.pdf
```

What to check:

- The `.xlsx` file opens in Excel or LibreOffice.
- The `.pdf` renders in a PDF viewer.
- Source notes are visible.

