# Sample: a small Agent Factory

An **Agent Factory** is a JavaScript orchestration that coordinates many subagents and durable
steps as a single, resumable run. This sample is one — about 300 lines including the comments that
explain it, no dependencies, and every primitive used exactly once.

It is meant to be read more often than it is run.

If you want the production-scale version afterwards, the `autodev` plugin in this repository is the
same API at 2,000 lines with approval gates, an audit trail, and review loops.

> **Status:** Agent Factories are an **experimental** SDK surface and may change or be removed in
> a future CLI or SDK release. Measured against Copilot CLI 1.0.81.

## What it does

`sample-review` reviews a target through several independent **lenses** in parallel, then has each
finding attacked by independent **skeptics** before reporting it. Findings a majority of skeptics
fail to refute come back confirmed; the rest come back *unconfirmed* rather than deleted.

```
Intake ──▶ Review ─┬─▶ find:correctness ─▶ verify:correctness:0:{0,1}  ─┐
                   │                    └▶ verify:correctness:1:{0,1}  ─┤
                   └─▶ find:security    ─▶ verify:security:0:{0,1}      ─┼─▶ Report
                                        └▶ verify:security:1:{0,1}      ─┘
```

The review itself is not the point — the *shape* is. Fan out, verify what came back, report what
survived. That shape is why this is a factory and not a single subagent: no one prompt can be
both the advocate and the skeptic for its own findings.

**A skeptic that fails to answer abstains; it does not acquit.** The quorum is a strict majority
of the skeptics that were *requested*, not of however many happened to reply. Dividing by the
replies received would lower the bar exactly when the evidence got weaker — with 3 verifiers and
2 failures, one unrefuted vote would "win 1–0" and promote the finding. This is the same class of
bug as the three below, and it is the reason `votes` is reported as
`{ requested, responded, supporting, refuting, quorum }` rather than as a bare count.

## Quick start

Install the extension, reload, and run it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File samples\factory-review\install.ps1
```

```bash
samples/factory-review/install.sh          # --project to install into .github/extensions instead
```

Then in Copilot CLI, `/extensions` to reload (or restart it). There are three ways to start it.

**The slash command**, which the extension registers itself:

```
/review-factory samples/factory-review/extensions/factory-review/extension.mjs
```

The argument is optional — `/review-factory` on its own reviews the factory's default target. See
[The slash command](#the-slash-command) for how it is wired up.

**By asking the agent**, which reaches the same factory through the `run_factory` tool:

```
Run the sample-review factory on samples/factory-review/extensions/factory-review/extension.mjs
```

**Or drive the tools directly:**

| Step | Tool call |
|---|---|
| Confirm it registered | `factories_manage` → `list` |
| Read its args and phases | `factories_manage` → `inspect`, `name: "sample-review"` |
| Run it | `run_factory` → `{ name: "sample-review", args: { target: "src/parser.ts" } }` |
| Find a past run's ID | `factories_manage` → `runs` |

**The cheapest possible first run** is two subagents — one finder, one skeptic:

```json
{ "name": "sample-review",
  "args": { "target": "README.md", "lenses": ["clarity"], "maxFindings": 1, "verifiers": 1 } }
```

## Arguments

There is **no declared schema for `ctx.args`**. `run_factory` forwards them verbatim and its
parameter is untyped, so `meta.description` is the *only* thing telling a model what to pass —
which is why the shape is spelled out there, and why `run()` validates rather than assumes.

| Argument | Meaning | Default |
|---|---|---|
| `target` | A file path, a directory, a diff, or a free-text description | the most recently changed code in the working tree |
| `lenses` | Review dimensions, one finder subagent each. Deduplicated case-insensitively, capped at 5 | `["correctness", "security"]` |
| `maxFindings` | Findings per lens carried into verification, 1–5 | `2` |
| `verifiers` | Independent skeptics per finding, 1–3 | `2` |

## The three silent failures

Every one of these compiles, runs, and produces a plausible-looking result that is wrong. They are
the reason this sample is worth reading; they are marked `GOTCHA` in the source.

### 1. Identical calls memoize into one subagent

`ctx.agent` is journaled by its canonical prompt **and options, including `label`**. Two calls with
the same prompt and the same options return one shared result — even when issued concurrently.

```js
// One subagent, awaited five times. Five identical "independent" votes from a single agent.
await ctx.parallel([1, 2, 3, 4, 5].map(() => () => ctx.agent("Find a bug")));

