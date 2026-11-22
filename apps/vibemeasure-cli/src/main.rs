mod alerts;
mod display;
mod pricing;

use std::{path::PathBuf, process::ExitCode};

use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand, ValueEnum};
use vibemeasure_core::{
    adapters::additional,
    adapters::codex::{import_codex_file, sync_codex_sessions},
    catalog::required_tools,
    currency::fetch_ecb_daily_rates,
    model::DisplayMode,
    reports::{ReportRequest, build_priced_usage_report, export_pdf, export_xlsx},
    snapshot::read_widget_snapshot,
    store::VibeStore,
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
    /// List per-provider notification settings, or open the Linux desktop editor.
    AlertSettings {
        #[arg(long)]
        db: PathBuf,
        #[arg(long)]
        edit: bool,
    },
    /// Replace a provider's alert settings. Omit a threshold to disable that warning.
    SetAlert(alerts::SetAlert),
    /// Deliver newly due alerts through the desktop notification service.
    CheckAlerts {
        #[arg(long)]
        db: PathBuf,
        #[arg(long, hide = true)]
        desktop_pipe: bool,
    },
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
    /// Import new or changed Codex logs from the last 31 days and print a JSON summary.
    SyncCodex {
        #[arg(long)]
        db: PathBuf,
        #[arg(long)]
        codex_home: PathBuf,
    },
    /// Refresh the six additional providers from local records and available account sources.
    SyncProviders {
        #[arg(long)]
        db: PathBuf,
    },
    Snapshot {
        #[arg(long)]
        db: PathBuf,
        #[arg(long, value_enum, default_value_t = CliDisplayMode::ProviderCycles)]
        mode: CliDisplayMode,
        #[arg(long, default_value = "USD", value_parser = pricing::currency_code)]
        currency: String,
        /// Print human-readable live usage for desktop widgets.
        #[arg(long)]
        text: bool,
    },
    /// Store manual USD prices per million tokens.
    SetPrice(pricing::SetPrice),
    /// Store a plan label from your subscription settings.
    SetPlan(pricing::SetPlan),
    /// Store a manual exchange rate for report estimates.
    SetRate(pricing::SetRate),
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
        #[arg(long, default_value = "USD", value_parser = pricing::currency_code)]
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
        Command::AlertSettings { db, edit } => alerts::settings(&db, edit)?,
        Command::SetAlert(rule) => rule.save()?,
        Command::CheckAlerts { db, desktop_pipe } => alerts::poll(&db, desktop_pipe)?,
        Command::Catalog => {
            println!("{}", serde_json::to_string_pretty(&catalog_json())?);
        }
        Command::InitDb { db } => {
            VibeStore::open(db)?;
            println!("database initialized");
        }
        Command::ImportCodex { db, jsonl } => {
            let store = VibeStore::open(db)?;
            let (events, windows) = import_codex_file(&store, &jsonl)?;
            println!("imported {events} usage events and {windows} limit windows");
        }
        Command::SyncCodex { db, codex_home } => {
            let result = sync_codex_sessions(&db, &codex_home)?;
            println!("{}", serde_json::to_string(&result)?);
        }
        Command::SyncProviders { db } => {
            println!("{}", serde_json::to_string(&additional::sync(&db)?)?);
        }
        Command::Snapshot {
            db,
            mode,
            currency,
            text,
        } => {
            let store = VibeStore::open_existing(db)?;
            let snapshot = read_widget_snapshot(&store, mode.into(), Utc::now(), &currency)?;
            if text {
                println!("{}", display::snapshot_text(&snapshot));
            } else {
                println!("{}", serde_json::to_string_pretty(&snapshot)?);
            }
        }
        Command::SetPrice(price) => {
            price.save()?;
            println!("saved manual token prices");
        }
        Command::SetPlan(plan) => {
            plan.save()?;
            println!("saved manual plan");
        }
        Command::SetRate(rate) => {
            rate.save()?;
            println!("saved manual exchange rate");
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
            let starts_at = parse_datetime(&start)?;
            let ends_at = parse_datetime(&end)?;
            if starts_at >= ends_at {
                return Err(vibemeasure_core::VibeError::InvalidData(
                    "report end must follow start".into(),
                ));
            }
            let store = VibeStore::open_existing(db)?;
            let events = store.usage_between(starts_at, ends_at)?;
            let (rules, rates) = store.report_pricing()?;
            let report = build_priced_usage_report(
                ReportRequest {
                    starts_at,
                    ends_at,
                    currency,
                },
                &events,
                &rules,
                &rates,
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
