use std::collections::BTreeMap;

use chrono::{DateTime, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::{
    Result, VibeError,
    adapters::additional,
    catalog::required_tools,
    model::{DisplayMode, ProviderSnapshot, WindowKind},
    snapshot::build_widget_snapshot,
    store::VibeStore,
};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct AlertRule {
    pub end_date: Option<NaiveDate>,
    pub days_before: Option<u16>,
    pub used_percent: Option<u8>,
}

impl AlertRule {
    pub fn save(&self, store: &VibeStore, tool: &str) -> Result<()> {
        if !required_tools().iter().any(|entry| entry.id == tool) {
            return Err(VibeError::InvalidData(format!("unknown provider: {tool}")));
        }
        if self.used_percent.is_some_and(|p| !(1..=100).contains(&p))
            || self
                .days_before
                .is_some_and(|d| d > 365 || self.end_date.is_none())
        {
            return Err(VibeError::InvalidData(
                "choose 1–100 percent and an end date for a reminder 0–365 days in advance".into(),
            ));
        }
        store.save_setting(&format!("alert.rule.{tool}"), self)
    }

    pub fn load(store: &VibeStore, tool: &str) -> Result<Self> {
        Ok(store
            .load_setting(&format!("alert.rule.{tool}"))?
            .unwrap_or_default())
    }

    fn enabled(&self) -> bool {
        self.days_before.is_some() || self.used_percent.is_some()
    }
}

// Each entry remembers the last delivered cycle. An unknown reading leaves the
// entry intact. For undated quotas only a measured drop below the limit rearms it.
type Receipts = BTreeMap<String, String>;

pub fn check_alerts(
    store: &VibeStore,
    now: DateTime<Utc>,
    mut deliver: impl FnMut(&str) -> Result<()>,
) -> Result<()> {
    let today = now.with_timezone(&Local).date_naive();
    let mut snapshot = None;
    for tool in required_tools() {
        let rule = AlertRule::load(store, tool.id)?;
        if !rule.enabled() {
            continue;
        }
        if rule.used_percent.is_some() && snapshot.is_none() {
            let windows = store.active_limit_windows_at(now)?;
            let mut quotas = build_widget_snapshot(DisplayMode::ProviderCycles, now, &[], &windows);
            let readings = additional::load(store)?;
            for provider in &mut quotas.providers {
                if let Some(reading) = readings.get(&provider.tool_id) {
                    provider.reported = reading.reported(&provider.tool_id, now);
                }
            }
            snapshot = Some(quotas);
        }
        let provider = snapshot
            .as_ref()
            .and_then(|s| s.providers.iter().find(|p| p.tool_id == tool.id));
        // Serialize check and acknowledgement across simultaneous widget instances.
        store.with_immediate_transaction(|| {
            if AlertRule::load(store, tool.id)? != rule {
                return Ok(());
            }
            let key = format!("alert.receipts.{}", tool.id);
            let previous: Receipts = store.load_setting(&key)?.unwrap_or_default();
            let mut receipts = previous.clone();
            let messages = evaluate(&rule, tool.display_name, today, provider, &mut receipts);
            if !messages.is_empty() {
                deliver(&messages.join("\n"))?;
            }
            if receipts != previous {
                store.save_setting(&key, &receipts)?;
            }
            Ok(())
        })?;
    }
    Ok(())
}

fn evaluate(
    rule: &AlertRule,
    name: &str,
    today: NaiveDate,
    provider: Option<&ProviderSnapshot>,
    receipts: &mut Receipts,
) -> Vec<String> {
    let mut messages = Vec::new();
    if let (Some(end), Some(days)) = (rule.end_date, rule.days_before) {
        let remaining = (end - today).num_days();
        let cycle = end.to_string();
        if (0..=i64::from(days)).contains(&remaining) && receipts.get("end") != Some(&cycle) {
            messages.push(format!(
                "{name} subscription ends {end} ({remaining} days remaining)."
            ));
            receipts.insert("end".into(), cycle);
        }
    }
    let (Some(threshold), Some(provider)) = (rule.used_percent, provider) else {
        return messages;
    };
    let mut check = |key: String, label: &str, used: Option<f64>, reset: Option<DateTime<Utc>>| {
        let Some(used) = used.filter(|p| p.is_finite() && *p >= 0.0) else {
            return;
        };
        let cycle = format!(
            "{threshold}/{}",
            reset.map(|t| t.timestamp().to_string()).unwrap_or_default()
        );
        if used + 1e-10 < f64::from(threshold) {
            if reset.is_none() {
                receipts.remove(&key);
            }
        } else if receipts.get(&key) != Some(&cycle) {
            messages.push(format!(
                "{name} · {label}: {used:.1}% used (threshold {threshold}%)."
            ));
            receipts.insert(key, cycle);
        }
    };
    for window in &provider.windows {
        let limit = &window.limit;
        let label = match limit.window_kind {
            WindowKind::FiveHours => "5 hours".into(),
            WindowKind::OneWeek => "1 week".into(),
            WindowKind::OneMonth => "1 month".into(),
            WindowKind::CustomMinutes(n) => format!("{n} minutes"),
        };
        let used = limit.used_percent.or_else(|| {
            let total = limit.token_limit.filter(|n| *n > 0)?;
            Some(100.0 * limit.used_tokens? as f64 / total as f64)
        });
        check(
            format!("window/{label}"),
            &label,
            used,
            Some(limit.reset_at),
        );
    }
    if let Some(reported) = &provider.reported {
        for quota in &reported.quotas {
            check(
                format!("quota/{}", quota.name),
                &quota.name,
                quota.used_percent,
                quota.resets_at,
            );
        }
    }
    messages
}
