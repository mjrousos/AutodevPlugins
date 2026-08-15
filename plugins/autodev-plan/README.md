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
| 8 | **WRAPUP** — reports plan path, tracker artifacts, and what the reviews changed | yes |

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

1. **10 attempts per gate, per pass.** A gate re-run after a material change starts a fresh
   budget rather than inheriting the previous pass's count.
2. **40 total reviewer invocations per session**, which bounds re-gate cascades.
3. **The CLI's own runaway guard** on forced continuations, which this plugin stays below.

On hitting a limit the workflow **escalates**: blocking stops, `ask_user` is re-permitted, and
the orchestrator brings you in with an explanation of why it is not converging.

Escalation is enforced, not merely requested. Once a gate is out of attempts the `preToolUse`
hook **denies any further `task` call to a reviewer agent**, so an orchestrator that ignores the
instruction to stop still cannot start another review. Non-reviewer sub-agents stay available so
it can still write up the escalation.

### Watching a run: the `.autodev/` directory

Everything the tracker records is mirrored next to the plan, in the same `.autodev/` directory,
so you can follow a run while it happens and read the reviews afterwards:

| File | What it holds |
| --- | --- |
| `.autodev/plan.md` | The plan itself, written by the orchestrator |
| `.autodev/gate-status.json` | Per-gate attempt counts and verdicts, refreshed on every event |
| `.autodev/gate-audit.md` | One row per reviewer lifecycle event |
| `.autodev/feedback-log.md` | Every reviewer response, verbatim |

`.autodev/` is gitignored (the orchestrator offers to add it on first use), so none of this ends
up in version control.

The state that normally enforces the gates lives at
`<COPILOT_HOME>/autodev-plan/gates/<sessionId>.json`, outside the workspace and keyed by session.
That split is deliberate:

- The orchestrator is allowed to edit files in the workspace while gating, so state it could
  rewrite must not be the normal source of enforcement.
- Two sessions running in the same repository keep independent attempt budgets, so they cannot
  reset each other's counters and quietly disable every cap.

`.autodev/gate-status.json` is both the live developer-facing view and a **disaster-recovery
checkpoint**. The tracker reads it only when the authoritative file is missing or corrupt, and
only when its `sessionId` exactly matches the current session. This prevents a lost
`<COPILOT_HOME>` state directory from making the next reviewer look like a new session, resetting
the audit/feedback logs, and re-running gates that already passed.

The three tracker files are written **only** by hooks — the orchestrator does not write them and
is instructed not to edit them. In particular, never edit `gate-status.json`: normal enforcement
ignores it while the authoritative state exists, but it may be needed to recover the same
session. If you run two autodev-plan sessions in one directory they will share these files (as
they would share `plan.md`), so the logs interleave and the single recovery checkpoint belongs to
whichever session wrote it last; the enforcement state behind them stays separate. Recovery,
like the plan itself, assumes one active autodev-plan session per directory.

#### `gate-status.json`

Refreshed on every reviewer start and finish, so `cat`-ing it mid-run tells you exactly where a
session is:

```json
{
  "sessionId": "549a2b9c-e26b-4d38-8b8a-6ac7d0b012d4",
  "architectureAttempts": 2, "architectureVerdict": "PASS",
  "securityAttempts": 1,     "securityVerdict": "running",
  "privacyAttempts": 0,      "privacyVerdict": "pending",
  "totalInvocations": 3, "blocks": 0
}
```

A verdict is `pending` (not yet run), `running` (in flight), `PASS`, or `ISSUES`.

#### `gate-audit.md`

```
| Time (UTC)          | Gate         | Attempt | Event     | Verdict |
| ------------------- | ------------ | ------- | --------- | ------- |
| 2026-08-04 20:23:25 | architecture | 1       | invoked   | -       |
| 2026-08-04 20:26:13 | architecture | 1       | completed | ISSUES  |
| 2026-08-04 20:31:24 | architecture | 2       | invoked   | -       |
```

Every row is written by a hook observing a real sub-agent lifecycle event. If the gates did not
genuinely run, the trail will show it.

#### `feedback-log.md`

The audit trail tells you *that* a gate objected; this tells you *what* it objected to. Each
entry is the reviewer's full response, exactly as written. Entry headers are level 1, because
reviewers use `##` and `###` for their own sections:

```markdown
---

# architecture - attempt 1 - ISSUES

_2026-08-04 20:26:13 UTC_

## Summary
...

### blocker Undo bypasses the server's move pipeline
...
```

