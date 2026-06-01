use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DisplayMode {
    #[default]
    ProviderCycles,
    FiveHours,
    OneWeek,
    OneMonth,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThemeMode {
    System,
    Light,
    Dark,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    LocalEvidence,
    OfficialApi,
    OfficialDocs,
    Manual,
    Unknown,
    TestDouble,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceStatus {
    Verified,
    Estimated,
    Manual,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SourceMeta {
    pub kind: SourceKind,
    pub status: SourceStatus,
    pub label: String,
    pub fetched_at: DateTime<Utc>,
}

impl SourceMeta {
    pub fn local(label: impl Into<String>, fetched_at: DateTime<Utc>) -> Self {
        Self {
            kind: SourceKind::LocalEvidence,
            status: SourceStatus::Verified,
            label: label.into(),
            fetched_at,
        }
    }

    pub fn manual(label: impl Into<String>, fetched_at: DateTime<Utc>) -> Self {
        Self {
            kind: SourceKind::Manual,
            status: SourceStatus::Manual,
            label: label.into(),
            fetched_at,
        }
    }

    pub fn unknown(label: impl Into<String>, fetched_at: DateTime<Utc>) -> Self {
        Self {
            kind: SourceKind::Unknown,
            status: SourceStatus::Unknown,
            label: label.into(),
            fetched_at,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowKind {
    FiveHours,
    OneWeek,
    OneMonth,
    CustomMinutes(i64),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageEvent {
    pub tool_id: String,
    pub occurred_at: DateTime<Utc>,
    pub model_name: Option<String>,
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_output_tokens: u64,
    pub total_tokens: u64,
    pub source: SourceMeta,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LimitWindow {
    pub tool_id: String,
    pub window_kind: WindowKind,
    pub starts_at: DateTime<Utc>,
    pub ends_at: DateTime<Utc>,
    pub reset_at: DateTime<Utc>,
    pub used_percent: Option<f64>,
    pub used_tokens: Option<u64>,
    pub token_limit: Option<u64>,
    pub source: SourceMeta,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PricingRule {
    pub tool_id: String,
    pub provider_name: String,
    pub model_name: Option<String>,
    pub input_per_million_usd: Option<f64>,
    pub cached_input_per_million_usd: Option<f64>,
    pub output_per_million_usd: Option<f64>,
    pub billing_window: Option<WindowKind>,
    pub source: SourceMeta,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CurrencyRate {
    pub base_currency: String,
    pub quote_currency: String,
    pub rate: f64,
    pub source: SourceMeta,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageSummary {
    pub tool_id: String,
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_output_tokens: u64,
    pub total_tokens: u64,
    pub source_labels: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProviderSnapshot {
    pub tool_id: String,
    pub display_name: String,
    pub windows: Vec<LimitWindow>,
    pub usage: UsageSummary,
    pub needs_manual_setup: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WidgetSnapshot {
    pub generated_at: DateTime<Utc>,
    pub display_mode: DisplayMode,
    pub providers: Vec<ProviderSnapshot>,
}
