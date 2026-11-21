# Pricing And Currency

Rust CLI reports estimate the API-equivalent cost of recorded token usage using the prices and exchange rates stored in the selected SQLite database. Provider invoices and subscription charges are outside the scope of this calculation.

## Pricing Rules

### Set a manual token price

The following values and model are synthetic. They match the Codex test fixture.

```sh
cargo run -p vibemeasure-cli -- set-price --db vibemeasure.sqlite \
  --tool codex --provider fixture --model fixture-model \
  --input 2 --cached-input 0.4 --output 8 --source "Fixture tariff"
```

Each price is in USD per million tokens. Input covers uncached input, and output includes reasoning tokens. Supply explicit zeroes for free categories. Any used category with an omitted price makes the estimate unknown. Use a tool ID from `catalog` and the model name recorded by the agent. Omitting `--model` sets a tool-wide fallback.

To update a price, repeat the command with the same tool, provider and model and all applicable prices. Each report uses the newest applicable rule for that combination. Model-specific prices take priority over tool-wide defaults. If the event could belong to multiple priced backend providers, the cost remains unknown. Every rate entered with this command is identified as manual in exports, including when its source label names a vendor.

## Current Online Source Policy

- OpenAI usage/cost data should use official OpenAI Admin API documentation where configured.
- Anthropic usage/cost data should use the official Anthropic Usage and Cost Admin API where an Admin API key is configured.
- ECB euro reference rates are used for exchange-rate refresh where supported.

References:

- OpenAI usage API: <https://platform.openai.com/docs/api-reference/usage>
- OpenAI pricing: <https://openai.com/api/pricing/>
- Anthropic Usage and Cost API: <https://docs.anthropic.com/en/api/data-usage-cost-api>
- ECB reference rates: <https://www.ecb.europa.eu/stats/eurofxref/html/index.en.html>

## Currency

USD reports need no exchange rate. For another currency, enter a direct rate or refresh the ECB reference rates. For example, the following synthetic rate means that one USD buys 0.50 EUR.

```sh
cargo run -p vibemeasure-cli -- set-rate --db vibemeasure.sqlite \
  --base USD --quote EUR --rate 0.50 --source "Fixture rate"

cargo run -p vibemeasure-cli -- import-codex --db vibemeasure.sqlite \
  --jsonl tests/fixtures/codex/token_count.jsonl

cargo run -p vibemeasure-cli -- report --db vibemeasure.sqlite \
  --start 2026-06-01T00:00:00Z --end 2026-06-02T00:00:00Z \
  --currency EUR
```

With the fixture price and exchange rate, 80 uncached input tokens, 20 cached input tokens and 30 output tokens cost an estimated USD 0.000408 or EUR 0.000204. JSON exposes the amount and its sources under `costs.codex`. XLSX and PDF exports show the estimate alongside the usage source.

`--base` defaults to USD. The report supports direct USD pairs, inverse pairs and conversions through EUR. Saving a rate replaces the stored value for the same ordered currency pair. The ECB refresh also updates its EUR pairs. Estimates use the prices and rates available at report generation, including for historical usage. If any event lacks pricing evidence or conversion is unavailable, the tool's total cost is marked unknown.

