use std::{collections::BTreeMap, fs, path::Path};

use chrono::{DateTime, Utc};
use rust_xlsxwriter::{Format, Workbook};
use serde::{Deserialize, Serialize};

use crate::{
    Result,
    catalog::tool_by_id,
    model::{CurrencyRate, PricingRule, UsageEvent, UsageSummary},
    store::VibeStore,
};

mod costs;
mod pdf;
pub use costs::ReportCost;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReportRequest {
    pub starts_at: DateTime<Utc>,
    pub ends_at: DateTime<Utc>,
    pub currency: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageReport {
    pub request: ReportRequest,
    pub rows: Vec<UsageSummary>,
    #[serde(default)]
    pub costs: BTreeMap<String, ReportCost>,
    pub notes: Vec<String>,
}

pub fn build_usage_report(request: ReportRequest, events: &[UsageEvent]) -> UsageReport {
    build_priced_usage_report(request, events, &[], &[])
}

pub fn build_priced_usage_report(
    mut request: ReportRequest,
    events: &[UsageEvent],
    rules: &[PricingRule],
    rates: &[CurrencyRate],
) -> UsageReport {
    request.currency = request.currency.trim().to_ascii_uppercase();
    let mut by_tool: BTreeMap<String, Vec<UsageEvent>> = BTreeMap::new();
    for event in events.iter().filter(|event| {
        event.occurred_at >= request.starts_at && event.occurred_at < request.ends_at
    }) {
        by_tool
            .entry(event.tool_id.clone())
            .or_default()
            .push(event.clone());
    }

    let mut rows = Vec::with_capacity(by_tool.len());
    let mut costs = BTreeMap::new();
    for (tool_id, events) in by_tool {
        rows.push(VibeStore::aggregate_usage(&events, &tool_id));
        costs.insert(
            tool_id,
            costs::estimate(&events, rules, rates, &request.currency),
        );
    }

    UsageReport {
        request,
        rows,
        costs,
        notes: vec![
            "API-equivalent estimates use the configured token prices and exchange rates at report generation. Provider invoices and subscription charges are separate.".to_string(),
        ],
    }
}

pub fn export_xlsx(report: &UsageReport, path: impl AsRef<Path>) -> Result<()> {
    let mut workbook = Workbook::new();
    let worksheet = workbook.add_worksheet();
    worksheet.set_name("Usage")?;

    let header = Format::new().set_bold();
    for (col, value) in [
        "Tool",
        "Tool ID",
        "Input tokens",
        "Cached input tokens",
        "Output tokens",
        "Reasoning output tokens",
        "Total tokens",
        "Source notes",
        "Estimated cost",
        "Currency",
        "Cost status and sources",
    ]
    .into_iter()
    .enumerate()
    {
        worksheet.write_string_with_format(0, col as u16, value, &header)?;
    }

    for (row_index, row) in report.rows.iter().enumerate() {
        let row_number = (row_index + 1) as u32;
        let display_name = tool_by_id(&row.tool_id)
            .map(|tool| tool.display_name.to_string())
            .unwrap_or_else(|| row.tool_id.clone());
        worksheet.write_string(row_number, 0, &display_name)?;
        worksheet.write_string(row_number, 1, &row.tool_id)?;
        worksheet.write_number(row_number, 2, row.input_tokens as f64)?;
        worksheet.write_number(row_number, 3, row.cached_input_tokens as f64)?;
        worksheet.write_number(row_number, 4, row.output_tokens as f64)?;
        worksheet.write_number(row_number, 5, row.reasoning_output_tokens as f64)?;
        worksheet.write_number(row_number, 6, row.total_tokens as f64)?;
        worksheet.write_string(row_number, 7, row.source_labels.join("; "))?;
        if let Some(cost) = report.costs.get(&row.tool_id) {
            if let Some(amount) = cost.amount() {
                worksheet.write_number(row_number, 8, amount)?;
            }
            worksheet.write_string(row_number, 10, cost.description())?;
        }
        worksheet.write_string(row_number, 9, &report.request.currency)?;
    }

    worksheet.autofit();
    workbook.save(path)?;
    Ok(())
}

pub fn export_pdf(report: &UsageReport, path: impl AsRef<Path>) -> Result<()> {
    let mut lines = vec![
        "VibeMeasure Usage Report".to_string(),
        format!("From: {}", report.request.starts_at.to_rfc3339()),
        format!("To: {}", report.request.ends_at.to_rfc3339()),
        format!("Currency: {}", report.request.currency),
        String::new(),
    ];

    for row in &report.rows {
        let display_name = tool_by_id(&row.tool_id)
            .map(|tool| tool.display_name.to_string())
            .unwrap_or_else(|| row.tool_id.clone());
        lines.push(format!("{display_name}: {} total tokens", row.total_tokens));
        lines.push(format!("Usage source: {}", row.source_labels.join("; ")));
        if let Some(cost) = report.costs.get(&row.tool_id) {
            let amount = cost
                .amount()
                .map(|value| format!("{value} {}. ", report.request.currency))
                .unwrap_or_default();
            lines.push(format!("Cost: {amount}{}", cost.description()));
        }
        lines.push(String::new());
    }

    lines.push(String::new());
    lines.extend(report.notes.iter().cloned());

    fs::write(path, pdf::document(&lines))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use crate::{
        model::{SourceMeta, UsageEvent},
        reports::{ReportRequest, build_usage_report, export_pdf, export_xlsx},
    };

    #[test]
    fn exports_report_files() {
        let temp = tempfile::tempdir().unwrap();
        let now = Utc.with_ymd_and_hms(2026, 6, 1, 10, 0, 0).single().unwrap();
        let report = build_usage_report(
            ReportRequest {
                starts_at: now,
                ends_at: now + chrono::Duration::hours(1),
                currency: "USD".to_string(),
            },
            &[UsageEvent {
                tool_id: "codex".to_string(),
                occurred_at: now,
                model_name: None,
                input_tokens: 1,
                cached_input_tokens: 2,
                output_tokens: 3,
                reasoning_output_tokens: 4,
                total_tokens: 10,
                source: SourceMeta::local("test double", now),
            }],
        );

        let xlsx = temp.path().join("report.xlsx");
        let pdf = temp.path().join("report.pdf");
        export_xlsx(&report, &xlsx).unwrap();
        export_pdf(&report, &pdf).unwrap();

        assert!(std::fs::metadata(xlsx).unwrap().len() > 0);
        let pdf = std::fs::read_to_string(pdf).unwrap();
        assert!(pdf.starts_with("%PDF-1.4"));
        assert!(pdf.contains("Usage source: test double"));
        assert!(pdf.contains("Unknown: No applicable price"));
    }

    #[test]
    fn report_builder_applies_half_open_dates_to_usage_and_costs() {
        let now = Utc.with_ymd_and_hms(2026, 6, 1, 0, 0, 0).unwrap();
        let end = now + chrono::Duration::hours(1);
        let event = UsageEvent {
            tool_id: "codex".into(),
            occurred_at: now,
            model_name: None,
            input_tokens: 1,
            cached_input_tokens: 0,
            output_tokens: 0,
            reasoning_output_tokens: 0,
            total_tokens: 1,
            source: SourceMeta::local("test event", now),
        };
        let events = [
            event.clone(),
            UsageEvent {
                occurred_at: end,
                ..event
            },
        ];
        let report = build_usage_report(
            ReportRequest {
                starts_at: now,
                ends_at: end,
                currency: " eur ".into(),
            },
            &events,
        );
        assert_eq!(report.request.currency, "EUR");
        assert_eq!(report.rows[0].total_tokens, 1);
        assert!(report.costs.contains_key("codex"));
    }
}
