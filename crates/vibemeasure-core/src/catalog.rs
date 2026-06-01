#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolDefinition {
    pub id: &'static str,
    pub display_name: &'static str,
    pub command_hint: Option<&'static str>,
}

pub fn required_tools() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            id: "claude",
            display_name: "Claude Code",
            command_hint: Some("claude"),
        },
        ToolDefinition {
            id: "codex",
            display_name: "Codex CLI",
            command_hint: Some("codex"),
        },
        ToolDefinition {
            id: "devin-terminal",
            display_name: "Devin for Terminal",
            command_hint: None,
        },
        ToolDefinition {
            id: "gemini",
            display_name: "Gemini CLI",
            command_hint: Some("gemini"),
        },
        ToolDefinition {
            id: "opencode",
            display_name: "OpenCode",
            command_hint: Some("opencode"),
        },
        ToolDefinition {
            id: "hermes",
            display_name: "Hermes",
            command_hint: None,
        },
        ToolDefinition {
            id: "kimi-cli",
            display_name: "Kimi CLI",
            command_hint: None,
        },
        ToolDefinition {
            id: "cursor-agent",
            display_name: "Cursor Agent",
            command_hint: Some("cursor-agent"),
        },
        ToolDefinition {
            id: "qwen-code",
            display_name: "Qwen Code",
            command_hint: None,
        },
        ToolDefinition {
            id: "qoder-cli",
            display_name: "Qoder CLI",
            command_hint: None,
        },
        ToolDefinition {
            id: "github-copilot-cli",
            display_name: "GitHub Copilot CLI",
            command_hint: None,
        },
        ToolDefinition {
            id: "pi",
            display_name: "Pi",
            command_hint: None,
        },
        ToolDefinition {
            id: "kiro-cli",
            display_name: "Kiro CLI",
            command_hint: None,
        },
        ToolDefinition {
            id: "kilo",
            display_name: "Kilo",
            command_hint: None,
        },
        ToolDefinition {
            id: "mistral-vibe-cli",
            display_name: "Mistral Vibe CLI",
            command_hint: None,
        },
        ToolDefinition {
            id: "deepseek-tui",
            display_name: "DeepSeek TUI",
            command_hint: None,
        },
        ToolDefinition {
            id: "minimax",
            display_name: "MiniMAX",
            command_hint: None,
        },
    ]
}

pub fn tool_by_id(id: &str) -> Option<ToolDefinition> {
    required_tools().into_iter().find(|tool| tool.id == id)
}

#[cfg(test)]
mod tests {
    use super::required_tools;

    #[test]
    fn includes_every_required_tool() {
        let ids: Vec<_> = required_tools().into_iter().map(|tool| tool.id).collect();
        assert_eq!(ids.len(), 17);
        for id in [
            "claude",
            "codex",
            "devin-terminal",
            "gemini",
            "opencode",
            "hermes",
            "kimi-cli",
            "cursor-agent",
            "qwen-code",
            "qoder-cli",
            "github-copilot-cli",
            "pi",
            "kiro-cli",
            "kilo",
            "mistral-vibe-cli",
            "deepseek-tui",
            "minimax",
        ] {
            assert!(ids.contains(&id), "missing {id}");
        }
    }
}