// Five independent subagents.
await ctx.parallel([1, 2, 3, 4, 5].map((i) =>
    () => ctx.agent("Find a bug", { label: `finder:${i}` })));
```

This is why the sample gives every subagent a unique label, why the skeptics get *different*
questions from `VERIFIER_ANGLES`, and why duplicate lens names are deduplicated in Intake — two
lenses named `security` would collide on `find:security` and silently become one reviewer.

### 2. An ordinary failure resolves to `null`, it does not throw

A subagent that errors, returns nothing, or — with a schema — produces output that still fails to
parse or match after its one automatic retry resolves to `null`. **A bare `await ctx.agent(...)`
needs a guard too.**

```js
const finding = await ctx.agent(prompt, { label: "inspector" });
if (!finding) return { finding: null };
```

Cancellation, a reached limit, and hard runtime failures (`ResponseError`, `ConnectionError`) are
the exception: they reject and abort the run, because they mean the run itself is in trouble
rather than one item having failed. Do not assume every failure arrives as a `null`.

### 3. `Boolean` is the wrong filter

```js
verdicts.filter(Boolean)          // also discards a valid false, 0, or ""
verdicts.filter(v => v !== null)  // correct
```

Harmless in this sample, because a verdict is an object. A data-loss bug the moment a schema
returns a bare boolean or a count — which is exactly the schema you would reach for next.

## `pipeline` or `parallel`?

Both fan out. The difference is the **barrier**.

- `ctx.parallel(thunks)` awaits *all* of them. Nothing proceeds until the slowest finishes.
- `ctx.pipeline(items, ...stages)` has no barrier between stages, so each item advances as soon as
  its own prior stage finishes.

This sample uses `pipeline` across lenses, because nothing in verification needs to see the other
lenses' findings — a fast `correctness` finder starts verifying while `security` is still reading.
With a barrier, every finding would wait for the slowest finder for no benefit. If the slowest of
N subagents takes three times the fastest, a barrier wastes the rest of the pool's time.

It then uses `parallel` *inside* a pipeline stage, where a barrier genuinely is correct: the vote
on one finding cannot be tallied until every skeptic on that finding has reported. It is a small
barrier over 2 items, and it never blocks another lens.

**Reach for a barrier only when a stage needs every prior result at once**: deduplicating or
merging across the full set, an early exit based on the total, or a prompt that compares one
result against the others. Needing to map, filter, or flatten is *not* a reason — do that inside a
pipeline stage.

Note that a stage receives `(previous, item, index)`, and for the **first** stage `previous` *is*
the item. That is why stage 1 here takes one parameter and stage 2 takes two.

## What `ctx.step` is doing here

`ctx.step(key, producer)` journals the producer's JSON result so a resumed run replays it instead
of re-running the producer. The sample uses it for exactly one thing — the clock:

```js
const baseline = await ctx.step("baseline-v1", () => ({ startedAt: new Date().toISOString(), target }));
```

Without it, resuming a run would silently re-date it and the report would claim a start time the
run never had. Pinning non-deterministic input is what journaling is *for*; the expensive part —
the subagents — is already journaled by `ctx.agent`'s own memoization.

Two rules the `-v1` suffix exists to serve:

- **The key is the sole identity.** Neither the producer body nor its inputs contribute to it. A
  resume replays the cached value for a matching key *even if the producer has since changed*, so
  version the key whenever its inputs or meaning change.
- **Journaled producers are best-effort at-least-once.** They may run again across crashes or
  concurrent same-key callers, so keep side effects idempotent. Pass `{ volatile: true }` to skip
  the journal and run the producer every time.

## Cost, limits, and why this factory declares none

At the defaults this run issues up to **10 agent calls**: `lenses + (lenses × maxFindings ×
verifiers)` = `2 + (2 × 2 × 2)`. Every call in this sample uses a schema, and a schema call retries
once on a parse or match failure — so a call may spawn twice and **both spawns count**. Budget up
to **20** admissions against `maxTotalSubagents`.

Four limits exist, and they may be declared in `meta.limits` or passed per invocation:

| Limit | Behaviour when reached |
|---|---|
| `maxConcurrentSubagents` | Queues. Backpressure only — it never fails the run |
| `maxTotalSubagents` | Ends the attempt with failure kind `maxTotalSubagents` |
| `timeoutSeconds` | Accumulated **active** execution time across attempts; time *between* attempts is excluded. Soft, because running work takes time to stop |
| `maxAiCredits` | Soft, post-paid ceiling over the whole subagent subtree, descendants included. Fail-closed: an accounting failure stops a budgeted run rather than allowing untracked use |

**This factory deliberately declares none of them.** A ceiling baked into `meta.limits` is a
guess about a workload the author cannot see, and a guess that is too low ends a legitimate run.
So the factory bounds its own fan-out with counters it *can* reason about — `CAPS` and the
`maxFindings`/`verifiers` arguments — and leaves the safety ceiling to the caller:

```json
{ "name": "sample-review", "args": { "target": "src/" }, "limits": { "maxAiCredits": 3 } }
```

Only `ctx.agent` spawns are throttled, by `maxConcurrentSubagents` falling back to
`maxTotalSubagents`. `ctx.parallel` is `Promise.all`, so non-agent work in a thunk runs fully
concurrently regardless.

## Resume

`maxTotalSubagents`, `timeoutSeconds`, and `maxAiCredits` use **reject-and-retry**. A rejected
attempt ends with status `error` and `failure.type: "factory_limit_reached"`, but the run keeps
its ID, arguments, journal, and accounting.

**Resume it; do not restart it.** A resume replays completed work for free, while a fresh run pays
for all of it a second time.

```
run_factory → { "resumeFromRunId": "<id>", "limits": { "maxAiCredits": 6 } }
```

Raise only the limit that was actually reached. Previously consumed resources still count. Lost
the ID? `factories_manage` → `runs` lists the session's runs with their IDs and statuses.

To watch it happen, run the sample with a limit you know is too low — `{"maxTotalSubagents": 3}`
against the defaults — then resume it with a higher one and watch the finders replay instantly.

## The slash command

The extension registers `/review-factory` alongside the factory. `commands` is an ordinary
session-config field — any extension can register slash commands, with or without a factory — but
it is worth having here for two reasons: a factory a human wants to start is better reached with
one keystroke than by asking the agent to call `run_factory`, and it is the only place this sample
uses `session.factory`, the caller-side half of the API opposite `ctx`.

```js
const session = await joinSession({
    factories: [sampleReview],
    commands: [{
        name: "review-factory",
        description: "Run the sample-review factory. Usage: /review-factory [target]",
        handler: async (context) => { /* context.args is the raw string after the name */ },
    }],
});
```

Three things about it are deliberate:

- **The handler closes over `session`.** `CommandContext` carries only `sessionId`, `command`,
  `commandName`, and `args` — there is no session on it, so the closure is the only route to
  `session.factory`. `session` is assigned before the CLI can dispatch a command, so it is always
  initialized by the time the handler runs.
- **The run is not awaited.** `session.factory.run` resolves only at a terminal status, minutes
  later, and a command handler should hand the terminal straight back. The run outlives the
  handler; its outcome is reported through `session.log` when it settles.
- **The `.catch` is not optional.** An un-awaited rejection would be an unhandled promise
  rejection in the extension host. Only *pre-execution* failures reject — an unknown factory, or a
  session that already has a run in flight — because every other outcome, including `error` and
  `cancelled`, resolves with an envelope.

`CommandHandler` returns `void`, so a command cannot return text to the user. Report through
`session.log(message, { level })` instead.

## Observing a run

Factory-owned subagents are **deliberately hidden** from `read_agent` and `write_agent`, and
factory prompts are never exposed. Use the factory APIs instead — from an extension, on
`session.factory`:

```ts
const runs   = await session.factory.listRuns();                 // durable creation order
const detail = await session.factory.getRunDetail(runId);        // phases, agent summaries, tail
const page   = await session.factory.getRunProgress(runId, { afterSeq });
const settled = await session.factory.waitForRun(runId);         // resolves on terminal status
```

`waitForRun` resolves once the run settles into `completed`, `error`, `halted`, or `cancelled`,
and immediately if it already has. Aborting the wait does **not** stop the run — use
`cancel(runId)` for that.

The ephemeral `factory.run_updated` event carries `{ runId, revision }` and is an *invalidation
signal*, not a payload: re-read whichever API you care about when a newer monotonic revision
arrives. Some read-time fields — `observedAt`, live counts, a live agent's activity text — change
without a new revision.

As an agent rather than an extension, use `factories_manage` → `inspect-run` to read a run's
durable result by ID without waiting for it to finish.

## Why this is an extension and not an agent

An Agent Factory has to be **registered from code**, so it ships as a Copilot CLI *extension*
(`extensions/factory-review/extension.mjs`) rather than as an `.agent.md`.

There are two ways to install one, and the choice matters more than it looks. A plugin can
contribute an extension — `plugin.json` here declares `"extensions": ["extensions/"]`, an official
manifest field — and that is the right route for **distributing to a team**, because it is the only
one that also reaches Copilot cloud agent through `enabledPlugins`. But a plugin-contributed
extension is resolved at CLI **startup**, so `/extensions` will not pick it up and you must restart.
Copilot CLI also discovers extensions in `<git root>/.github/extensions/` and in your Copilot home,
which is all the install scripts do — slower to distribute, but it reloads live, so it is the better
**development** loop.

> Note: installing a plugin by path or repository (`copilot plugin install owner/repo:path`) still
> works but is **deprecated** — the CLI warns that only `plugin@marketplace` installs will be
> supported in a future release. Prefer a marketplace entry for anything you intend to share.

There is a third way in, useful for a throwaway: `factories_manage` with `operation: "author"`
writes a factory into a session-scoped extension at runtime. One extra constraint applies there —
**the `run` body is emitted verbatim and closes over nothing.** Every schema, constant, and helper
must be defined *inside* the function, and external modules load with a dynamic `await import()`,
never a static `import` or `require`. That is why this sample is a file: at this size, module
scope is worth having. A session-scoped factory also cannot be shared at all.

## What this sample omits for clarity

| Omitted | Why it is safe to leave out |
|---|---|
| **`ctx.signal`** | Factory subagents already observe cancellation. You need the signal only to abort your *own* long-running extension work or subprocesses. |
| **Loop-until-dry** | A finder pool that keeps going until N consecutive rounds surface nothing new, deduplicating against everything *seen* rather than everything kept. Real, and twice this sample's length. |
| **A synthesis stage** | A final agent that merges confirmed findings into one narrative. Another fan-in; nothing new to teach. |
| **Approval pauses** | The `autodev` plugin pauses for user approval mid-run. It needs an interactive host, which makes it awkward to run as a demo. |
| **A completeness critic** | An agent asked what is *missing* — an angle not run, a claim unverified — whose answer seeds the next round. |

## Adapting it

**Match the orchestration to what was asked.** A quick check wants a couple of subagents and
single-vote verification. "Be thorough" wants a larger finder pool, three-to-five-vote adversarial
verification, and a synthesis stage. There is no in-script budget object — scale with your own
counters and treat declared limits as the safety ceiling, not the control.

**Change the domain, keep the skeleton.** Replace the prompts and the lenses and this becomes a
research harness, a test-gap finder, or a docs auditor. The fan-out/verify/report shape is
domain-agnostic.

**Other quality patterns**, composable with this one:

- **Perspective-diverse verify** — already here: each skeptic gets a distinct angle rather than
  being an identical clone. The distinct prompts also stop them memoizing into one subagent.
- **Judge panel** — generate several independent attempts from different angles, score them with
  parallel judges, then synthesise from the winner while grafting the best ideas from the
  runners-up.
- **Multi-modal sweep** — parallel searchers that each look a different way: by container, by
  content, by entity, by time.
- **No silent caps** — whenever the factory bounds its own coverage with a top-N, a sampling step,
  or a no-retry rule, `log()` what was dropped. This sample logs every drop it makes, including an
  argument it rejected or clamped — `ctx.args` comes from an untyped tool parameter, so a caller
  who passes `"4"` instead of `4` should be told it landed on the default.

**Nested factories are not supported.** `ctx.factory(...)` always rejects. Compose with plain
function calls in the run body instead.

## Reference

The authoritative docs ship with the CLI. Find them with `factories_manage` → `guide`, which
prints the paths to `factories.md` (the API, limits, resume, observability) and
`factory-patterns.md` (composable orchestration patterns). Types are in the SDK's `factory.d.ts`.
