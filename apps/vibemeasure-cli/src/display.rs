use vibemeasure_core::model::{DisplayMode, WidgetSnapshot, WindowKind};

pub fn snapshot_text(snapshot: &WidgetSnapshot) -> String {
    let period = match snapshot.display_mode {
        DisplayMode::ProviderCycles => "last 31 days",
        DisplayMode::FiveHours => "last 5 hours",
        DisplayMode::OneWeek => "this UTC week",
        DisplayMode::OneMonth => "this UTC month",
    };
    let mut sections = Vec::new();
    for provider in &snapshot.providers {
        if provider.needs_manual_setup {
            continue;
        }
        let mut lines = vec![provider.display_name.clone()];
        if !provider.usage.source_labels.is_empty() {
            lines.push(format!("{} tokens · {period}", provider.usage.total_tokens));
        }
        for window in &provider.windows {
            let label = match window.window_kind {
                WindowKind::FiveHours => "5 hours".into(),
                WindowKind::OneWeek => "1 week".into(),
                WindowKind::OneMonth => "1 month".into(),
                WindowKind::CustomMinutes(minutes) => format!("{minutes} minutes"),
            };
            let used = if let Some(percent) = window.used_percent {
                format!("{percent}% used")
            } else if let (Some(used), Some(limit)) = (window.used_tokens, window.token_limit) {
                format!("{used} / {limit} tokens")
            } else {
                "Usage unavailable".into()
            };
            lines.push(format!(
                "{label} · {used} · resets {} UTC",
                window.reset_at.format("%Y-%m-%d %H:%M")
            ));
        }
        sections.push(lines.join("\n"));
    }
    if sections.is_empty() {
        return "No usage or active quota windows for this period.".into();
    }
    format!(
        "{}\n\nSnapshot · {} UTC",
        sections.join("\n\n"),
        snapshot.generated_at.format("%Y-%m-%d %H:%M")
    )
}