This exists because the orchestrator summarises reviewer findings as it goes, and a summary is
lossy. When you want to audit a decision — or disagree with one — read this file.

`gate-audit.md` and `feedback-log.md` are **append-only across reviewers and planning sessions**.
A new session adds a `Session: <id>` section and keeps every older row and reviewer response; the
tracker never deletes or clears either Markdown file, including after wrap-up. This is deliberate
human-review history, so archive or delete it manually only when you no longer need it.

`gate-status.json` is different: it remains the live/recovery state for the most recent session
in that workspace and is overwritten as that session advances.

### Escalation is enforced by refusing the tool call

Once a gate is out of attempts the `preToolUse` hook denies any further `task` call to a reviewer
agent. That refusal is driven by the out-of-workspace state, so an orchestrator cannot lift it by
editing `.autodev/`. Non-reviewer sub-agents stay available so it can still write up the
escalation.

## OpenTelemetry

When a run is being observed with OpenTelemetry, each `subagentStop` also emits one span
describing the gate that just finished, so `ISSUES` verdicts can be counted across sessions
instead of only being readable in `.autodev/`.

### Enabling it

The emitter reuses Copilot CLI's own telemetry variables, so hook telemetry switches on and off
with Copilot's. It exports only when **both** are set:

| Variable | Purpose |
| --- | --- |
| `COPILOT_OTEL_ENABLED` | Must be truthy (`1`, `true`, `yes`, `on`). Unset means no telemetry, and no child process is spawned at all. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Base endpoint; `/v1/traces` is appended. Copilot's implicit `http://127.0.0.1:4318` default is deliberately not assumed. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Used verbatim when set, in preference to the base endpoint. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` / `..._TRACES_PROTOCOL` | `grpc` disables export entirely — a shell script cannot speak gRPC. `http/json` and `http/protobuf` both export JSON. See the caveat below. |
| `OTEL_EXPORTER_OTLP_HEADERS` / `..._TRACES_HEADERS` | Comma-separated `key=value` pairs, percent-decoded. The signal-specific variable wins. Header values are never logged. |
| `OTEL_SERVICE_NAME` | Resource `service.name`; defaults to `github-copilot` so hook spans land beside Copilot's own. |
| `AUTODEV_OTEL_TIMEOUT_SEC` | Request timeout, default 2, clamped to a maximum of 5. |
| `AUTODEV_OTEL_DEBUG_FILE` | Writes each span document to this file, one per line, **instead of** posting it. Use this to see exactly what would be exported. |

### What is emitted

One span per `subagentStop`, named `autodev.gate <gate>`, covering the reviewer's real runtime.

| Attribute | Value |
| --- | --- |
| `gen_ai.conversation.id`, `github.copilot.session.id` | The session id, matching Copilot's own spans |
| `github.copilot.agent.name`, `github.copilot.agent.id` | The reviewer sub-agent |
| `autodev.plugin` | `autodev-plan` |
| `autodev.gate` | `architecture`, `security` or `privacy` |
| `autodev.verdict` | `PASS` or `ISSUES` |
| `autodev.issues` | `1` for an `ISSUES` verdict, else `0` |
| `autodev.blocked` | Always `0` here; present so a query spanning both plugins needs no special case |
| `autodev.attempt`, `autodev.total_invocations` | Attempt counters for this gate and session |

To count issues, sum `autodev.issues`, or count spans where `autodev.verdict = "ISSUES"`.

**No reviewer content is ever exported** — not the response body, not the plan, not the prompt,
and not `transcriptPath`. Only verdicts and identifiers leave the machine.

### The emitter only speaks OTLP/JSON

This is worth knowing before you point it at a non-Collector backend. The emitter always sends
HTTP/JSON, because building protobuf from a shell script is not practical. `grpc` is therefore
refused outright rather than sent JSON at a gRPC port.

`http/protobuf` is a softer case and is **not** refused. The OTLP specification requires a
receiver to support protobuf but makes JSON support optional, so a backend configured for
protobuf is permitted to reject the JSON body. In practice the OpenTelemetry Collector — by far
the most common target, and what Copilot CLI's own documented setup points at — accepts both on
the same port, so refusing to export would break the common case to protect against the rare one.

The trade-off is that against a strict protobuf-only backend, spans are dropped at the receiver
and the emitter cannot tell: it discards transport errors by design, because surfacing them would
mean writing to a hook's stdout. If you are exporting somewhere other than a Collector and see no
`autodev.*` spans, set `AUTODEV_OTEL_DEBUG_FILE` to confirm the emitter is producing them, then
check whether your endpoint accepts `Content-Type: application/json`.

