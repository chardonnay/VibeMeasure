use std::{
    env,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use serde_json::Value;

use super::{Provider, env_path, finite, records::factory_quotas};
use crate::model::{ReportedQuota, ReportedQuotaUnit};

const TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: usize = 256 * 1024;

pub(super) enum Account {
    NotConfigured,
    Unavailable,
    Available {
        plan: Option<String>,
        quotas: Vec<ReportedQuota>,
    },
}

pub(super) fn read(provider: Provider, home: &Path) -> Account {
    let (name, override_key, args): (_, _, &[_]) = match provider {
        Provider::Droid => return factory(),
        Provider::Auggie => (
            "auggie",
            "VIBEMEASURE_AUGGIE_COMMAND",
            &["account", "status"],
        ),
        Provider::Amp => ("amp", "VIBEMEASURE_AMP_COMMAND", &["usage"]),
        _ => return Account::NotConfigured,
    };
    let command = env_path(override_key);
    let Some(path) = executable(home, name, command.as_deref()) else {
        return if command.is_some() {
            Account::Unavailable
        } else {
            Account::NotConfigured
        };
    };
    let Some(output) = run(&path, args) else {
        return Account::Unavailable;
    };
    let (plan, quotas) = parse_cli(provider, &output);
    if plan.is_none() && quotas.is_empty() {
        Account::Unavailable
    } else {
        Account::Available { plan, quotas }
    }
}

fn factory() -> Account {
    let Ok(token) = env::var("VIBEMEASURE_FACTORY_ACCESS_TOKEN") else {
        return Account::NotConfigured;
    };
    if token.is_empty() {
        return Account::NotConfigured;
    }
    if token.len() > 8192 || !token.bytes().all(|byte| (33..=126).contains(&byte)) {
        return Account::Unavailable;
    }
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .https_only(true)
        .max_redirects(0)
        .timeout_global(Some(TIMEOUT))
        .build()
        .into();
    let Ok(mut response) = agent
        .get("https://api.factory.ai/api/billing/limits")
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/json")
        .call()
    else {
        return Account::Unavailable;
    };
    if response.status().as_u16() != 200 {
        return Account::Unavailable;
    }
    let Ok(data) = response
        .body_mut()
        .with_config()
        .limit(MAX_OUTPUT as u64)
        .read_to_vec()
    else {
        return Account::Unavailable;
    };
    let Ok(data) = serde_json::from_slice::<Value>(&data) else {
        return Account::Unavailable;
    };
    let quotas = factory_quotas(&data);
    if quotas.is_empty() {
        Account::Unavailable
    } else {
        Account::Available { plan: None, quotas }
    }
}

fn executable(home: &Path, name: &str, command: Option<&Path>) -> Option<PathBuf> {
    if let Some(command) =
        command.filter(|path| path.components().count() > 1 || path.is_absolute())
    {
        return (command.is_absolute() && command.is_file()).then(|| command.to_owned());
    }
    let name = command.and_then(Path::to_str).unwrap_or(name);
    let mut directories: Vec<_> = env::var_os("PATH")
        .iter()
        .flat_map(env::split_paths)
        .collect();
    directories.push(home.join(".local/bin"));
    if let Some(appdata) = env_path("APPDATA") {
        directories.push(appdata.join("npm"));
    }
    #[cfg(windows)]
    let suffixes = [".exe", ".cmd", ".bat", ""];
    #[cfg(not(windows))]
    let suffixes = [""];
    directories
        .into_iter()
        .filter(|path| path.is_absolute())
        .flat_map(|directory| suffixes.map(|suffix| directory.join(format!("{name}{suffix}"))))
        .find(|path| path.is_file())
}

fn run(path: &Path, args: &[&str]) -> Option<String> {
    let mut command = Command::new(path);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("NO_COLOR", "1")
        .env("CI", "1");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW preserves redirected pipes without a console flashing in the tray.
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().ok()?;
    let mut stdout = child.stdout.take()?.take((MAX_OUTPUT + 1) as u64);
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let output = stdout
            .read_to_end(&mut bytes)
            .ok()
            .filter(|length| *length <= MAX_OUTPUT)
            .map(|_| String::from_utf8_lossy(&bytes).into_owned());
        let _ = send.send(output);
    });
    let start = Instant::now();
    while start.elapsed() < TIMEOUT {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                return receive
                    .recv_timeout(TIMEOUT.saturating_sub(start.elapsed()))
                    .ok()
                    .flatten();
            }
            Ok(Some(_)) => return None,
            Ok(None) => thread::sleep(Duration::from_millis(40)),
            Err(_) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    None
}

