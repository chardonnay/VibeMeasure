mod account;
mod records;

use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    env, fs,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    time::SystemTime,
};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    Result,
    model::{ProviderPlan, ReportedQuota, ReportedUsage, SourceMeta},
    store::VibeStore,
};

const MAX_FILE_SIZE: u64 = 64 * 1024 * 1024;
const SETTINGS_KEY: &str = "additional_provider_readings_v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Provider {
    Antigravity,
    Droid,
    Cline,
    Auggie,
    Amp,
    OpenHands,
}

impl Provider {
    const ALL: [Self; 6] = [
        Self::Antigravity,
        Self::Droid,
        Self::Cline,
        Self::Auggie,
        Self::Amp,
        Self::OpenHands,
    ];

    fn id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity",
            Self::Droid => "factory-droid",
            Self::Cline => "cline",
            Self::Auggie => "auggie",
            Self::Amp => "amp",
            Self::OpenHands => "openhands",
        }
    }

    fn source(self) -> &'static str {
        match self {
            Self::Antigravity => "Antigravity CLI usage records",
            Self::Droid => "Factory Droid usage records",
            Self::Cline => "Cline usage records",
            Self::Auggie => "Augment Code usage records",
            Self::Amp => "Amp usage records",
            Self::OpenHands => "OpenHands conversation state",
        }
    }

    fn credit_unit(self) -> Option<&'static str> {
        match self {
            Self::Droid => Some("Factory credits"),
            Self::Auggie => Some("Augment credits"),
            Self::Amp => Some("Amp credits"),
            _ => None,
        }
    }

    fn paths(self, home: &Path) -> Vec<PathBuf> {
        let (override_name, default_path) = match self {
            Self::Antigravity => (
                "ANTIGRAVITY",
                ".gemini/antigravity-cli/vibemeasure-usage.json",
            ),
            Self::Droid => ("FACTORY_DROID", ".factory/sessions"),
            Self::Cline => ("CLINE", ".cline/data/sessions"),
            Self::Auggie => ("AUGGIE", ".augment/sessions"),
            Self::Amp => ("AMP", ".local/share/amp/threads"),
            Self::OpenHands => ("OPENHANDS", ".openhands/conversations"),
        };
        if let Some(path) = env_path(&format!("VIBEMEASURE_{override_name}_PATH")) {
            return vec![path];
        }

        match self {
            Self::Cline => {
                let cline = env_path("CLINE_DIR")
                    .unwrap_or_else(|| home.join(".cline"))
                    .join("data");
                let mut paths = vec![cline.join("sessions"), cline.join("state/taskHistory.json")];
                if let Some(appdata) = env_path("APPDATA") {
                    for editor in ["Code", "Code - Insiders", "VSCodium"] {
                        paths.push(appdata.join(editor).join(
                            "User/globalStorage/saoudrizwan.claude-dev/state/taskHistory.json",
                        ));
                    }
                }
                paths
            }
            Self::Auggie => vec![
                env_path("AUGMENT_HOME")
                    .map(|path| path.join("sessions"))
                    .unwrap_or_else(|| home.join(default_path)),
            ],
            Self::Amp => {
                if let Ok(paths) = env::var("AMP_DATA_DIR") {
                    let paths: Vec<_> = paths
                        .split(',')
                        .map(str::trim)
                        .filter(|p| !p.is_empty())
                        .map(|path| PathBuf::from(path).join("threads"))
                        .collect();
                    if !paths.is_empty() {
                        return paths;
                    }
                }
                let mut paths = vec![
                    env_path("XDG_DATA_HOME")
                        .unwrap_or_else(|| home.join(".local/share"))
                        .join("amp/threads"),
                ];
                if let Some(appdata) = env_path("LOCALAPPDATA") {
                    paths.push(appdata.join("amp/threads"));
                }
                paths
            }
            _ => vec![home.join(default_path)],
        }
    }

    fn matches(self, name: &str) -> bool {
        match self {
            Self::Antigravity => name == "vibemeasure-usage.json" || name.ends_with(".jsonl"),
            Self::Droid => name == "factory-limits.json" || name.ends_with(".settings.json"),
            Self::Cline => name.ends_with(".json") && !name.ends_with(".messages.json"),
            Self::Auggie | Self::Amp => name.ends_with(".json") && name != "session.json",
            Self::OpenHands => name == "base_state.json",
        }
    }
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub(crate) struct Reading {
    tokens: Option<u64>,
    #[serde(default)]
    token_overflow: bool,
    conversation_tokens: Option<u64>,
    usd: Option<f64>,
    credits: Option<f64>,
    quotas: Vec<ReportedQuota>,
    history: BTreeMap<DateTime<Utc>, u64>,
    plan: Option<ProviderPlan>,
    source: Option<SourceMeta>,
}