### Correlating with Copilot's own traces

Hook payloads carry no W3C trace context, so these spans **cannot** be children of Copilot's
spans; each is its own root trace. They are correlated by attribute instead: Copilot records its
session id as `gen_ai.conversation.id`, and the emitter exports the same raw value, so joining on
it in your backend is exact rather than manual.

### Reliability

Export is **best-effort and never authoritative**. A network failure drops a span silently, and a
redelivered hook would double-count; `github.copilot.agent.id` and `autodev.attempt` are exported
so duplicates can be identified at query time. Telemetry can never affect a session: the emitter
runs as a separate process with both output streams discarded, is killed if it exceeds its
budget, and its failure cannot change the hook's stdout or exit code.

## Requirements

- **Windows** — no extra prerequisites. Hooks run through the built-in `powershell.exe`, and the
  script is Windows PowerShell 5.1 compatible.
- **Linux / macOS** — hooks require [`jq`](https://jqlang.github.io/jq/). If `jq` is missing the
  hooks degrade to a no-op: enforcement and the audit trail are disabled, but sessions are never
  broken. OpenTelemetry export additionally needs `curl`; without it telemetry is skipped and
  everything else still works.

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
│   ├── autodev-gates.sh              # Gate tracker (Linux/macOS, needs jq)
│   ├── autodev-otel.ps1              # OTLP span emitter (Windows) - canonical copy
│   └── autodev-otel.sh               # OTLP span emitter (Linux/macOS) - canonical copy
└── tests/
    ├── gates.tests.ps1               # Gate tracker tests (Windows)
    └── gates.tests.sh                # Gate tracker tests (Linux/macOS)
```

Both trackers implement the same state machine and are dispatched by event name. They are written
to **fail open**: `preToolUse` hooks are fail-closed by design in the CLI, so a crash there would
permanently break `ask_user`. Every path is wrapped, always emits valid JSON, and always exits 0.

The two `autodev-otel.*` files are the canonical copies. `autodev-implement` ships byte-identical
copies of them, kept in sync by `scripts/sync-otel-emitter.sh`; CI runs that script in `--check`
mode and fails on any drift. Edit the copies here, never the ones in the other plugin.

## Tests

The two gate tracker implementations have to stay behaviorally identical, so both are covered by
an equivalent suite. Each test runs the hook script as a real subprocess — feeding a payload on
stdin and asserting on the single JSON object it writes to stdout. Every test gets its own
temporary working directory (and an isolated `COPILOT_HOME`), so running them never touches real
session state.

```
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File plugins/autodev-plan/tests/gates.tests.ps1

# Linux / macOS (requires jq)
bash plugins/autodev-plan/tests/gates.tests.sh
```

Because every assertion costs a process spawn — roughly a second on Windows, once PowerShell
startup and the JSON cmdlets are paid for — the suites shard themselves across parallel workers
by default. That takes a full run from about 11 minutes to about 90 seconds. When you are
diagnosing a failure and want output grouped by section in a single ordered run:

```
powershell ... -File plugins/autodev-plan/tests/gates.tests.ps1 -Sequential
bash plugins/autodev-plan/tests/gates.tests.sh --sequential
```

Both accept a worker count (`-Workers 4` / `--workers 4`). Sequential and parallel runs execute
exactly the same cases; only the ordering and the section headings differ.

A few tests seed the tracker's state file directly rather than driving forty real rounds to
reach a limit. That is a deliberate trade: the tests that cover *accumulation* — the 9-versus-10
attempt boundary, and two sessions counting independently — still push every round through the
hook.

Coverage includes verdict parsing (including the negatives — a verdict mentioned in prose must
never count), the enforcement decisions, all three loop bounds, the refusal of further reviewer
invocations once the budget is spent, re-gate invalidation, the `.autodev/` artifacts (including
that a new session does not inherit a previous run left in the same directory), and the
fail-safe paths: corrupt state, empty and garbage stdin, malformed `task` arguments,
non-reviewer sub-agents, a hostile session id, and a missing `jq`.

The suites also assert on `hooks.json` itself, because that file is what connects everything
above to the CLI and a typo there would disable enforcement entirely while every other test
stayed green. Those checks cover the matcher patterns (applied the way the CLI applies them,
anchored as `^(?:PATTERN)$`), that each entry dispatches its own event name to the right script
via `${PLUGIN_ROOT}`, that `powershell` is used rather than `pwsh`, and that every referenced
script exists.

CI runs the PowerShell suite on Windows and the bash suite on both Linux and macOS, and also
validates every JSON manifest and checks that no `*.sh` file has CRLF endings — a CRLF shebang
would make the hooks unrunnable on Linux and macOS.

### What the automated tests do not cover

Worth knowing before trusting a green run:

- **The agent prompts.** Whether the orchestrator actually runs the gates in order, applies the
  material-change rule, and escalates properly is model behavior, not script behavior. Nothing
  here asserts on it.
- **Whether the reviewers emit a parseable verdict.** If a reviewer stops following the contract
  the fail-safe records `ISSUES`, so the workflow degrades into wasted attempts rather than
  failing loudly.
- **Concurrency.** State writes are atomic, but no test drives two hooks at once.
- **The whole thing working together.** Covered by the manual walkthrough below.

## Manual end-to-end check

The automated suites test the gate tracker in isolation. This walkthrough exercises the real
thing — CLI, plugin loading, agents, sub-agent isolation, and hooks — and is worth running after
changing the agent prompts, the hook wiring, or the pinned models, and when adopting a new CLI
version.

Budget roughly 45–60 minutes and a few thousand AI credits, since it runs real reviews.

**1. Create a throwaway repo with something worth reviewing.** Pick a feature with genuine
security and privacy surface — authentication, data export, and file upload all work well. A
trivial feature produces a trivial plan and proves little.

```
mkdir /tmp/autodev-e2e && cd /tmp/autodev-e2e && git init
# add a small, realistic app skeleton (a few files is enough)
```

**2. Run the orchestrator against the plugin from your working copy.**

```
copilot -C /tmp/autodev-e2e --plugin-dir /path/to/plugins/autodev-plan \
  --agent autodev-plan:autodev-plan
```

Describe the feature and let the workflow run. To keep an unattended run short you can
pre-answer the clarifying questions in the initial prompt and tell it to skip the approval step.

**3. Check the tracker artifacts**, in `/tmp/autodev-e2e/.autodev/`. These are the primary
evidence: they are written by hooks observing real sub-agent events, so the orchestrator cannot
fake them. Start with `gate-audit.md`.

Expect to see, in order:

- `architecture`, then `security`, then `privacy` — gates must not interleave
- at least one `invoked` row per gate, each followed by a `completed` row with a verdict
- attempt numbers incrementing within a gate whenever a verdict was `ISSUES`
- every gate ending on `PASS` (or an escalation you were asked about)

Then open `feedback-log.md` and compare it against what the orchestrator told you in the
transcript. Every `ISSUES` round should have a corresponding entry, and the findings the
orchestrator described should be recognisably the ones the reviewer actually raised.

Tailing `gate-status.json` during the run is the easiest way to watch progress live.

**4. Confirm the things that are easy to get wrong.**

| Check | What you are confirming |
| --- | --- |
| A `premature-stop-blocked` row appears if the agent tried to stop early | `agentStop` enforcement is live |
| The plan file exists at the agreed path and reflects reviewer feedback | Findings were applied, not just acknowledged |
| You were not asked anything between approval and wrap-up | The gate phase stayed autonomous |
| Wrap-up reports the plan path, the audit trail and the feedback log | The orchestrator followed through |
| Reviewer responses carry a `[autodev-plan gate tracker]` footer | The hooks are loaded and rewriting responses |
| The orchestrator listed each finding, with severity, before revising | Reviewer feedback is visible to you, not just summarised away |

If the footer never appears, the plugin's hooks are not loading — everything else in the run is
then unverified, whatever the transcript claims.

**5. Sanity-check the review quality.** Skim the findings and ask whether a competent reviewer
would have raised them. The gates are only worth their cost if they catch real problems; a run
where all three pass on the first attempt with a substantial feature is a signal the reviewers
have gone toothless, not a success.

**6. Optionally, prove the cap holds.** Escalation is the hardest path to reach naturally. To
force it, edit the session's enforcement state at
`<COPILOT_HOME>/autodev-plan/gates/<sessionId>.json` mid-run and set `architectureAttempts` to
`10` with `architectureVerdict` as `ISSUES`. The next reviewer invocation must be **denied** with
an "out of budget" message, and the orchestrator must escalate to you rather than retrying.
Editing `.autodev/gate-status.json` instead must have no effect on this check while the
authoritative state exists. Do not delete the authoritative file afterwards: the workspace copy
is also its same-session recovery checkpoint.

**7. Clean up.**

```
rm -rf /tmp/autodev-e2e
```
