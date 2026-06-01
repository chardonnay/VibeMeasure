# Pricing And Currency

VibeMeasure separates reported cost, estimated cost, manual pricing, and unknown pricing.

## Pricing Rules

Pricing may come from:

- Official API reported cost.
- Official pricing documentation.
- Manual user entry.
- Estimated API-equivalent calculation.

The app must label which of these was used. It must not silently convert a subscription quota into an API price or vice versa.

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

The initial core parses ECB daily XML rates. ECB rates are reference rates and may not include every user-requested currency. Unsupported currencies require manual entry.

