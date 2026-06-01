# Reporting And Export

Reports summarize token usage and cost status over a selected period.

## Periods

- Current week.
- Current month.
- Current year.
- Custom date range.

The CLI already supports custom start and end timestamps. Native UIs will map dropdown selections to these ranges.

macOS status: the menu-bar app opens a native Reports window from the Usage footer. It can export the currently visible live/manual snapshot to `.xlsx` and `.pdf`. Historical native aggregation over the selected period starts after the macOS app writes usage events to the shared SQLite store.

## Exports

- CLI `.xlsx`: generated with `rust_xlsxwriter`.
- macOS snapshot `.xlsx`: generated as an open OOXML workbook.
- CLI `.pdf`: generated as a simple open PDF document.
- macOS snapshot `.pdf`: rendered as a styled native report with header, summary cards, and table layout.

Exports include token counts and source notes. Costs are omitted unless provider-reported cost, verified pricing, or manual pricing exists.

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
