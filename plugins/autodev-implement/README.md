# Autodev-Implement

Takes an implementation plan — normally one produced by
[Autodev-Plan](../autodev-plan/README.md) — and drives it to a complete, reviewed implementation.
The plan is broken into milestones, each milestone is implemented and then reviewed in an isolated
context until it passes, and the finished implementation is put through security and privacy review
before the run ends.

The thing this plugin is built to prevent is the failure mode where an agent implements most of a
plan, reviews its own work, declares victory, and leaves a trail of `TODO` comments behind.
**Nothing is deferred:** the run ends with the plan implemented, or it escalates to you and says so.

## How it works

One user-invocable orchestrator coordinates six specialist sub-agents. The orchestrator never
writes code and never reviews code — it only decides what runs next and talks to you.

```
INTAKE → TASKING → ┌──────────────── for each milestone, in order ───────────────┐
                   │  IMPLEMENT → [ CODE-REVIEW ⇄ CODE-FIX ] up to 10 rounds     │
                   └────────────────────────────────────────────────────────────┘
                                              ↓ (all milestones done)
                                         USER-REVIEW  ⇄ CODE-FIX
                                              ↓ (you say proceed)
                                    SECURITY-REVIEW ⇄ CODE-FIX  up to 10 rounds
                                              ↓
                                    PRIVACY-REVIEW  ⇄ CODE-FIX  up to 10 rounds
                                              ↓
                                           WRAPUP
```

TASKING through the milestone loop runs without input from you. **USER-REVIEW is the one
checkpoint where the run stops and waits** — you read the code and either approve it or say what
needs to change, and anything you report is routed back through the fix agent. After you approve,
the security and privacy reviews run autonomously.

### Agents

| Agent | Model | Access | Role |
| --- | --- | --- | --- |
| `autodev-implement` | Claude Opus 5 | full | Orchestrator. Runs the phase machine, dispatches sub-agents, talks to you. |
| `autodev-tasking` | Claude Opus 5 | read + write | Turns the plan into `.autodev/todos.md`, split into milestones sized at one to two weeks of human dev work each. |
| `autodev-implementation` | GPT-5.5 | full | Implements exactly one milestone, runs the project's build and tests, marks its tasks done. |
| `autodev-code-review` | Claude Sonnet 5 | read-only | Reviews the milestone's changes against the plan. Required to report every finding in one pass. |
| `autodev-code-fix` | GPT-5.5 | full | Applies review findings. A finding it judges invalid is answered with a code comment explaining why the code is correct, not with a silent dismissal. |
| `autodev-code-security-review` | Claude Sonnet 5 | read-only + web | Security review of the finished implementation. |
| `autodev-code-privacy-review` | Claude Sonnet 5 | read-only | Privacy and data-protection review of the finished implementation. |

Reviewers run in their own context and never see the reasoning that produced the code. That
isolation is the point: an agent that has just talked itself into an implementation cannot
meaningfully review it.

Every sub-agent ends its response with a machine-readable verdict — `PASS`/`ISSUES` for reviewers,
`DONE`/`BLOCKED` for the others. A missing or unreadable verdict never counts as a pass.

## Enforcement

The orchestrator's instructions say what it should do. The hooks in `hooks.json` make it true.

A stage tracker (`hooks/scripts/autodev-stages.ps1` and `.sh`, behaviourally identical) observes
every sub-agent lifecycle event and:

- **counts attempts in state held outside your workspace**, keyed by session, so the orchestrator
  cannot edit its way past a review;
- **appends a footer to every sub-agent response** stating the recorded verdict, the run status,
  and the exact next action;
- **blocks the orchestrator from ending its turn mid-run** — except at USER-REVIEW, where stopping
  to wait for you is the correct behaviour;
- **records the USER-REVIEW handoff** — the security review stays locked until the orchestrator has
  actually given the code back to you, by ending its turn or asking you directly, so the last
  milestone cannot close and the final reviews start in the same turn;
