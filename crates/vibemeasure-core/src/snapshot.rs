use chrono::{DateTime, Utc};

use crate::{
    catalog::required_tools,
    model::{DisplayMode, LimitWindow, ProviderSnapshot, UsageEvent, WidgetSnapshot},
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
                .filter(|window| window.tool_id == tool.id)
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
