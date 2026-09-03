# Autodev Plugins

This repository contains plugins for automating the software development lifecycle with GitHub
Copilot or other compatible AI assistants. It ships exactly two plugins:

- [**autodev**](./plugins/autodev/README.md) (`0.5.0`): the planning and implementation workflows in
  one plugin. It contributes two top-level agents — `autodev-plan`, which drafts a development plan
  hardened by isolated architecture, security, and privacy review gates with a live workflow canvas,
  and `autodev-implement`, which builds that plan milestone by milestone, hardened by isolated code,
  security, and privacy review loops. Their reviewers, workers, hooks, and tracker enforcement all
  ship together.
- [**autodev-factory**](./plugins/autodev-factory/README.md) (`0.2.0`): the same plan-then-implement
  loop packaged as a single Agent Factory. It replaces the two orchestrator agents with code,
  pausing for your approval before the review gates, before implementation, and at the code
  checkpoint. It is a Copilot CLI *extension* rather than an agent bundle, because an Agent Factory
  has to be registered from code.

Both plugins share the same reviewers and workers: the factory carries their instructions in
generated prompts lifted from the `autodev` plugin's canonical `.agent.md` files.

## Installation

This repository is a plugin marketplace. Add it and then install the plugin you want:

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev@autodev-plugins
```

### Upgrading existing installations

Before installing `autodev`, uninstall the legacy plugin IDs so their hooks cannot also capture
the current agents:

```
/plugin uninstall autodev-plan@autodev-plugins
/plugin uninstall autodev-implement@autodev-plugins
/plugin uninstall autodev-docs@autodev-plugins
```

If you installed the old factory directly, run the new `autodev-factory` installer once. It removes
an installation it recognizes at `extensions/autodev` before installing the renamed
`extensions/autodev-factory`; an unrelated directory with that name is left untouched.

`autodev` installs its two agents (`autodev-plan` and `autodev-implement`) under the shared
`autodev:` namespace, along with the review-gate and implementation-stage hooks.

`autodev-factory` is an extension, not an agent bundle, so — in addition to being listed in the
marketplace — it is installed from code into a directory the CLI scans for extensions:

```
plugins/autodev-factory/install.sh          # or install.ps1 on Windows
```

After installing, run `/extensions` in the CLI (or restart it) and invoke the `autodev-factory`
factory with `run_factory`. See [its README](./plugins/autodev-factory/README.md).

## Namespaces

Agents contributed by the `autodev` plugin are namespaced `autodev:<agent>` — for example
`autodev:autodev-plan`, `autodev:autodev-implement`, and the reviewers such as
`autodev:autodev-security-review` and `autodev:autodev-code-review`.

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

## Repository layout

```
.github/plugin/marketplace.json   # Marketplace manifest listing both plugins
plugins/
├── autodev/                      # Planning + implementation agents, hooks, canvas, and trackers
│   ├── plugin.json               # Plugin manifest (name, version, artifacts)
│   ├── README.md                 # Plugin documentation
│   ├── hooks.json                # Hook configuration (routes to the shared hook router)
│   ├── .mcp.json                 # MCP server configuration
│   ├── agents/                   # Agent definitions (*.agent.md) for both workflows
│   ├── skills/                   # Skills (<skill-name>/SKILL.md)
│   ├── extensions/autodev-workflow/  # Workflow canvas extension
│   ├── hooks/scripts/            # Router, gate tracker, stage tracker, and OTEL emitter
│   └── tests/                    # Gate, stage, router, and workflow-canvas tests
└── autodev-factory/              # The plan-then-implement loop as an Agent Factory extension
    ├── plugin.json
    ├── README.md
    ├── install.sh / install.ps1  # Installs the extension where the CLI will find it
    ├── extensions/autodev-factory/   # extension.mjs + generated prompt bundle
    └── tests/                    # Factory unit tests and SDK stubs
samples/<sample-name>/            # Standalone teaching samples, installed by path
scripts/                         # Repository maintenance scripts, verified by CI
```

The `autodev` plugin's `plugin.json` references its `hooks.json` and `.mcp.json`. The single
`hooks.json` wires every hook event to a small router in `hooks/scripts/`, which dispatches to the
planning gate tracker or the implementation stage tracker depending on the event. The
`autodev-factory` prompt bundle is generated from the `autodev` plugin's canonical agents by
`scripts/sync-autodev-prompts.sh`, which CI verifies stays in sync.
