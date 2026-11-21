use std::path::PathBuf;

use chrono::Utc;
use clap::Args;
use vibemeasure_core::{
    Result, VibeError,
    catalog::tool_by_id,
    model::{CurrencyRate, PricingRule, SourceMeta},
    store::VibeStore,
};

#[derive(Args)]
pub struct SetPrice {
    #[arg(long)]
    db: PathBuf,
    /// Tool ID as shown by the catalog command.
    #[arg(long)]
    tool: String,
    #[arg(long, value_parser = nonempty)]
    provider: String,
    /// Omit to set a tool-wide default.
    #[arg(long, value_parser = nonempty)]
    model: Option<String>,
    /// USD per million uncached input tokens.
    #[arg(long, value_parser = price)]
    input: Option<f64>,
    /// USD per million cached input tokens.
    #[arg(long, value_parser = price)]
    cached_input: Option<f64>,
    /// USD per million output tokens, including reasoning.
    #[arg(long, value_parser = price)]
    output: Option<f64>,
    /// Label identifying the source of this manual price.
    #[arg(long, value_parser = nonempty, default_value = "Manual CLI price")]
    source: String,
}

impl SetPrice {
    pub fn save(self) -> Result<()> {
        if tool_by_id(&self.tool).is_none() {
            return Err(VibeError::InvalidData(format!(
                "unknown catalog tool: {}",
                self.tool
            )));
        }
        if self.input.is_none() && self.cached_input.is_none() && self.output.is_none() {
            return Err(VibeError::InvalidData(
                "supply at least one price: --input, --cached-input, or --output".into(),
            ));
        }
        VibeStore::open(&self.db)?.save_pricing_rule(&PricingRule {
            tool_id: self.tool,
            provider_name: self.provider,
            model_name: self.model,
            input_per_million_usd: self.input,
            cached_input_per_million_usd: self.cached_input,
            output_per_million_usd: self.output,
            billing_window: None,
            source: SourceMeta::manual(self.source, Utc::now()),
        })
    }
}

#[derive(Args)]
pub struct SetRate {
    #[arg(long)]
    db: PathBuf,
    /// Currency in which one unit is valued.
    #[arg(long, value_parser = currency_code, default_value = "USD")]
    base: String,
    /// Currency in which the rate is expressed.
    #[arg(long, value_parser = currency_code)]
    quote: String,
    /// Units of the quote currency for one unit of the base currency.
    #[arg(long, value_parser = positive_rate)]
    rate: f64,
    #[arg(long, value_parser = nonempty, default_value = "Manual CLI exchange rate")]
    source: String,
}

impl SetRate {
    pub fn save(self) -> Result<()> {
        if self.base == self.quote {
            return Err(VibeError::InvalidData(
                "choose two different currencies".into(),
            ));
        }
        VibeStore::open(&self.db)?.save_currency_rate(&CurrencyRate {
            base_currency: self.base,
            quote_currency: self.quote,
            rate: self.rate,
            source: SourceMeta::manual(self.source, Utc::now()),
        })
    }
}

pub fn currency_code(value: &str) -> std::result::Result<String, String> {
    let value = value.trim().to_ascii_uppercase();
    if value.len() == 3 && value.bytes().all(|byte| byte.is_ascii_uppercase()) {
        Ok(value)
    } else {
        Err("expected a three-letter currency code".into())
    }
}

fn nonempty(value: &str) -> std::result::Result<String, String> {
    if value.trim().is_empty() {
        Err("expected a nonempty value".into())
    } else {
        Ok(value.trim().to_owned())
    }
}

fn price(value: &str) -> std::result::Result<f64, String> {
    value
        .parse::<f64>()
        .ok()
        .filter(|value| value.is_finite() && *value >= 0.0)
        .ok_or_else(|| "expected a finite nonnegative price".into())
}

fn positive_rate(value: &str) -> std::result::Result<f64, String> {
    price(value)
        .ok()
        .filter(|value| *value > 0.0)
        .ok_or_else(|| "expected a finite exchange rate greater than zero".into())
}