- **denies `ask_user` during autonomous phases**, and unlocks it at USER-REVIEW and on escalation;
- **refuses out-of-order sub-agent calls** — nothing but tasking may open a run, no security
  review while milestones remain, no review of a milestone that has not been implemented, no new
  milestone while the current one's review is unresolved, and no re-tasking once milestone work
  has started;
- **invalidates stale verdicts** — tasking clears any milestone progress recorded before the todo
  list existed, implementing new code clears the review verdict for that milestone, and a fix
  applied after the milestones close clears the security and privacy passes, so the final reviews
  re-run against the code that actually shipped;
- **refuses any further sub-agent call once a budget is spent**, which is what actually ends a loop
  that will not converge.

Sub-agents are matched by their exact `autodev-implement:` namespace, so another installed plugin
exposing an identically named agent cannot be captured by this tracker or mutate its counters.

Milestone *structure* is read from `.autodev/todos.md` — it is the only place that information
exists, and the headings must be numbered consecutively from 1. A tasking agent that reports
success but leaves a todo list the tracker cannot walk is recorded as `BLOCKED` rather than
`DONE`, so the run retries tasking instead of starting implementation against an unusable
artifact. Milestone *progress* comes entirely from the tracker's own counters, and a count that is
already known can only be changed by the tasking agent, so editing the todo list cannot skip a
review or retire a milestone that was never built.

### Caps

| Loop | Cap | On exhaustion |
| --- | --- | --- |
| Code review, per milestone | 10 rounds | Record the outstanding findings and proceed to the next milestone |
| Security review | 10 rounds | Escalate to you |
| Privacy review | 10 rounds | Escalate to you |
| Tasking / implementation retries | 5 attempts | Escalate to you |
| Whole session | 120 + 30 per milestone invocations | Escalate to you |

The session ceiling scales with the milestone count deliberately. A fixed limit would cut a long
run off before its milestones had spent their own budgets, leaving the plan half-implemented —
which is the one outcome this workflow exists to prevent.

An escalated review never becomes passed. The run can continue at your direction, but the tracker
keeps reporting the session as escalated and the orchestrator is required to say so at wrap-up.

## Files it writes

All in `.autodev/`, beside the plan:

| File | Written by | Purpose |
| --- | --- | --- |
| `todos.md` | tasking / implementation / fix agents | The milestone todo list. The working document for the whole run. |
| `implement-gate-audit.md` | the hooks | One row per sub-agent lifecycle event. |
| `implement-feedback-log.md` | the hooks | Every sub-agent's full response, verbatim. |
| `implement-status.json` | the hooks | A live mirror of the tracker's state, and its same-session recovery checkpoint. |

The audit and feedback files exist so you can check what the reviewers actually said rather than
what the orchestrator chose to relay. The orchestrator is instructed never to edit them.

These filenames are deliberately distinct from Autodev-Plan's (`gate-audit.md`,
`feedback-log.md`, `gate-status.json`), so both plugins can run in the same repository — even in
the same session — without clobbering each other.

## OpenTelemetry

When a run is being observed with OpenTelemetry, each `subagentStop` also emits one span
describing the stage that just finished, so review `ISSUES` verdicts and blocked workers can be
counted across sessions instead of only being readable in `.autodev/`.

### Enabling it

Hook telemetry is configured with `AUTODEV_OTEL_*` variables, **not** Copilot's own `OTEL_*`
ones. Copilot CLI scrubs its telemetry configuration out of the environment it hands to command
hooks: measured against CLI 1.0.81, a hook process sees no variable whose name begins with
`OTEL_` or `COPILOT_OTEL_`, while everything else — including `AUTODEV_OTEL_*` — is inherited
normally. Setting only Copilot's variables enables Copilot's exporter but leaves the hook blind,
so it emits nothing.

The minimum needed is one variable:

```sh
export AUTODEV_OTEL_ENABLED=1     # posts to http://localhost:4318/v1/traces
```

