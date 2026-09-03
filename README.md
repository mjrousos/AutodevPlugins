# Autodev Plugins

This repository contains plugins for automating different parts of the software development lifecycle with GitHub Copilot or other compatible AI assistants.

Plugins:

- [Autodev](./plugins/autodev/README.md): Consolidated planning + implementation plugin with workflow canvas and separate planning/implementation hook enforcement routers.
- [Autodev-Factory](./plugins/autodev-factory/README.md): Single Agent Factory runtime that runs the full plan-then-implement loop with approval checkpoints.

> **Status:** `autodev` (plugin) and `autodev-factory` (Agent Factory extension plugin) are implemented.

## Samples

- [hook-otel-span](./samples/hook-otel-span/README.md): a minimal, installable plugin showing how
  to emit an OpenTelemetry span from a Copilot CLI hook.
- [factory-review](./samples/factory-review/README.md): a small, readable **Agent Factory** — fan
  out reviewers across lenses, have independent skeptics verify every finding, report what
  survived. Covers the primitives, the three ways a factory fails silently, limits, and resume.
  An Agent Factory has to be registered from code, so this one is a Copilot CLI *extension*:
  install it with `samples/factory-review/install.sh` (or `install.ps1`).

Samples are not part of the marketplace; install a hook or agent sample by path with
`copilot plugin install mjrousos/AutodevPlugins:samples/<sample-name>`. Note that installing by
path or repository is deprecated — the CLI warns that only `plugin@marketplace` installs will be
supported in a future release — so prefer a marketplace entry for anything you intend to share.


## Installation

This repository is a plugin marketplace. Add it and then install the plugins you want:

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev@autodev-plugins
/plugin install autodev-factory@autodev-plugins
```

If you previously installed `autodev-plan` and `autodev-implement`, uninstall those legacy plugins before installing `autodev`.

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
├── extensions/<name>/            # SDK extensions (extension.mjs) — Agent Factories live here
└── hooks/scripts/                # Scripts invoked by hooks
samples/<sample-name>/            # Standalone teaching samples, installed by path
scripts/                          # Repository maintenance scripts, verified by CI
```

Each plugin's `plugin.json` references its `hooks.json` and `.mcp.json` as needed by that plugin type.

Agents contributed by a plugin are namespaced `<plugin>:<agent>` — for example
`autodev:autodev-plan`.