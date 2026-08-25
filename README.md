# Autodev Plugins

This repository contains plugins for automating different parts of the software development lifecycle with GitHub Copilot or other compatible AI assistants.

Plugins:

- [Autodev](./plugins/autodev/README.md): Runs the whole loop — planning and implementation — as a
  single Agent Factory, pausing for your approval before the review gates, before implementation,
  and at the code checkpoint. Combines what `autodev-plan` and `autodev-implement` do into one run.
- [Autodev-Plan](./plugins/autodev-plan/README.md): Generates a development plan based on a project or feature description, hardened by isolated architecture, security, and privacy review gates.
- [Autodev-Implement](./plugins/autodev-implement/README.md): Implements a plan from Autodev-Plan milestone by milestone, hardened by isolated code, security, and privacy review loops.
- [Autodev-Docs](./plugins/autodev-docs/README.md): Generates documentation for your codebase or project.

> **Status:** `autodev`, `autodev-plan` and `autodev-implement` are implemented. `autodev-docs` is
> still a scaffolded placeholder.
>
> `autodev` ships as a Copilot CLI *extension* rather than as agents and hooks, because an Agent
> Factory has to be registered from code. Copilot CLI discovers extensions in `.github/extensions/`
> and in your Copilot home, so install it with `plugins/autodev/install.sh` (or `install.ps1`) —
> see [its README](./plugins/autodev/README.md).

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
/plugin install autodev-plan@autodev-plugins
/plugin install autodev-implement@autodev-plugins
/plugin install autodev-docs@autodev-plugins
```

The `autodev` factory is an extension, not an agent bundle, so it is installed by path rather than
through the marketplace:

```
plugins/autodev/install.sh          # or install.ps1 on Windows
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
├── extensions/<name>/            # SDK extensions (extension.mjs) — Agent Factories live here
└── hooks/scripts/                # Scripts invoked by hooks
samples/<sample-name>/            # Standalone teaching samples, installed by path
scripts/                          # Repository maintenance scripts, verified by CI
```

Each plugin's `plugin.json` references its `hooks.json` and `.mcp.json`. In the unimplemented
plugin both files are present but empty, so they load cleanly until they are built out.

Agents contributed by a plugin are namespaced `<plugin>:<agent>` — for example
`autodev-plan:autodev-plan`.