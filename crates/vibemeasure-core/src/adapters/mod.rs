pub mod codex;

use std::path::Path;

use crate::{
    Result,
    model::{LimitWindow, UsageEvent},
};

#[derive(Clone, Debug, Default)]
pub struct AdapterOutput {
    pub usage_events: Vec<UsageEvent>,
    pub limit_windows: Vec<LimitWindow>,
}

pub trait ProviderAdapter {
    fn tool_id(&self) -> &'static str;
    fn collect_from_path(&self, path: &Path) -> Result<AdapterOutput>;
}
