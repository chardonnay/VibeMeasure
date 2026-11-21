use serde::{Deserialize, Serialize};

use crate::model::{CurrencyRate, PricingRule, SourceKind, SourceMeta, SourceStatus, UsageEvent};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ReportCost {
    ApiEquivalentEstimate {
        amount: f64,
        pricing_sources: Vec<SourceMeta>,
        exchange_rate_sources: Vec<SourceMeta>,
    },
    Unknown {
        reason: String,
    },
}

impl ReportCost {
    pub(super) fn amount(&self) -> Option<f64> {
        match self {
            Self::ApiEquivalentEstimate { amount, .. } => Some(*amount),
            Self::Unknown { .. } => None,
        }
    }

    pub(super) fn description(&self) -> String {
        match self {
            Self::ApiEquivalentEstimate {
                pricing_sources,
                exchange_rate_sources,
                ..
            } => {
                let mut details = vec!["API-equivalent estimate".to_string()];
                for (kind, sources) in [("Price", pricing_sources), ("FX", exchange_rate_sources)] {
                    for source in sources {
                        details.push(format!(
                            "{kind} ({:?}, {:?}): {} [{}]",
                            source.kind, source.status, source.label, source.fetched_at
                        ));
                    }
                }
                details.join("; ")
            }
            Self::Unknown { reason } => format!("Unknown: {reason}"),
        }
    }
}

fn acceptable_source(source: &SourceMeta) -> bool {
    matches!(
        (&source.kind, &source.status),
        (
            SourceKind::OfficialApi | SourceKind::OfficialDocs,
            SourceStatus::Verified
        ) | (SourceKind::Manual, SourceStatus::Manual)
    )
}

fn remember(sources: &mut Vec<SourceMeta>, source: &SourceMeta) {
    if !sources.contains(source) {
        sources.push(source.clone());
    }
}

fn token_cost(tokens: u64, price_per_million: Option<f64>) -> Option<f64> {
    if tokens == 0 {
        return Some(0.0);
    }
    let price = price_per_million.filter(|price| price.is_finite() && *price >= 0.0)?;
    Some((tokens as f64 / 1_000_000.0) * price)
}

fn event_cost(event: &UsageEvent, rule: &PricingRule) -> Option<f64> {
    // Cached input and reasoning output are subsets of their respective totals.
    if event.input_tokens.checked_add(event.output_tokens)? != event.total_tokens
        || event.reasoning_output_tokens > event.output_tokens
    {
        return None;
    }
    let uncached = event.input_tokens.checked_sub(event.cached_input_tokens)?;
    let amount = token_cost(uncached, rule.input_per_million_usd)?
        + token_cost(event.cached_input_tokens, rule.cached_input_per_million_usd)?
        + token_cost(event.output_tokens, rule.output_per_million_usd)?;
    amount.is_finite().then_some(amount)
}

fn rate_between<'a>(
    rates: &'a [CurrencyRate],
    from: &str,
    to: &str,
) -> Option<(f64, &'a SourceMeta)> {
    let valid = |rate: &&CurrencyRate| {
        rate.rate.is_finite() && rate.rate > 0.0 && acceptable_source(&rate.source)
    };
    let mut matching = rates.iter().filter(valid);
    if let Some(rate) = matching.clone().find(|rate| {
        rate.base_currency.eq_ignore_ascii_case(from)
            && rate.quote_currency.eq_ignore_ascii_case(to)
    }) {
        return Some((rate.rate, &rate.source));
    }
    let inverse = matching.find(|rate| {
        rate.base_currency.eq_ignore_ascii_case(to)
            && rate.quote_currency.eq_ignore_ascii_case(from)
    })?;
    Some((1.0 / inverse.rate, &inverse.source))
}

fn exchange_rate(currency: &str, rates: &[CurrencyRate]) -> Option<(f64, Vec<SourceMeta>)> {
    if currency == "USD" {
        return Some((1.0, Vec::new()));
    }
    if let Some((factor, source)) = rate_between(rates, "USD", currency) {
        return Some((factor, vec![source.clone()]));
    }
    let (usd_eur, usd_source) = rate_between(rates, "USD", "EUR")?;
    let (eur_target, target_source) = rate_between(rates, "EUR", currency)?;
    let mut sources = vec![usd_source.clone()];
    remember(&mut sources, target_source);
    Some((usd_eur * eur_target, sources))
}

