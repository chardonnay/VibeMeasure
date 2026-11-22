use std::{
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
};

use chrono::{NaiveDate, Utc};
use clap::Args;
use vibemeasure_core::{
    Result, VibeError,
    alerts::{AlertRule, check_alerts},
    catalog::required_tools,
    store::VibeStore,
};

#[derive(Args)]
pub struct SetAlert {
    #[arg(long)]
    db: PathBuf,
    #[arg(long)]
    tool: String,
    /// Subscription end date (YYYY-MM-DD).
    #[arg(long)]
    end_date: Option<NaiveDate>,
    /// Days before the end date, including zero for the last day.
    #[arg(long)]
    days_before: Option<u16>,
    /// Percentage of a provider quota consumed (1–100).
    #[arg(long)]
    used_percent: Option<u8>,
}

fn open(db: &Path) -> Result<VibeStore> {
    if let Some(dir) = db.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    VibeStore::open(db)
}

impl SetAlert {
    pub fn save(self) -> Result<()> {
        AlertRule {
            end_date: self.end_date,
            days_before: self.days_before,
            used_percent: self.used_percent,
        }
        .save(&open(&self.db)?, &self.tool)
    }
}

pub fn settings(db: &Path, edit: bool) -> Result<()> {
    if edit {
        let status = Command::new("python3")
            .arg("-c")
            .arg(include_str!("alert_editor.py"))
            .arg(std::env::current_exe()?)
            .arg(db)
            .status()?;
        if !status.success() {
            return Err(VibeError::InvalidData(
                "the alert editor requires Python 3 and Tk".into(),
            ));
        }
    } else {
        let store = open(db)?;
        let mut settings = Vec::new();
        for tool in required_tools() {
            settings.push(serde_json::json!({"id": tool.id, "name": tool.display_name, "rule": AlertRule::load(&store, tool.id)?}));
        }
        println!("{}", serde_json::to_string(&settings)?);
    }
    Ok(())
}

pub fn poll(db: &Path, desktop_pipe: bool) -> Result<()> {
    let store = VibeStore::open_existing(db)?;
    check_alerts(&store, Utc::now(), |message| {
        if desktop_pipe {
            // The Windows host acknowledges after handing the message to the OS.
            writeln!(io::stdout(), "{}", serde_json::to_string(message)?)?;
            io::stdout().flush()?;
            let mut ack = String::new();
            io::stdin().read_line(&mut ack)?;
            if ack.trim() == "ok" {
                return Ok(());
            }
        } else if Command::new("notify-send")
            .args(["--app-name=VibeMeasure", "--", "VibeMeasure", message])
            .status()?
            .success()
        {
            return Ok(());
        }
        Err(VibeError::InvalidData(
            "desktop notification delivery failed".into(),
        ))
    })
}
