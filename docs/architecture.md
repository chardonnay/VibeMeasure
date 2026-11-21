# Architecture

The Rust CLI stores imported Codex measurements in SQLite. The macOS app can query that history or gather readings directly from four local providers.

```mermaid
flowchart TD
    Logs["Codex session logs"] --> CLI["Rust CLI and core"]
    CLI <--> DB["SQLite database"]
    CLI --> Platforms["Windows, GNOME and KDE displays"]
    CLI --> Exports["JSON, XLSX and PDF reports"]
    Readers["macOS local readers and manual settings"] --> Mac["macOS app"]
    DB --> Mac
    Mac --> NativeExports["Native XLSX and PDF reports"]
    Mac --> Widget["WidgetKit snapshot"]
```

## Responsibilities

- Native shells own OS-specific presentation, notifications, autostart, and widget packaging.
- `vibemeasure-core` owns provider catalog data, source metadata, usage windows, persistence, snapshots, reports, and verified parsers.
- Provider adapters may read local logs or official APIs only when the format is verified.
- Manual settings are first-class data with `manual` source status, not hidden defaults.

## Truth Policy

Every usage, pricing, limit, model, currency, and reset-window value must carry:

- `source.kind`: local evidence, official API, official docs, manual, unknown, or test double.
- `source.status`: verified, estimated, manual, or unknown.
- `source.label`: human-readable origin.
- `source.fetched_at`: timestamp.

VibeMeasure must show unknown/manual state rather than invent a tariff, quota, schema, or reset window.

