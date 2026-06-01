# Data Model

The shared core stores data in SQLite.

```mermaid
erDiagram
    USAGE_EVENTS {
        integer id PK
        text tool_id
        text occurred_at
        text model_name
        integer input_tokens
        integer cached_input_tokens
        integer output_tokens
        integer reasoning_output_tokens
        integer total_tokens
        text source_json
    }

    LIMIT_WINDOWS {
        integer id PK
        text tool_id
        text window_kind_json
        text starts_at
        text ends_at
        text reset_at
        real used_percent
        integer used_tokens
        integer token_limit
        text source_json
    }

    PRICING_RULES {
        integer id PK
        text tool_id
        text provider_name
        text model_name
        real input_per_million_usd
        real cached_input_per_million_usd
        real output_per_million_usd
        text billing_window_json
        text source_json
    }

    CURRENCY_RATES {
        text base_currency PK
        text quote_currency PK
        real rate
        text source_json
    }

    APP_SETTINGS {
        text key PK
        text value_json
    }

    WIDGET_SNAPSHOTS {
        integer id PK
        text generated_at
        text snapshot_json
    }
```

## Display Modes

- `provider_cycles`
- `five_hours`
- `one_week`
- `one_month`

Provider cycles are the default display mode. Built-in LLM providers are disabled in menu-bar and widget surfaces until the user explicitly enables them. The period comparison modes are derived from stored events and do not imply provider-specific limits unless a limit window is verified or manually configured.

## Window Kinds

- `five_hours`
- `one_week`
- `one_month`
- `custom_minutes`

Unknown provider windows are not generated automatically.
