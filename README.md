# Autodev Plugins

This repository contains plugins for automating different parts of the software development lifecycle with GitHub Copilot or other compatible AI assistants.

Plugins:

- [Autodev-Plan](./plugins/autodev-plan/README.md): Generates a development plan based on a project or feature description, hardened by isolated architecture, security, and privacy review gates.
- [Autodev-Implement](./plugins/autodev-implement/README.md): Implements a plan from Autodev-Plan milestone by milestone, hardened by isolated code, security, and privacy review loops.
- [Autodev-Docs](./plugins/autodev-docs/README.md): Generates documentation for your codebase or project.

> **Status:** `autodev-plan` and `autodev-implement` are implemented. `autodev-docs` is still a
> scaffolded placeholder.

## Samples

- [hook-otel-span](./samples/hook-otel-span/README.md): a minimal, installable plugin showing how
  to emit an OpenTelemetry span from a Copilot CLI hook. Samples are not part of the marketplace;
  install one by path with
  `copilot plugin install mjrousos/AutodevPlugins:samples/hook-otel-span`.


## Installation

This repository is a plugin marketplace. Add it and then install the plugins you want:

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev-plan@autodev-plugins
/plugin install autodev-implement@autodev-plugins
/plugin install autodev-docs@autodev-plugins
```

## Repository layout

```
.github/plugin/marketplace.json   # Marketplace manifest listing all plugins
plugins/<plugin-name>/
├── plugin.json                   # Plugin manifest (name, version, artifacts)
├── README.md                     # Plugin documentation
├── hooks.json                    # Hook configuration
├── .mcp.json                     # MCP server configuration
├── agents/                       # Agent definitions (*.agent.md)
├── skills/                       # Skills (<skill-name>/SKILL.md)
└── hooks/scripts/                # Scripts invoked by hooks
samples/<sample-name>/            # Standalone teaching samples, installed by path
```

Each plugin's `plugin.json` references its `hooks.json` and `.mcp.json`. In the unimplemented
plugin both files are present but empty, so they load cleanly until they are built out.

Agents contributed by a plugin are namespaced `<plugin>:<agent>` — for example
`autodev-plan:autodev-plan`.