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

The reviewers are `user-invocable: false`, so they stay out of your agent picker while remaining
invocable by the orchestrator. They are prefixed `autodev-` because the CLI already ships
built-in `security-review` and `code-review` agents that would otherwise collide.

### Why the reviewers list `tools` and the orchestrator does not

This asymmetry is deliberate and load-bearing, and it is easy to misread as an oversight when
skimming the agent files.

The `tools` frontmatter key is an **allowlist**: omit it and the agent gets every tool; specify
it and the agent gets *only* what is listed. So on a reviewer, the interesting part of
`tools: ["read", "search"]` is not what it grants — it is what it leaves out.

The omissions that matter:

- **`ask_user` and any other elicitation tool.** This is the primary reason the key is present
  at all. Requirement: the review gates must complete with no human interaction. An agent that
  cannot reach the user cannot stall waiting on one, cannot quietly turn a judgment call back
  into a question, and cannot interrupt an otherwise unattended run. The `preToolUse` hook
  denies `ask_user` during gating as well, but that hook is a *runtime* backstop; the allowlist
  means the tool is never offered to the reviewer in the first place.
- **`edit`, `create` and the write tools.** Reviewers report, the orchestrator fixes. A reviewer
  that could edit the plan could quietly resolve its own findings, and the verdict would then
  describe a document nobody agreed to.
- **`task`.** A reviewer cannot spawn further sub-agents, so a gate cannot fan out into work the
  tracker never sees.

The orchestrator does the opposite and **omits `tools` entirely**, which grants everything. That
is also intentional: it genuinely needs `ask_user` for the clarifying and wrap-up phases, and
`ask_user` is not among the documented tool aliases, so naming an explicit allowlist risks
silently dropping the one tool the workflow depends on most. Leaving the key off is the safer
failure mode.

The net effect is that each agent's tool surface encodes its role: reviewers *cannot* talk to
the user or change the plan even if their prompt were ignored, while the orchestrator retains
the full surface and is instead constrained at runtime by the hooks.

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
├── hooks/scripts/
│   ├── autodev-gates.ps1             # Gate tracker (Windows)
│   └── autodev-gates.sh              # Gate tracker (Linux/macOS, needs jq)
└── tests/
    ├── gates.tests.ps1               # Gate tracker tests (Windows)
    └── gates.tests.sh                # Gate tracker tests (Linux/macOS)
```

Both scripts implement the same state machine and are dispatched by event name. They are written
to **fail open**: `preToolUse` hooks are fail-closed by design in the CLI, so a crash there would
permanently break `ask_user`. Every path is wrapped, always emits valid JSON, and always exits 0.

## Tests

The two gate tracker implementations have to stay behaviorally identical, so both are covered by
an equivalent suite. Each test runs the hook script as a real subprocess — feeding a payload on
stdin and asserting on the single JSON object it writes to stdout — against an isolated
`COPILOT_HOME`, so running them never touches real session state.

```
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File plugins/autodev-plan/tests/gates.tests.ps1

# Linux / macOS (requires jq)
bash plugins/autodev-plan/tests/gates.tests.sh
```

Coverage includes verdict parsing (including the negatives — a verdict mentioned in prose must
never count), the enforcement decisions, all three loop bounds, re-gate invalidation, the audit
trail, and the fail-safe paths: corrupt state, empty and garbage stdin, non-reviewer sub-agents,
a hostile session id, and a missing `jq`.

CI runs the PowerShell suite on Windows and the bash suite on both Linux and macOS, and also
validates every JSON manifest and checks that no `*.sh` file has CRLF endings — a CRLF shebang
would make the hooks unrunnable on Linux and macOS.