| Variable | Purpose |
| --- | --- |
| `AUTODEV_OTEL_ENABLED` | Truthy (`1`, `true`, `yes`, `on`) turns hook telemetry on. A falsy **value** (`0`, `false`, `no`, `off`) is an explicit **off** that outranks every other signal. Unset — or set to nothing but whitespace — falls through to the rules below. |
| `AUTODEV_OTEL_ENDPOINT` | Base endpoint; `/v1/traces` is appended. Setting it is itself an opt-in, so it enables telemetry on its own. Defaults to `http://localhost:4318`, matching Copilot's own implicit default. |
| `AUTODEV_OTEL_TRACES_ENDPOINT` | Used verbatim when set, in preference to the base endpoint. Also enables telemetry on its own. |
| `AUTODEV_OTEL_PROTOCOL` | `grpc` disables export entirely — a shell script cannot speak gRPC. `http/json` and `http/protobuf` both export JSON. See the caveat below. |
| `AUTODEV_OTEL_HEADERS` | Comma-separated `key=value` pairs, percent-decoded. Header values are never logged. |
| `AUTODEV_OTEL_SERVICE_NAME` | Resource `service.name`; defaults to `github-copilot` so hook spans land beside Copilot's own. |
| `AUTODEV_OTEL_TIMEOUT_SEC` | Request timeout, default 2, clamped to a maximum of 5. |
| `AUTODEV_OTEL_DEBUG_FILE` | Writes each span document to this file, one per line, **instead of** posting it. Use this to see exactly what would be exported. It is a sink, not a switch: on its own it does not enable telemetry. |

An empty or whitespace-only value counts as *not set* rather than as an explicit off. That is
deliberate: Windows does not carry an empty variable across a process boundary, so a hook or
emitter -- both of which are child processes -- receives `AUTODEV_OTEL_ENABLED=` as unset no matter
what the parent shell did. Honouring it as an off switch would work on Linux and macOS and quietly
do nothing on Windows, which is precisely the kind of platform divergence this emitter exists to
avoid. Whitespace-only values are treated as absent for every other variable here too, endpoints
included. To turn hook telemetry off, give it a falsy value rather than an empty one.

