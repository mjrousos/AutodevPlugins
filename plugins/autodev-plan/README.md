# Autodev-Plan

Turns a rough feature request into an implementation plan that has survived three independent
expert reviews — architecture, security, and privacy — each run in an **isolated sub-agent
context** so its judgment is not contaminated by the reasoning that produced the plan.

## Installation

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev-plan@autodev-plugins
```

## Usage

Select the `autodev-plan` agent and describe the feature you want planned. From the CLI:

```
copilot --agent autodev-plan:autodev-plan
```

> Agents contributed by a plugin are namespaced `<plugin>:<agent>`, so the entry point is
> `autodev-plan:autodev-plan`. The bare name is not accepted.

## Workflow

| Step | Phase | Human involved? |
| --- | --- | --- |
| 1 | **INTAKE** — establish the request and the plan file path | yes |
| 2 | **CLARIFY** — orchestrator asks clarifying questions until it can write a real plan | yes |
| 3 | **DRAFT** — plan written to disk | no |
| 4 | **APPROVE** — you review, request changes, and give the go-ahead | yes |
| 5 | **GATE: architecture** — loops until clean | **no** |
| 6 | **GATE: security** — loops until clean | **no** |
| 7 | **GATE: privacy** — loops until clean | **no** |
| 8 | **WRAPUP** — reports plan path, audit trail, and what the reviews changed | yes |

Steps 5–7 run sequentially and **fully autonomously**. Each reviewer returns a verdict; anything
other than a pass sends the orchestrator back to revise the plan and re-invoke that same
reviewer.

The plan is written to `./.autodev/plan.md` by default. The orchestrator offers to add
`.autodev/` to your `.gitignore` and will not touch `.gitignore` without asking.

## Agents

| Agent | Invocable by | Model | Tools | Role |
| --- | --- | --- | --- | --- |
| `autodev-plan` | user | Claude Opus 5 | all | Orchestrator and the only agent you talk to |
| `autodev-architecture-review` | orchestrator only | GPT-5.6 Terra | read, search | Decomposition, coupling, failure modes, testability |
| `autodev-security-review` | orchestrator only | GPT-5.6 Terra | read, search, web | Authn/authz, injection, secrets, supply chain, trust boundaries |
| `autodev-privacy-review` | orchestrator only | GPT-5.6 Terra | read, search | Data inventory, minimization, retention, telemetry leakage |

Each agent pins its own model via the `model` frontmatter key, so they run on the intended
model regardless of the model selected for your session. Using a different model family for the
reviewers than for the orchestrator is deliberate: a reviewer is more likely to catch what the
author missed when it does not share the author's blind spots.

The reviewers are `user-invocable: false`, so they stay out of your agent picker. Their tool
allowlists deliberately exclude `ask_user` and `edit`: reviewers *report*, the orchestrator
*fixes*.

They are prefixed `autodev-` because the CLI already ships built-in `security-review` and
`code-review` agents that would otherwise collide.

## Enforcement

Prompt instructions alone cannot guarantee that the gates actually ran in isolation, so this
plugin ships hooks that observe and enforce the workflow. The orchestrator cannot bypass them.

| Hook | What it does |
| --- | --- |
| `subagentStart` | Records that a gate was invoked and increments its attempt counter |
| `subagentStop` | Parses the reviewer's verdict, records it, and appends a tracker footer to the response |
| `agentStop` | **Blocks** the orchestrator from ending its turn while gates are outstanding |
| `preToolUse` | **Denies** `ask_user` during gating, keeping steps 5–7 free of human interaction |

Gating is **inferred, never declared**: it begins the first time a reviewer sub-agent starts, and
ends when all three hold a pass. Sessions that never invoke the orchestrator are completely
unaffected.

### Verdict contract

Every reviewer ends its response with:

```
AUTODEV-VERDICT: PASS
```

or `AUTODEV-VERDICT: ISSUES`. A **missing or unparseable verdict is recorded as `ISSUES`**, so a
malfunctioning reviewer can never wave a plan through.

### Loop bounds

Three independent layers make an infinite loop impossible:

1. **5 attempts per gate, per pass.** A gate re-run after a material change starts a fresh
   budget rather than inheriting the previous pass's count.
2. **20 total reviewer invocations per session**, which bounds re-gate cascades.
3. **The CLI's own runaway guard** on forced continuations, which this plugin stays below.

On hitting a limit the workflow **escalates**: blocking stops, `ask_user` is re-permitted, and
the orchestrator brings you in with an explanation of why it is not converging.

### Audit trail

Written to `<COPILOT_HOME>/autodev-plan/gates/<sessionId>.md` (`COPILOT_HOME` defaults to
`~/.copilot`), alongside a `.json` state file. Nothing is written into your repository.

```
| Time (UTC)          | Gate         | Attempt | Event     | Verdict |
| ------------------- | ------------ | ------- | --------- | ------- |
| 2026-08-04 20:23:25 | architecture | 1       | invoked   | -       |
| 2026-08-04 20:26:13 | architecture | 1       | completed | ISSUES  |
| 2026-08-04 20:31:24 | architecture | 2       | invoked   | -       |
```

Every row is written by a hook observing a real sub-agent lifecycle event — the orchestrator
cannot write to this file. If the gates did not genuinely run, the trail will show it.

## Requirements

- **Windows** — no extra prerequisites. Hooks run through the built-in `powershell.exe`, and the
  script is Windows PowerShell 5.1 compatible.
- **Linux / macOS** — hooks require [`jq`](https://jqlang.github.io/jq/). If `jq` is missing the
  hooks degrade to a no-op: enforcement and the audit trail are disabled, but sessions are never
  broken.

## Layout

```
plugins/autodev-plan/
├── plugin.json
├── hooks.json                        # Four hook entries wired to the scripts below
├── .mcp.json                         # Empty; this plugin needs no MCP servers
├── agents/
│   ├── autodev-plan.agent.md         # Orchestrator (entry point)
│   ├── autodev-architecture-review.agent.md
│   ├── autodev-security-review.agent.md
│   └── autodev-privacy-review.agent.md
└── hooks/scripts/
    ├── autodev-gates.ps1             # Gate tracker (Windows)
    └── autodev-gates.sh              # Gate tracker (Linux/macOS, needs jq)
```

Both scripts implement the same state machine and are dispatched by event name. They are written
to **fail open**: `preToolUse` hooks are fail-closed by design in the CLI, so a crash there would
permanently break `ask_user`. Every path is wrapped, always emits valid JSON, and always exits 0.