pub(super) fn estimate(
    events: &[UsageEvent],
    rules: &[PricingRule],
    rates: &[CurrencyRate],
    currency: &str,
) -> ReportCost {
    let unknown = |reason| ReportCost::Unknown { reason };
    let mut total_usd = 0.0;
    let mut pricing_sources = Vec::new();
    for event in events {
        let candidates = rules
            .iter()
            .filter(|rule| rule.tool_id == event.tool_id && acceptable_source(&rule.source));
        // Rules arrive newest first. Prefer a model match over a tool-wide default.
        let rule = candidates
            .clone()
            .find(|rule| rule.model_name.is_some() && rule.model_name == event.model_name)
            .or_else(|| candidates.clone().find(|rule| rule.model_name.is_none()));
        let Some(rule) = rule else {
            return unknown(format!(
                "No applicable price for {}",
                event.model_name.as_deref().unwrap_or("unidentified model")
            ));
        };
        // A UsageEvent identifies a tool and model, but carries no backend provider.
        if candidates.clone().any(|other| {
            other.model_name == rule.model_name && other.provider_name != rule.provider_name
        }) {
            return unknown("Multiple backend providers have applicable prices".into());
        }
        let Some(amount) = event_cost(event, rule) else {
            return unknown(
                "Incomplete token breakdown or missing price for a used token category".into(),
            );
        };
        total_usd += amount;
        remember(&mut pricing_sources, &rule.source);
    }
    let Some((rate, exchange_rate_sources)) = exchange_rate(currency, rates) else {
        return unknown(format!("Missing USD/{currency} exchange rate"));
    };
    let amount = total_usd * rate;
    if !amount.is_finite() || !rate.is_finite() || rate <= 0.0 {
        return unknown("Cost exceeds numeric range".into());
    }
    ReportCost::ApiEquivalentEstimate {
        amount,
        pricing_sources,
        exchange_rate_sources,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn usage() -> UsageEvent {
        let at = Utc.with_ymd_and_hms(2026, 6, 1, 12, 0, 0).unwrap();
        UsageEvent {
            tool_id: "codex".into(),
            model_name: Some("test-model".into()),
            occurred_at: at,
            input_tokens: 1_000_000,
            cached_input_tokens: 250_000,
            output_tokens: 500_000,
            reasoning_output_tokens: 125_000,
            total_tokens: 1_500_000,
            source: SourceMeta::local("test event", at),
        }
    }

    fn price() -> PricingRule {
        let event = usage();
        PricingRule {
            tool_id: event.tool_id,
            provider_name: "test provider".into(),
            model_name: event.model_name,
            input_per_million_usd: Some(2.0),
            cached_input_per_million_usd: Some(0.4),
            output_per_million_usd: Some(8.0),
            billing_window: None,
            source: SourceMeta::manual("manual model price", event.occurred_at),
        }
    }

    #[test]
    fn bills_each_token_once_and_converts_via_eur_using_model_price() {
        let event = usage();
        let rule = price();
        let mut default_price = rule.clone();
        default_price.model_name = None;
        default_price.output_per_million_usd = Some(200.0);
        let rate = |quote: &str, value: f64| CurrencyRate {
            base_currency: "EUR".into(),
            quote_currency: quote.into(),
            rate: value,
            source: SourceMeta::manual(format!("EUR/{quote}"), event.occurred_at),
        };
        let rates = [rate("USD", 2.0), rate("GBP", 0.5)];
        let estimate = estimate(&[event], &[default_price, rule], &rates, "GBP");
        let ReportCost::ApiEquivalentEstimate {
            amount,
            pricing_sources,
            exchange_rate_sources,
        } = estimate
        else {
            panic!("expected estimate");
        };
        assert!((amount - 1.4).abs() < 0.000_001);
        assert_eq!(pricing_sources[0].status, SourceStatus::Manual);
        assert_eq!(exchange_rate_sources.len(), 2);
    }

    #[test]
    fn missing_values_do_not_yield_partial_or_verified_costs() {
        let rule = price();
        let event = usage();
        let missing = |events: &[UsageEvent], rules: &[PricingRule], currency: &str| {
            assert!(matches!(
                estimate(events, rules, &[], currency),
                ReportCost::Unknown { .. }
            ));
        };
        missing(
            std::slice::from_ref(&event),
            std::slice::from_ref(&rule),
            "GBP",
        );
        let mut uncovered = event.clone();
        uncovered.model_name = None;
        missing(
            &[event.clone(), uncovered],
            std::slice::from_ref(&rule),
            "USD",
        );
        let mut incomplete = rule.clone();
        incomplete.cached_input_per_million_usd = None;
        missing(std::slice::from_ref(&event), &[incomplete], "USD");
        let mut unverified = rule.clone();
        unverified.source.status = SourceStatus::Estimated;
        missing(std::slice::from_ref(&event), &[unverified], "USD");
        let mut another_provider = rule.clone();
        another_provider.provider_name = "Other backend".into();
        missing(
            std::slice::from_ref(&event),
            &[rule.clone(), another_provider],
            "USD",
        );
        let mut bad_usage = event;
        bad_usage.total_tokens += 1;
        missing(&[bad_usage], &[rule], "USD");
    }
}