impl Reading {
    fn add_tokens(&mut self, total: Option<u64>, time: Option<DateTime<Utc>>) {
        let Some(total) = total else { return };
        if !self.token_overflow {
            self.tokens = self.tokens.unwrap_or(0).checked_add(total);
            self.token_overflow = self.tokens.is_none();
        }
        if let Some(time) = time {
            let value = self.history.entry(time).or_default();
            *value = value.saturating_add(total);
        }
    }

    fn add_usd(&mut self, value: Option<f64>) {
        if let Some(value) = value {
            self.usd = finite(self.usd.unwrap_or(0.0) + value);
        }
    }

    fn add_credits(&mut self, value: Option<f64>) {
        if let Some(value) = value {
            self.credits = finite(self.credits.unwrap_or(0.0) + value);
        }
    }

    fn has_data(&self) -> bool {
        self.tokens.is_some()
            || self.conversation_tokens.is_some()
            || self.usd.is_some()
            || self.credits.is_some()
            || !self.quotas.is_empty()
            || self.plan.is_some()
            || !self.history.is_empty()
    }

    pub(crate) fn dated_tokens(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> Option<u64> {
        if start >= end {
            return None;
        }
        let mut tokens = self.history.range(start..end).map(|(_, tokens)| *tokens);
        let first = tokens.next()?;
        tokens.try_fold(first, u64::checked_add)
    }

    pub(crate) fn plan(&self) -> Option<ProviderPlan> {
        self.plan.clone()
    }

    pub(crate) fn reported(&self, tool: &str, now: DateTime<Utc>) -> Option<ReportedUsage> {
        let provider = Provider::ALL.into_iter().find(|p| p.id() == tool)?;
        let mut quotas = self.quotas.clone();
        for quota in &mut quotas {
            if quota.resets_at.is_some_and(|reset| reset <= now) {
                quota.used_percent = None;
                quota.value = None;
            }
        }
        Some(ReportedUsage {
            tokens: self.tokens.or(self.conversation_tokens),
            conversation_tokens: self.tokens.is_none() && self.conversation_tokens.is_some(),
            estimated_usd: self.usd,
            credits: self.credits,
            credit_unit: provider.credit_unit().map(str::to_owned),
            quotas,
            source: self.source.clone()?,
        })
    }
}

#[derive(Serialize)]
pub struct SyncSummary {
    providers_updated: usize,
    unreadable_files: usize,
    deferred_accounts: usize,
}

type Readings = BTreeMap<String, Reading>;

pub(crate) fn load(store: &VibeStore) -> Result<Readings> {
    Ok(store.load_setting(SETTINGS_KEY)?.unwrap_or_default())
}

pub fn sync(db: &Path) -> Result<SyncSummary> {
    let home = env_path("USERPROFILE").or_else(|| env_path("HOME"));
    let Some(home) = home else {
        return Ok(SyncSummary {
            providers_updated: 0,
            unreadable_files: 0,
            deferred_accounts: 0,
        });
    };
    sync_at(db, &home, Utc::now())
}

fn sync_at(db: &Path, home: &Path, now: DateTime<Utc>) -> Result<SyncSummary> {
    // The two CLI commands and the optional account API can all wait on a network independently.
    let accounts = std::thread::scope(|scope| {
        let account = scope.spawn(|| account::read(Provider::Droid, home));
        let auggie = scope.spawn(|| account::read(Provider::Auggie, home));
        let amp = scope.spawn(|| account::read(Provider::Amp, home));
        let locals: Vec<_> = Provider::ALL
            .into_iter()
            .map(|provider| {
                let (reading, errors) = read_local(provider, &provider.paths(home), now);
                (provider, reading, errors)
            })
            .collect();
        (locals, [account.join(), auggie.join(), amp.join()])
    });
    let (locals, accounts) = accounts;
    let mut accounts = [Provider::Droid, Provider::Auggie, Provider::Amp]
        .into_iter()
        .zip(accounts.map(|result| result.unwrap_or(account::Account::Unavailable)))
        .collect::<Vec<_>>();
    let mut summary = SyncSummary {
        providers_updated: 0,
        unreadable_files: 0,
        deferred_accounts: 0,
    };
    let mut readings = Readings::new();
    let mut retry = Vec::new();
    for (provider, mut reading, errors) in locals {
        summary.unreadable_files += errors;
        let deferred = if let Some(index) = accounts.iter().position(|(id, _)| *id == provider) {
            match accounts.swap_remove(index).1 {
                account::Account::Available { plan, quotas } => {
                    reading.plan = plan
                        .map(|name| ProviderPlan {
                            name,
                            source: SourceMeta::local(provider.source(), now),
                        })
                        .or(reading.plan);
                    // Live data wins over a saved Factory export with the same labels.
                    reading
                        .quotas
                        .retain(|local| !quotas.iter().any(|live| live.name == local.name));
                    reading.quotas.extend(quotas);
                    false
                }
                account::Account::Unavailable => {
                    summary.deferred_accounts += 1;
                    true
                }
                account::Account::NotConfigured => false,
            }
        } else {
            false
        };
        if reading.has_data() {
            reading
                .history
                .retain(|date, _| *date >= now - Duration::days(32));
            reading.source = Some(SourceMeta::local(provider.source(), now));
            readings.insert(provider.id().to_owned(), reading);
            summary.providers_updated += 1;
        } else if errors > 0 && !deferred {
            // Files can briefly be unreadable while a provider rewrites them.
            retry.push(provider.id());
        }
    }
    if !db.is_file() && readings.is_empty() {
        return Ok(summary);
    }
    if let Some(parent) = db.parent().filter(|path| !path.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let store = VibeStore::open(db)?;
    let mut previous = load(&store)?;
    for provider in retry {
        if let Some(reading) = previous.remove(provider) {
            readings.insert(provider.to_owned(), reading);
        }
    }
    if !readings.is_empty() || !previous.is_empty() {
        store.save_setting(SETTINGS_KEY, &readings)?;
    }
    Ok(summary)
}

fn read_local(provider: Provider, roots: &[PathBuf], now: DateTime<Utc>) -> (Reading, usize) {
    let mut files = BTreeSet::new();
    let mut errors = 0;
    for path in roots {
        let mut pending = vec![(path.clone(), true)];
        while let Some((path, explicit)) = pending.pop() {
            let metadata = if explicit {
                fs::metadata(&path)
            } else {
                fs::symlink_metadata(&path)
            };
            let metadata = match metadata {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(_) => {
                    errors += 1;
                    continue;
                }
            };
            if metadata.is_dir() {
                match fs::read_dir(&path) {
                    Ok(entries) => {
                        for entry in entries {
                            match entry {
                                Ok(entry)
                                    if !entry.file_name().to_string_lossy().starts_with('.') =>
                                {
                                    pending.push((entry.path(), false));
                                }
                                Ok(_) => {}
                                Err(_) => errors += 1,
                            }
                        }
                    }
                    Err(_) => errors += 1,
                }
            } else if metadata.is_file()
                && (explicit
                    || path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| provider.matches(name)))
            {
                if metadata.len() <= MAX_FILE_SIZE {
                    files.insert((metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH), path));
                } else {
                    errors += 1;
                }
            }
        }
    }
    let mut reading = Reading::default();
    let mut seen = HashSet::new();
    let mut ids = HashSet::new();
    for (_, file) in files.into_iter().rev() {
        if !ids.insert(fs::canonicalize(&file).unwrap_or_else(|_| file.clone())) {
            continue;
        }
        let result = if provider == Provider::Antigravity
            && file.extension().is_some_and(|ext| ext == "jsonl")
        {
            read_antigravity_stream(&file, &mut seen, &mut reading)
        } else {
            parse_file(&file)
                .map(|data| records::read(provider, &data, &file, now, &mut seen, &mut reading))
        };
        if result.is_err() {
            errors += 1;
        }
    }
    (reading, errors)
}

