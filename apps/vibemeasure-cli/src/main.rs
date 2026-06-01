use std::{path::PathBuf, process::ExitCode};

use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand, ValueEnum};
use vibemeasure_core::{
    adapters::codex::parse_codex_jsonl,
    catalog::required_tools,
    currency::fetch_ecb_daily_rates,
    model::DisplayMode,
    reports::{ReportRequest, build_usage_report, export_pdf, export_xlsx},
    snapshot::build_widget_snapshot,
    store::VibeStore,
    windows::comparison_range,
};

#[derive(Parser)]
#[command(name = "vibemeasure")]
#[command(about = "Local-first token and usage monitor core tooling")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Catalog,
    InitDb {
        #[arg(long)]
        db: PathBuf,
    },
    ImportCodex {
        #[arg(long)]
        db: PathBuf,
        #[arg(long)]
        jsonl: PathBuf,
    },
    Snapshot {
        #[arg(long)]
        db: PathBuf,
        #[arg(long, value_enum, default_value_t = CliDisplayMode::ProviderCycles)]
        mode: CliDisplayMode,
    },
    RefreshEcbRates {
        #[arg(long)]
        db: PathBuf,
    },
    Report {
        #[arg(long)]
        db: PathBuf,
        #[arg(long)]
        start: String,
        #[arg(long)]
        end: String,
        #[arg(long, default_value = "USD")]
        currency: String,
        #[arg(long)]
        xlsx: Option<PathBuf>,
        #[arg(long)]
        pdf: Option<PathBuf>,
    },
}

#[derive(Clone, Debug, ValueEnum)]
enum CliDisplayMode {
    ProviderCycles,
    FiveHours,
    OneWeek,
    OneMonth,
}

impl From<CliDisplayMode> for DisplayMode {
    fn from(value: CliDisplayMode) -> Self {
        match value {
            CliDisplayMode::ProviderCycles => Self::ProviderCycles,
            CliDisplayMode::FiveHours => Self::FiveHours,
            CliDisplayMode::OneWeek => Self::OneWeek,
            CliDisplayMode::OneMonth => Self::OneMonth,
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::from(1)
        }
    }
}

fn run() -> vibemeasure_core::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::Catalog => {
            println!("{}", serde_json::to_string_pretty(&catalog_json())?);
        }
        Command::InitDb { db } => {
            VibeStore::open(db)?;
            println!("database initialized");
        }
        Command::ImportCodex { db, jsonl } => {
            let store = VibeStore::open(db)?;
            let output = parse_codex_jsonl(&jsonl)?;
            for event in &output.usage_events {
                store.insert_usage_event(event)?;
            }
            for window in &output.limit_windows {
                store.insert_limit_window(window)?;
            }
            println!(
                "imported {} usage events and {} limit windows",
                output.usage_events.len(),
                output.limit_windows.len()
            );
        }
        Command::Snapshot { db, mode } => {
            let store = VibeStore::open(db)?;
            let mode = DisplayMode::from(mode);
            let now = Utc::now();
            let usage_events = if let Some((start, end)) = comparison_range(&mode, now) {
                store.usage_between(start, end)?
            } else {
                store.usage_between(
                    now - chrono::Duration::days(31),
                    now + chrono::Duration::minutes(1),
                )?
            };
            let windows = store.latest_limit_windows()?;
            let snapshot = build_widget_snapshot(mode, now, &usage_events, &windows);
            println!("{}", serde_json::to_string_pretty(&snapshot)?);
        }
        Command::RefreshEcbRates { db } => {
            let store = VibeStore::open(db)?;
            let rates = fetch_ecb_daily_rates()?;
            for rate in &rates {
                store.save_currency_rate(rate)?;
            }
            println!("saved {} ECB reference rates", rates.len());
        }
        Command::Report {
            db,
            start,
            end,
            currency,
            xlsx,
            pdf,
        } => {
            let store = VibeStore::open(db)?;
            let starts_at = parse_datetime(&start)?;
            let ends_at = parse_datetime(&end)?;
            let events = store.usage_between(starts_at, ends_at)?;
            let report = build_usage_report(
                ReportRequest {
                    starts_at,
                    ends_at,
                    currency,
                },
                &events,
            );
            if let Some(path) = xlsx {
                export_xlsx(&report, path)?;
            }
            if let Some(path) = pdf {
                export_pdf(&report, path)?;
            }
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
    }

    Ok(())
}

fn parse_datetime(value: &str) -> vibemeasure_core::Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| {
            vibemeasure_core::VibeError::InvalidData(format!("invalid datetime: {error}"))
        })
}

fn catalog_json() -> Vec<serde_json::Value> {
    required_tools()
        .into_iter()
        .map(|tool| {
            serde_json::json!({
                "id": tool.id,
                "display_name": tool.display_name,
                "command_hint": tool.command_hint,
                "status": "manual_or_adapter_pending_unless_verified_locally"
            })
        })
        .collect()
}
