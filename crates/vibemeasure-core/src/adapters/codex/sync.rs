use std::{
    cmp::Reverse,
    fs::{self, File, Metadata},
    io::{self, BufReader, Read},
    path::Path,
    time::{Duration, Instant},
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::{Result, VibeError, store::VibeStore};

use super::{parse_codex_jsonl, parse_codex_records};

const RECENT_DAYS: i64 = 31;
const BATCH_TIME: Duration = Duration::from_secs(15);
const PARSER_VERSION: u8 = 1;

#[derive(Default, Serialize)]
pub struct CodexSyncResult {
    source_found: bool,
    imported_files: usize,
    deferred_files: usize,
    unreadable_files: usize,
    more_work: bool,
}

#[derive(Deserialize, Serialize, PartialEq, Eq)]
struct FileStamp {
    length: u64,
    modified: DateTime<Utc>,
}

impl FileStamp {
    fn read(metadata: &Metadata) -> io::Result<Self> {
        Ok(Self {
            length: metadata.len(),
            modified: metadata.modified()?.into(),
        })
    }
}

#[derive(Clone, Copy, Deserialize, Serialize)]
enum FileState {
    Imported,
    Incomplete,
    Invalid,
}

#[derive(Deserialize, Serialize)]
struct Checkpoint {
    stamp: FileStamp,
    state: FileState,
    #[serde(default)]
    parser_version: u8,
}

fn session_key(path: &Path, session_id: Option<&str>) -> Result<String> {
    match session_id {
        Some(id) => Ok(format!("session:{id}")),
        None => Ok(format!(
            "file:{}",
            serde_json::to_string(path.canonicalize()?.as_os_str().as_encoded_bytes())?
        )),
    }
}

pub fn import_codex_file(store: &VibeStore, path: &Path) -> Result<(usize, usize)> {
    let output = parse_codex_jsonl(path)?;
    let key = session_key(path, output.session_id.as_deref())?;
    store.import_codex_session(&key, &output)
}

pub fn sync_codex_sessions(db: &Path, home: &Path) -> Result<CodexSyncResult> {
    let mut result = CodexSyncResult::default();
    let mut files = Vec::new();
    let cutoff = Utc::now() - chrono::Duration::days(RECENT_DAYS);
    let mut next = vec![home.join("sessions"), home.join("archived_sessions")];
    while let Some(directory) = next.pop() {
        let entries = match fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(_) => {
                result.unreadable_files += 1;
                continue;
            }
        };
        result.source_found = true;
        for item in entries {
            let Ok(entry) = item else {
                result.unreadable_files += 1;
                continue;
            };
            let Ok(kind) = entry.file_type() else {
                result.unreadable_files += 1;
                continue;
            };
            if kind.is_dir() {
                next.push(entry.path());
            } else if kind.is_file()
                && entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(".jsonl"))
            {
                match entry.metadata().and_then(|value| FileStamp::read(&value)) {
                    Ok(stamp) if stamp.modified >= cutoff => files.push((entry.path(), stamp)),
                    Ok(_) => {}
                    Err(_) => result.unreadable_files += 1,
                }
            }
        }
    }
    if files.is_empty() {
        return Ok(result);
    }

    if let Some(parent) = db.parent().filter(|path| !path.as_os_str().is_empty()) {
        fs::create_dir_all(parent)?;
    }
    let store = VibeStore::open(db)?;
    files.sort_by_key(|(_, stamp)| Reverse(stamp.modified));
    let started = Instant::now();
    for (path, stamp) in files {
        if result.imported_files > 0 && started.elapsed() >= BATCH_TIME {
            result.more_work = true;
            break;
        }
        match sync_file(&store, &path, stamp, &mut result) {
            Ok(()) => {}
            Err(VibeError::Io(error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::WouldBlock
                ) =>
            {
                result.deferred_files += 1;
            }
            Err(VibeError::Io(_)) => result.unreadable_files += 1,
            Err(error) => return Err(error),
        }
    }
    Ok(result)
}

fn sync_file(
    store: &VibeStore,
    path: &Path,
    stamp: FileStamp,
    result: &mut CodexSyncResult,
) -> Result<()> {
    let path = path.canonicalize()?;
    let key = format!(
        "codex.sync.v1.{}",
        serde_json::to_string(path.as_os_str().as_encoded_bytes())?
    );
    let cached: Option<Checkpoint> = store.load_setting(&key)?;
    let state = if let Some(cached) = cached.filter(|cached| {
        cached.stamp == stamp
            && (!matches!(cached.state, FileState::Invalid)
                || cached.parser_version == PARSER_VERSION)
    }) {
        cached.state
    } else {
        let mut file = File::open(&path)?;
        let observed = FileStamp::read(&file.metadata()?)?;
        let parsed = parse_codex_records(BufReader::new((&mut file).take(observed.length)), true);
        let current = FileStamp::read(&file.metadata()?)?;
        let grew = current.length > observed.length;
        // A Codex writer can append while we read. Import the bounded prefix in
        // that case and checkpoint its stamp, so the next pass sees the append.
        if current != observed && (!grew || parsed.is_err()) {
            result.deferred_files += 1;
            return Ok(());
        }
        let state = match parsed {
            Ok((output, partial)) => {
                let session = session_key(&path, output.session_id.as_deref())?;
                store.import_codex_session(&session, &output)?;
                result.imported_files += 1;
                if partial || grew {
                    FileState::Incomplete
                } else {
                    FileState::Imported
                }
            }
            Err(VibeError::InvalidData(_) | VibeError::Json(_)) => FileState::Invalid,
            Err(error) => return Err(error),
        };
        // Saving this after the import is retry-safe. If interrupted, the next import
        // replays the file through the same session and measurement deduplication.
        store.save_setting(
            &key,
            &Checkpoint {
                stamp: observed,
                state,
                parser_version: PARSER_VERSION,
            },
        )?;
        state
    };
    match state {
        FileState::Imported => {}
        FileState::Incomplete => result.deferred_files += 1,
        FileState::Invalid => result.unreadable_files += 1,
    }
    Ok(())
}