fn parse_file(file: &Path) -> Result<Value> {
    let content = fs::File::open(file)?;
    let mut bytes = Vec::new();
    content.take(MAX_FILE_SIZE + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_FILE_SIZE {
        return Err(crate::VibeError::InvalidData(
            "provider file is too large".into(),
        ));
    }
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
    Ok(serde_json::from_slice(bytes)?)
}

fn read_antigravity_stream(
    file: &Path,
    seen: &mut HashSet<String>,
    reading: &mut Reading,
) -> Result<()> {
    let content = fs::File::open(file)?;
    let mut reader = BufReader::new(content.take(MAX_FILE_SIZE));
    let mut line = Vec::new();
    while reader.read_until(b'\n', &mut line)? > 0 {
        if let Ok(event) = serde_json::from_slice::<Value>(&line) {
            let step = &event["step_update"];
            if step["state"] == "DONE"
                && let (Some(total), Some(session), Some(index)) = (
                    count(&step["usage"]["total_tokens"]),
                    step["conversation_id"].as_str(),
                    count(&step["step_index"]),
                )
                && seen.insert(format!("step:{session}:{index}"))
            {
                reading.add_tokens(Some(total), timestamp(&event["timestamp"]));
            }
        }
        line.clear();
    }
    Ok(())
}

fn finite(value: f64) -> Option<f64> {
    (value.is_finite() && value >= 0.0).then_some(value)
}

fn amount(value: &Value) -> Option<f64> {
    finite(value.as_f64().or_else(|| value.as_str()?.parse().ok())?)
}

fn count(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str()?.parse().ok())
        .or_else(|| {
            let number = amount(value)?;
            (number.fract() == 0.0 && number < u64::MAX as f64).then_some(number as u64)
        })
}

fn timestamp(value: &Value) -> Option<DateTime<Utc>> {
    if let Some(number) = amount(value).filter(|value| *value > 0.0) {
        let millis = if number > 100_000_000_000.0 {
            number
        } else {
            number * 1000.0
        };
        return DateTime::from_timestamp_millis(millis as i64);
    }
    DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|date| date.to_utc())
}
