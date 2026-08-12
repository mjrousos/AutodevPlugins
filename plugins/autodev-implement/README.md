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
- **refuses out-of-order sub-agent calls** — no security review while milestones remain, no review
  of a milestone that has not been implemented, no new milestone while the current one's review is
  unresolved, and no re-tasking once milestone work has started;
- **invalidates stale verdicts** — implementing new code clears the review verdict for that
  milestone, and a fix applied after the milestones close clears the security and privacy passes,
  so the final reviews re-run against the code that actually shipped;
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
