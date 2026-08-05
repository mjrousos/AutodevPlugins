# Autodev-Docs

> **Status: placeholder.** This plugin is scaffolded but not yet implemented.

Generates documentation for your codebase or project.

## Planned contents

| Folder | Purpose |
| --- | --- |
| `agents/` | Agent definitions (`*.agent.md`) that author and review documentation. |
| `skills/` | Skills (`<skill-name>/SKILL.md`) for documentation generation workflows. |
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
/plugin install autodev-docs@autodev-plugins
```

## Usage

To be documented once the plugin is implemented.