fn parse_cli(provider: Provider, output: &str) -> (Option<String>, Vec<ReportedQuota>) {
    let clean = strip_ansi(output).replace("**", "");
    let mut quotas = Vec::new();
    let mut plan = None;
    for line in clean.lines().map(str::trim) {
        let Some((label, value)) = line.split_once(':') else {
            continue;
        };
        let label = label.trim();
        let value = value.trim();
        match provider {
            Provider::Amp => {
                if let Some(remaining) = value
                    .strip_prefix('$')
                    .and_then(|value| value.split_once(" remaining"))
                {
                    let (balance, ceiling) =
                        remaining.0.split_once('/').unwrap_or((remaining.0, ""));
                    if let Some(balance) = number(balance) {
                        let percent = number(ceiling.trim().trim_start_matches('$'))
                            .filter(|limit| *limit > 0.0 && balance <= *limit)
                            .map(|limit| (1.0 - balance / limit) * 100.0);
                        quotas.push(ReportedQuota {
                            name: short(label),
                            used_percent: percent,
                            resets_at: None,
                            value: Some(balance),
                            unit: Some(ReportedQuotaUnit::UsdRemaining),
                            detail: "Amp credit balance".into(),
                        });
                    }
                } else if label.ends_with("Subscription") && value.contains("remaining") {
                    let name = label
                        .trim_start_matches("Amp ")
                        .trim_end_matches("Subscription")
                        .trim();
                    if !name.is_empty() {
                        plan = Some(short(name));
                    }
                    let detail = value
                        .find("resets upon renewal")
                        .map(|at| &value[at..])
                        .unwrap_or("Amp subscription");
                    let parts: Vec<_> = value.split_whitespace().collect();
                    for pair in parts.windows(2) {
                        if matches!(pair[1], "other" | "orb")
                            && let Some(remaining) = pair[0]
                                .strip_suffix('%')
                                .and_then(number)
                                .filter(|value| *value <= 100.0)
                            && let Some(offset) =
                                value.find(&format!("{} {} usage", pair[0], pair[1]))
                            && value[offset..].contains("remaining")
                        {
                            quotas.push(ReportedQuota {
                                name: format!("Amp {} usage", pair[1]),
                                used_percent: Some(100.0 - remaining),
                                resets_at: None,
                                value: None,
                                unit: None,
                                detail: short(detail),
                            });
                        }
                    }
                }
            }
            Provider::Auggie => {
                let detail = "Reported by auggie account status".to_owned();
                match label.to_ascii_lowercase().as_str() {
                    "plan" | "subscription plan" if !value.is_empty() => plan = Some(short(value)),
                    "credits used" | "usage" => {
                        if let Some((used, limit)) = value.split_once('/')
                            && let Some(used) = number(used)
                            && let Some(limit) = limit
                                .split_whitespace()
                                .next()
                                .and_then(number)
                                .filter(|value| *value > 0.0)
                        {
                            quotas.push(ReportedQuota {
                                name: "Augment credit usage".into(),
                                used_percent: Some((used / limit).min(1.0) * 100.0),
                                resets_at: None,
                                value: Some(used),
                                unit: Some(ReportedQuotaUnit::Credits),
                                detail: format!("{used} / {limit} credits · {detail}"),
                            });
                        }
                    }
                    "credits remaining"
                    | "remaining credits"
                    | "credit balance"
                    | "monthly allowance"
                    | "monthly credit allowance" => {
                        if let Some(value) = number(value.trim_end_matches("credits")) {
                            quotas.push(ReportedQuota {
                                name: short(label),
                                used_percent: None,
                                resets_at: None,
                                value: Some(value),
                                unit: Some(ReportedQuotaUnit::Credits),
                                detail,
                            });
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    (plan, quotas)
}

fn short(value: &str) -> String {
    value
        .chars()
        .filter(|ch| !ch.is_control())
        .take(100)
        .collect()
}

fn number(value: &str) -> Option<f64> {
    finite(value.trim().replace(',', "").parse().ok()?)
}

fn strip_ansi(text: &str) -> String {
    let mut clean = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for code in chars.by_ref() {
                if ('@'..='~').contains(&code) {
                    break;
                }
            }
        } else {
            clean.push(ch);
        }
    }
    clean
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_remaining_amp_allowances_and_plan() {
        let (plan, quotas) = parse_cli(
            Provider::Amp,
            "\x1b[32m**Amp Megawatt Subscription:** 68% other usage and 97% orb usage remaining - resets upon renewal in 5 days\x1b[0m\nIndividual: $24.20 remaining\nWorkspace: $9.00 / $36.00 remaining",
        );
        assert_eq!(plan.as_deref(), Some("Megawatt"));
        assert_eq!(
            quotas.iter().map(|q| q.used_percent).collect::<Vec<_>>(),
            [Some(32.0), Some(3.0), None, Some(75.0)]
        );
        assert_eq!(quotas[2].value, Some(24.20));
    }

    #[test]
    fn parses_augment_usage_without_guessing_a_reset() {
        let (plan, quotas) = parse_cli(
            Provider::Auggie,
            "Plan: Max\nCredits Used: 230 / 1,000 credits\nCredits Remaining: 770 credits",
        );
        assert_eq!(plan.as_deref(), Some("Max"));
        assert_eq!(quotas[0].used_percent, Some(23.0));
        assert_eq!(quotas[1].value, Some(770.0));
        assert_eq!(quotas[0].resets_at, None);
    }
}
