# Autodev-Implement

> **Status: placeholder.** This plugin is scaffolded but not yet implemented.

Generates code implementations based on a plan from [Autodev-Plan](../autodev-plan/README.md).

## Planned contents

| Folder | Purpose |
| --- | --- |
| `agents/` | Agent definitions (`*.agent.md`) that carry out implementation work. |
| `skills/` | Skills (`<skill-name>/SKILL.md`) for implementing and verifying plan steps. |
| `hooks.json` | Hook configuration (currently empty). |
| `hooks/scripts/` | Scripts invoked by the hooks. |
| `.mcp.json` | MCP server configuration (currently empty). |

## Hooks

`hooks.json` follows the standard hook schema. Add entries under `hooks` using any of the
supported events: `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`,
`postToolUse`, `agentStop`, and `errorOccurred`.

```json
{
  "version": 1,
  "hooks": {
    "postToolUse": [
      {
        "type": "command",
        "bash": "bash hooks/scripts/example.sh",
        "powershell": "pwsh -File hooks/scripts/example.ps1",
        "timeoutSec": 30
      }
    ]
  }
}
```

Provide both `bash` and `powershell` keys so hooks work on Linux, macOS, and Windows.

## MCP servers

Add any MCP servers this plugin needs to `.mcp.json`:

```json
{
  "mcpServers": {
    "example": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "example-mcp-server"]
    }
  }
}
```

Use `${PLUGIN_ROOT}` to reference files bundled inside the plugin.

## Installation

Add this repository as a plugin marketplace, then install the plugin:

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev-implement@autodev-plugins
```

## Usage

To be documented once the plugin is implemented.
