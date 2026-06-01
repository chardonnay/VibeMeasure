use std::{collections::BTreeMap, fs, path::Path};

use chrono::{DateTime, Utc};
use rust_xlsxwriter::{Format, Workbook};
use serde::{Deserialize, Serialize};

use crate::{
    Result,
    catalog::tool_by_id,
    model::{UsageEvent, UsageSummary},
    store::VibeStore,
};

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
    pub notes: Vec<String>,
}

pub fn build_usage_report(request: ReportRequest, events: &[UsageEvent]) -> UsageReport {
    let mut by_tool: BTreeMap<String, Vec<UsageEvent>> = BTreeMap::new();
    for event in events {
        by_tool
            .entry(event.tool_id.clone())
            .or_default()
            .push(event.clone());
    }

    let rows = by_tool
        .iter()
        .map(|(tool_id, events)| VibeStore::aggregate_usage(events, tool_id))
        .collect::<Vec<_>>();

    UsageReport {
        request,
        rows,
        notes: vec![
            "Costs are omitted unless a verified official API value or manual pricing rule is present."
                .to_string(),
            "Unknown provider limits are not guessed; configure them manually in settings.".to_string(),
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
    }

    lines.push(String::new());
    lines.extend(report.notes.iter().cloned());

    fs::write(path, minimal_pdf(&lines))?;
    Ok(())
}

fn minimal_pdf(lines: &[String]) -> Vec<u8> {
    let mut content = String::from("BT\n/F1 12 Tf\n50 780 Td\n14 TL\n");
    for line in lines {
        content.push('(');
        content.push_str(&escape_pdf_text(line));
        content.push_str(") Tj\nT*\n");
    }
    content.push_str("ET\n");

    let objects = [
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".to_string(),
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n".to_string(),
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n".to_string(),
        "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n".to_string(),
        format!(
            "5 0 obj\n<< /Length {} >>\nstream\n{}endstream\nendobj\n",
            content.len(),
            content
        ),
    ];

    let mut pdf = String::from("%PDF-1.4\n");
    let mut offsets = Vec::with_capacity(objects.len());
    for object in &objects {
        offsets.push(pdf.len());
        pdf.push_str(object);
    }
    let xref_start = pdf.len();
    pdf.push_str("xref\n0 6\n0000000000 65535 f \n");
    for offset in offsets {
        pdf.push_str(&format!("{offset:010} 00000 n \n"));
    }
    pdf.push_str("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n");
    pdf.push_str(&xref_start.to_string());
    pdf.push_str("\n%%EOF\n");
    pdf.into_bytes()
}

fn escape_pdf_text(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('(', "\\(")
        .replace(')', "\\)")
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
        assert!(std::fs::read(pdf).unwrap().starts_with(b"%PDF-1.4"));
    }
}
