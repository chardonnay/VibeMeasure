use chrono::{DateTime, Utc};

use crate::{
    catalog::required_tools,
    model::{DisplayMode, LimitWindow, ProviderSnapshot, UsageEvent, WidgetSnapshot, WindowKind},
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
                .cloned()
                .collect::<Vec<_>>();
            let needs_manual_setup = windows.is_empty() && tool_events.is_empty();

            ProviderSnapshot {
                tool_id: tool.id.to_string(),
                display_name: tool.display_name.to_string(),
                windows,
                usage: VibeStore::aggregate_usage(&tool_events, tool.id),
                needs_manual_setup,
            }
        })
        .collect();

    WidgetSnapshot {
        generated_at: now,
        display_mode: mode,
        providers,
    }
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
        assert_eq!(provider("claude").windows, vec![weekly]);
        assert_eq!(provider("codex").windows, vec![codex]);
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
