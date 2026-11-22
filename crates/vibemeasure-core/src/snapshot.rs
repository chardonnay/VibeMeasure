use chrono::{DateTime, Duration, Utc};

use crate::{
    Result,
    adapters::additional,
    catalog::required_tools,
    model::{
        DisplayMode, LimitWindow, ProviderSnapshot, SnapshotWindow, UsageEvent, WidgetSnapshot,
        WindowKind,
    },
    reports::costs::estimate,
    store::VibeStore,
    windows::comparison_range,
};

pub fn build_widget_snapshot(
    mode: DisplayMode,
    now: DateTime<Utc>,
    usage_events: &[UsageEvent],
    limit_windows: &[LimitWindow],
) -> WidgetSnapshot {
    let providers = required_tools()
        .into_iter()
        .map(|tool| {
            let tool_events = if let Some((start, end)) = comparison_range(&mode, now) {
                usage_events
                    .iter()
                    .filter(|event| {
                        event.tool_id == tool.id
                            && event.occurred_at >= start
                            && event.occurred_at < end
                    })
                    .cloned()
                    .collect::<Vec<_>>()
            } else {
                usage_events
                    .iter()
                    .filter(|event| event.tool_id == tool.id)
                    .cloned()
                    .collect::<Vec<_>>()
            };
            let windows = limit_windows
                .iter()
                .filter(|window| {
                    mode == DisplayMode::ProviderCycles
                        && window.tool_id == tool.id
                        && (tool.id != "claude" || window.window_kind == WindowKind::OneWeek)
                        && window.source.fetched_at <= now
                        && window.starts_at <= now
                        && now < window.ends_at
                        && now < window.reset_at
                })
                .map(|window| SnapshotWindow {
                    limit: window.clone(),
                    estimated_cost: None,
                })
                .collect::<Vec<_>>();
            let needs_manual_setup = windows.is_empty() && tool_events.is_empty();

            ProviderSnapshot {
                tool_id: tool.id.to_string(),
                display_name: tool.display_name.to_string(),
                windows,
                usage: VibeStore::aggregate_usage(&tool_events, tool.id),
                needs_manual_setup,
                plan: None,
                estimated_cost: None,
                reported: None,
            }
        })
        .collect();

    WidgetSnapshot {
        generated_at: now,
        display_mode: mode,
        providers,
        currency: None,
    }
}

pub fn read_widget_snapshot(
    store: &VibeStore,
    mode: DisplayMode,
    now: DateTime<Utc>,
    currency: &str,
) -> Result<WidgetSnapshot> {
    let (start, end) = comparison_range(&mode, now).unwrap_or((now - Duration::days(31), now));
    let windows = if mode == DisplayMode::ProviderCycles {
        store.active_limit_windows_at(now)?
    } else {
        Vec::new()
    };
    let earliest = windows
        .iter()
        .filter(|window| window.tool_id != "claude" || window.window_kind == WindowKind::OneWeek)
        .fold(start, |date, window| date.min(window.starts_at));
    let events = store.usage_between(earliest, end)?;
    let display_events = &events[events.partition_point(|event| event.occurred_at < start)..];
    let mut snapshot = build_widget_snapshot(mode, now, display_events, &windows);
    let (rules, rates) = store.report_pricing()?;
    let readings = additional::load(store)?;
    snapshot.currency = Some(currency.to_owned());

    for provider in &mut snapshot.providers {
        provider.plan = store.provider_plan(&provider.tool_id, now)?;
        if let Some(reading) = readings.get(&provider.tool_id) {
            if let Some(plan) = reading.plan() {
                provider.plan = Some(plan);
            }
            provider.reported = reading.reported(&provider.tool_id, now);
            if let Some(tokens) = reading.dated_tokens(start, end)
                && let Some(reported) = &provider.reported
            {
                provider.usage.total_tokens = provider.usage.total_tokens.saturating_add(tokens);
                provider
                    .usage
                    .source_labels
                    .push(reported.source.label.clone());
            }
        }
        if provider.needs_manual_setup {
            provider.needs_manual_setup = provider.reported.is_none();
            continue;
        }
        let tool = provider.tool_id.as_str();
        let usage_in = |range_start, range_end| {
            events.iter().filter(move |event| {
                event.tool_id == tool
                    && event.occurred_at >= range_start
                    && event.occurred_at < range_end
            })
        };
        provider.estimated_cost = Some(estimate(usage_in(start, end), &rules, &rates, currency));
        for window in &mut provider.windows {
            window.estimated_cost = Some(estimate(
                usage_in(window.limit.starts_at, now),
                &rules,
                &rates,
                currency,
            ));
        }
    }
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, Utc};

    use super::*;
    use crate::model::SourceMeta;

    #[test]
    fn provider_cycles_show_only_weekly_claude_quota_and_comparisons_show_no_quotas() {
        let now = Utc::now();
        let weekly = LimitWindow {
            tool_id: "claude".to_string(),
            window_kind: WindowKind::OneWeek,
            starts_at: now - Duration::days(1),
            ends_at: now + Duration::days(6),
            reset_at: now + Duration::days(6),
            used_percent: Some(20.0),
            used_tokens: None,
            token_limit: None,
            source: SourceMeta::manual("legacy window", now),
        };
        let mut short = weekly.clone();
        short.window_kind = WindowKind::FiveHours;
        let mut codex = short.clone();
        codex.tool_id = "codex".into();
        let windows = vec![weekly.clone(), short, codex.clone()];
        let snapshot = build_widget_snapshot(DisplayMode::ProviderCycles, now, &[], &windows);
        let provider = |id| snapshot.providers.iter().find(|p| p.tool_id == id).unwrap();
        assert_eq!(provider("claude").windows.len(), 1);
        assert_eq!(provider("claude").windows[0].limit, weekly);
        assert_eq!(provider("codex").windows.len(), 1);
        assert_eq!(provider("codex").windows[0].limit, codex);
        for mode in [
            DisplayMode::FiveHours,
            DisplayMode::OneWeek,
            DisplayMode::OneMonth,
        ] {
            let snapshot = build_widget_snapshot(mode, now, &[], &windows);
            assert!(
                snapshot
                    .providers
                    .iter()
                    .all(|p| p.windows.is_empty() && p.needs_manual_setup)
            );
        }
    }
}