The equivalent `COPILOT_OTEL_ENABLED`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL` / `..._TRACES_PROTOCOL`,
`OTEL_EXPORTER_OTLP_HEADERS` / `..._TRACES_HEADERS` and `OTEL_SERVICE_NAME` variables are still
read, as a fallback for hosts that do not scrub them. Endpoints are resolved one namespace at a time: if any `AUTODEV_OTEL_*` endpoint is set, the legacy pair is not consulted at all, so an inherited `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` can never outrank `AUTODEV_OTEL_ENDPOINT` despite being the more specific name.
Under Copilot CLI they are invisible, so do not rely on them.

### What is emitted

One span per `subagentStop`, named `autodev.stage <stage>`. The span marks the instant the verdict
was recorded rather than spanning the sub-agent's work: that duration belongs to Copilot's own
sub-agent span, which measures it in-process.

| Attribute | Value |
| --- | --- |
| `gen_ai.conversation.id`, `github.copilot.session.id` | The session id, matching Copilot's own spans |
| `github.copilot.agent.name`, `github.copilot.agent.id` | The sub-agent |
| `autodev.plugin` | `autodev-implement` |
| `autodev.stage` | `tasking`, `implementation`, `code-review`, `code-fix`, `code-security-review` or `code-privacy-review` |
| `autodev.verdict` | `PASS`/`ISSUES` for review agents, `DONE`/`BLOCKED` for workers |
| `autodev.issues` | `1` only for a literal `ISSUES` verdict, else `0` |
| `autodev.blocked` | `1` only for a literal `BLOCKED` verdict, else `0` |
| `autodev.attempt`, `autodev.total_invocations` | Attempt counters for this stage and session |

The two counters are deliberately separate: a blocked worker is an operational stall, not a review
finding, so folding it into `autodev.issues` would inflate the issue count. Sum `autodev.issues`
for review findings and `autodev.blocked` for stalls.

**No sub-agent content is ever exported** — not the response body, not the todo list, not the
prompt, and not `transcriptPath`. Only verdicts and identifiers leave the machine.

### The emitter only speaks OTLP/JSON

The emitter always sends HTTP/JSON, because building protobuf from a shell script is not
practical. `grpc` is refused outright rather than sent JSON at a gRPC port.

`http/protobuf` is **not** refused. The OTLP specification requires a receiver to support
protobuf but makes JSON support optional, so a protobuf-configured backend is permitted to reject
the JSON body. In practice the OpenTelemetry Collector accepts both on the same port, so refusing
to export would break the common case to protect against the rare one. Against a strict
protobuf-only backend, spans are dropped at the receiver and the emitter cannot tell, since it
discards transport errors by design. Set `AUTODEV_OTEL_DEBUG_FILE` to confirm the emitter is
producing spans, then check whether your endpoint accepts `Content-Type: application/json`.

### Cost when telemetry is off

With no `AUTODEV_OTEL_*` variable set — the default for essentially every user — no emitter process
is spawned, no temp file is written and no network call is made. The residual cost is a shell
`case` on one environment variable. The hooks keep no telemetry state at all: the span is built
entirely from the `subagentStop` payload and the counters the tracker already maintains for
enforcement, so enabling telemetry part way through a session works immediately and needs no
warm-up.

### Correlating with Copilot's own traces

The emitter reads `traceparent` (and `tracestate`) from the hook payload. When present, the span
is emitted as a **child of Copilot's own sub-agent span**: it adopts that trace id, sets
`parentSpanId`, and the verdict shows up directly on the sub-agent's trace.

Copilot CLI does not supply trace context to command hooks yet. Until it does, each span is its
own root trace and correlates by attribute instead: Copilot records its session id as
`gen_ai.conversation.id`, and the emitter exports the same raw value, so joining on it in your
backend is exact rather than manual. Nothing needs to change in this plugin when the CLI starts
sending the header — the spans simply start arriving parented.

A malformed, reserved (`ff`), or all-zero `traceparent` is ignored rather than trusted, and the
span falls back to a root.

### Reliability

Export is **best-effort and never authoritative**. A network failure drops a span silently, and a
redelivered hook would double-count; `github.copilot.agent.id` and `autodev.attempt` are exported
so duplicates can be identified at query time. Telemetry can never affect a session: the emitter
runs as a separate process with both output streams discarded, is killed if it exceeds its
budget, and its failure cannot change the hook's stdout or exit code.

On Linux and macOS the export path also needs `curl`; without it telemetry is skipped and
everything else still works.

`hooks/scripts/autodev-otel.ps1` and `autodev-otel.sh` are **copies**. The canonical versions live
in `plugins/autodev-plan/hooks/scripts/` and are propagated by `scripts/sync-otel-emitter.sh`,
which CI runs in `--check` mode. Edit the canonical copies, not these.

## Installation

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev-implement@autodev-plugins
```

## Usage

Run [Autodev-Plan](../autodev-plan/README.md) first, or bring your own plan document, then:

```
copilot --agent autodev-implement:autodev-implement
```

> Agents contributed by a plugin are namespaced `<plugin>:<agent>`, so the entry point is
> `autodev-implement:autodev-implement`. The bare name is not accepted.

Tell it what to implement, or just point it at the plan. It defaults to `./.autodev/plan.md`.

Expect it to:

1. Confirm the plan path, check whether `.autodev/` is git-ignored, and orient itself in the repo.
2. Report the milestone breakdown, then work through the milestones without further input.
3. Stop at USER-REVIEW and wait for you.
4. Run the security and privacy reviews after you approve.
5. Report the paths to the todo list, audit trail, and feedback log, and state plainly anything
   that did not get resolved.

## Development

The tracker is the risky part of this plugin: `preToolUse` hooks are **fail-closed**, so a crash
would deny the tool call. Both implementations are wrapped end to end, always emit valid JSON, and
always exit 0. Both have test suites, and both run in CI.

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests/stages.tests.ps1
bash tests/stages.tests.sh
```

Add `--sequential` / `-Sequential` for output grouped by section when diagnosing a failure. The
suites are case-for-case equivalent; a change to one tracker needs the same change and the same
test in the other.

Shell scripts must keep LF endings (enforced by `.gitattributes` and checked in CI) — a CRLF
shebang makes the hook unrunnable on Linux and macOS.
