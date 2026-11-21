# Reporting And Export

Reports summarize token usage and cost status over a selected period.

## Periods

- Current week.
- Current month.
- Current year.
- Custom date range.

The CLI queries events between the inclusive start and exclusive end timestamps. macOS supports a current snapshot and dated reports. Historical reports aggregate recorded local token events from enabled providers, or imported events from a VibeMeasure SQLite database selected in the report window. Each report uses one source. Weeks start Monday UTC and custom ranges include the entire selected end date in UTC. Providers with no dated events in the period have no historical total. Manual quota percentages remain available in the snapshot.

## Exports

- CLI `.xlsx`: generated with `rust_xlsxwriter`.
- macOS `.xlsx`: generated as an open OOXML workbook.
- CLI `.pdf`: generated as a simple open PDF document.
- macOS `.pdf`: rendered as a styled native report with header, summary cards, and table layout.

Exports include token counts and source notes. CLI reports label calculable prices as estimates and include their sources. See [Pricing and Currency](pricing-currency.md) for units, conversion and missing-price behavior.

Validation:

```bash
cargo run -p vibemeasure-cli -- report \
  --db vibemeasure.sqlite \
  --start 2026-06-01T00:00:00Z \
  --end 2026-06-02T00:00:00Z \
  --currency USD \
  --xlsx report.xlsx \
  --pdf report.pdf
```
