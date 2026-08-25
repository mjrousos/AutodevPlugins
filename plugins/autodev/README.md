# Autodev

One [Agent Factory](https://github.com/github/copilot-cli) that runs the whole loop: it plans a
feature the way `autodev-plan` does, stops and asks whether you are ready, and then implements it
the way `autodev-implement` does — in a single run, with a single audit trail.

```
INTAKE → CLARIFY → DRAFT → APPROVE → GATE:architecture → GATE:security → GATE:privacy
                                                                              ↓
                                                                      ┌── HANDOFF ──┐
                                                                      │  "ready?"   │
                                                                      └──────┬──────┘
                                                                             ↓ yes
   TASKING → [ IMPLEMENT → CODE-REVIEW ⇄ CODE-FIX ] per milestone → CHECKPOINT
                                                                             ↓
                                            SECURITY-REVIEW ⇄ CODE-FIX → PRIVACY-REVIEW ⇄ CODE-FIX
                                                                             ↓
                                                                          WRAPUP
```

The reviewers and workers are the same ones the two plugins use — literally the same instructions,
lifted from their canonical `.agent.md` files. What changes is who is in charge: the phase machine,
the attempt caps, the verdict handling and the escalation paths are **code** here, not a document a
model is asked to follow.

---

## Why a factory rather than a third orchestrator agent

The two existing plugins are built the only way they could be: a markdown orchestrator that drives
the workflow, and a set of hooks that police it — refusing `ask_user` during autonomous phases,
counting attempts, blocking an early stop, recording verdicts the orchestrator might otherwise
misreport. That machinery exists because an agent following a document can wander off it.

A factory cannot wander off. `run()` is JavaScript. The loop that re-invokes a reviewer until it
returns `AUTODEV-VERDICT: PASS` is a `while` loop; the cap is an integer; the refusal to treat a
missing verdict as a pass is an `if`. So the enforcement layer disappears into the orchestration,
and what is left over — the evidence — is still written to `.autodev/`.

Three things follow from that, and they are the honest trade-offs of this design:

| | Plugins | Factory |
| --- | --- | --- |
| Gate enforcement | Hooks watch an agent that is asked to comply | The loop *is* the enforcement |
| Reviewer isolation | A separate agent with `tools: ["read", "search"]` | A separate subagent with the same instructions, but the full tool set |
| Interaction | The orchestrator talks to you throughout | Fixed checkpoints, as interactive forms |
| Resumability | Re-run and re-do the work | Resume the run and replay the journal for free |

The middle row is the one real regression. `ctx.agent()` has no way to restrict a subagent's tools,
so the reviewers are told to stay read-only in their prompt and then **verified**: the plan's hash
is compared before and after every plan gate, and before and after every code review the factory
compares a snapshot of `git status --porcelain`, hashes of the staged and unstaged tracked diffs,
a hash of every untracked file's contents, and hashes of the plan and todo list. The last three
matter — porcelain alone reports only *which* paths are dirty, and a tracked diff ignores
untracked files entirely, so a reviewer that edited a file the implementation stage had just
created would show up in neither.

A reviewer caught writing does not get to approve its own edit: the `PASS` is refused, the attempt
is spent, and the reviewer is re-run. The same applies when the guard could not run at all —
an unverifiable `PASS` is not a `PASS`. Both are recorded as process violations and reported at
wrapup.

### Why the instructions travel in the prompt

`ctx.agent(prompt, options)` takes exactly `label`, `schema` and `model` — there is no
`agent_type`, and a factory subagent's own `task` tool only offers the built-in agents. A factory
therefore *cannot* delegate to `autodev-plan:autodev-architecture-review`, however much it would
like to.

So `scripts/sync-autodev-prompts.sh` lifts each agent's body out of its canonical `.agent.md`,
along with the model its frontmatter declares, into `extensions/autodev/prompts.generated.mjs`.
The factory sends the body as the subagent's instructions and the model as `options.model`. Edit
the source agent, re-run the script; CI fails on drift. There is no second copy of a reviewer to
keep in sync by hand.

---

## Installation

The factory ships as a Copilot CLI **extension**, because an Agent Factory has to be registered
from code. There are two ways to get it, and they trade off differently.

**As a plugin** (`plugin.json` declares `"extensions": ["extensions/"]`, which the CLI honours —
see the [plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference)):

```
/plugin marketplace add mjrousos/AutodevPlugins
/plugin install autodev@autodev-plugins
```

This is the right route for distributing to a team, and the only one that also works for Copilot
cloud agent (via `enabledPlugins` in `.github/copilot/settings.json`). The catch: a
plugin-contributed extension is resolved at CLI **startup**, so `/extensions` will not pick it up —
you must restart the CLI after installing.

**Directly**, which the CLI discovers in `<git root>/.github/extensions/` or your Copilot home
(`~/.copilot/extensions/`). Slower to distribute, but it reloads live with `/extensions`, so it is
the better development loop:

```bash
# For every repository you work in:
plugins/autodev/install.sh

# Or just this repository:
plugins/autodev/install.sh --project
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev\install.ps1 -Scope Project
```

Then run `/extensions` in the CLI (or restart it). `autodev` becomes available to `run_factory`.
To remove it: `install.sh --uninstall` or `install.ps1 -Uninstall`.

You do not need `autodev-plan` or `autodev-implement` installed to use this — the instructions are
baked into the extension.

---

## Running it

Ask for it in the CLI:

> Run the autodev factory to build rate limiting for the public API.

Or invoke it directly with `run_factory`, name `autodev`:

```json
{
  "request": "Add per-tenant rate limiting to the public API.",
  "clarifyRounds": 3
}
```

### Arguments

| Argument | Default | What it does |
| --- | --- | --- |
| `request` | *prompted for* | What to plan and implement. A paragraph is plenty — the clarifying round pulls out the rest. |
| `repoRoot` | working directory | Absolute path to the repository. Resolved against `git rev-parse --show-toplevel`, and the default artifact paths move with it. |
| `planPath` | `<repoRoot>/.autodev/plan.md` | Where the plan is written. Must be inside the repository — these paths reach write-capable subagents, and anything resolving outside falls back to the default. |
| `todosPath` | `<repoRoot>/.autodev/todos.md` | Where the milestone todo list is written. Same rule as `planPath`. |
| `startAt` | `"plan"` | `"implement"` skips planning entirely and works from the plan already on disk. |
| `clarifyRounds` | `3` | How many rounds of clarifying questions to allow, 0–4. |

### Limits

None are declared. Every loop bounds itself — 10 attempts per plan gate, a ceiling of 40 plan
reviewer invocations, 10 rounds per code review, 3 tasking attempts — so the run terminates on its
own. If you want a hard ceiling anyway, pass one per invocation:

```json
{ "name": "autodev", "args": { "request": "…" }, "limits": { "maxAiCredits": 400 } }
```

A run that hits a declared limit stops with `factory_limit_reached` and keeps its journal. Resume it
with a raised limit and the completed work replays for free — restarting from scratch pays for it
twice. The stages that write a file — plan drafting and tasking — journal their own success, so a
resumed run recognizes the artifact already on disk instead of re-drafting over a plan the gates
have since amended.

---

## The three times it stops for you

Everything else is autonomous. Subagents have no `ask_user` tool at all, so an autonomous phase
genuinely cannot interrupt you — the restriction that the plugins enforce with a hook is a property
of the runtime here.

**1. Plan approval.** The plan is drafted and summarized; the gates do not start until you say so.
You can ask for changes first — they go to the plan reviser, and the plan is re-presented — for up
to six rounds, after which you are asked once, plainly, whether to run the gates on the latest
revision or stop. Running out of revision rounds is never treated as approval, and neither is
asking for changes without describing any: that just re-presents the plan.

**2. The handoff.** All three gates have closed. You are told how each one went — including any
that escalated rather than passed — and asked whether to implement. Three answers: implement now,
stop with the plan, or stop so you can edit the plan yourself and re-run with
`{"startAt": "implement"}`.

**3. The code checkpoint.** Every milestone is implemented and reviewed. You review the code. If you
ask for changes they are routed to the fix agent verbatim — your words, not a paraphrase — and the
checkpoint re-locks, because you should see the corrected code before the final security and
privacy reviews run. As at plan approval, this runs for up to six rounds and then asks once whether
to proceed; it never unlocks itself, and an empty change request re-presents the code rather than
counting as sign-off.

Plus escalations. When a gate or a final review exhausts its attempts, you are shown the findings
that keep recurring and offered three options: retry with guidance the reviewer is missing, accept
the risk, or stop. An escalated gate **never becomes a passed gate** — the audit trail keeps saying
so, and wrapup says so too.

If the host has no interactive support, the checkpoints are skipped, the run stops at the handoff
rather than implementing unasked, and every skip is recorded in the notes.

---

## What it writes

Everything lands in `.autodev/` next to the plan. If that directory is not git-ignored you are
asked, once, whether to ignore it — nothing is written to `.gitignore` without your answer.

| File | Contents |
| --- | --- |
| `plan.md` | The plan, as amended by the gates. |
| `todos.md` | The milestone decomposition, maintained by the workers. |
| `factory-audit.md` | One row per subagent invocation: phase, stage, attempt, model, verdict, response size, notes. |
| `factory-feedback.md` | Every subagent response, verbatim. This is where a reviewer's actual findings live. |
| `factory-status.json` | A live mirror of the run's state, rewritten after every stage. |
| `factory-summary.md` | The wrapup: gate outcomes, milestones, unresolved findings, process violations, accounting. |

The names deliberately differ from the plugins' `gate-audit.md` and `feedback-log.md` so a factory
run and a plugin run in the same repository cannot overwrite each other's evidence.

### About hooks

The plugins' `subagentStart`/`subagentStop` hooks **do not fire for factory subagents** — the gate
and stage trackers cannot see this workflow at all, which is why their job moved into the code.

Extension SDK hooks *can* observe factory subagent tool calls, and an earlier revision of this
factory used them to record per-stage tool usage in the audit trail. That was removed. Registering
extension hooks was observed to leave the session's hook processor in a state where every
subsequent `subagentStart` failed — `Hook processor is not configured for session id` — which takes
down subagent spawning for the whole session, this factory's own reviewers included. A column in an
audit table is not worth that. **This extension registers no hooks.**

What replaces them is not a weaker check but a stronger one. A hook can only watch an agent decide
whether to comply; the loop here simply does not exit until a reviewer's response ends in
`AUTODEV-VERDICT: PASS`, and the artifact guards catch a reviewer that wrote when it should not
have.

---

## Maintenance

The prompt bundle is generated. Never edit `extensions/autodev/prompts.generated.mjs` by hand:

```bash
scripts/sync-autodev-prompts.sh          # regenerate after editing any source agent
scripts/sync-autodev-prompts.sh --check  # what CI runs
```

It reads nine agents — the three plan reviewers from `autodev-plan`, and tasking, implementation,
code review, code fix, code security review and code privacy review from `autodev-implement` — plus
the plan document template from the `autodev-plan` orchestrator. The two orchestrator agents are
deliberately not in the bundle: orchestration is the part the factory replaces.

Three prompts are authored in `extension.mjs` rather than lifted, because they cover work the
plugin orchestrators did in their own context and no agent exists for them: the requirements
analyst that generates the clarifying questions, the plan author, and the plan reviser. The reviser
in particular has no candidate to lift: `autodev-code-fix` is the closest thing either plugin has,
and its own scope rules forbid it to touch `.autodev/plan.md`.

### Tests

```bash
node --import ./plugins/autodev/tests/register-stub.mjs --test plugins/autodev/tests/factory.tests.mjs
```

The orchestration cannot be unit tested without a live CLI session, so what is covered is
everything that decides *what* the orchestration does: verdict parsing, the todo list's
machine-readable contract, elicitation form construction from model-supplied JSON, path
resolution, and audit-table escaping.

`@github/copilot-sdk` is injected by the CLI into the extension host and cannot be installed, so
`tests/register-stub.mjs` resolves it to a local stub. `extension.mjs` skips `joinSession` when
`AUTODEV_FACTORY_TEST=1`, which the suite sets before importing it.

---

## Known limitations

- **Reviewers are not tool-restricted.** Mitigated by prompt, verified by hashing, and enforced by
  refusing a `PASS` from a reviewer that wrote; see the trade-off table above.
- **Path containment is lexical.** `planPath` and `todosPath` are kept inside the repository by
  comparing resolved paths, which does not follow symlinks or Windows junctions. A link *inside*
  the repository pointing outside it would not be caught.
- **Unresolved code-review findings are recorded, not merged into `todos.md`.** The plugin
  orchestrator writes them into the milestone's *Review notes*; the factory records them in
  `factory-feedback.md`, the run result and the wrapup summary instead of editing a file a worker
  owns.
- **Re-gating is not automatic.** The plugins re-run earlier gates when a plan changes materially
  after passing. Here the gates run once, in order, after your approval. If you change the plan at
  the handoff, re-run the factory.
- **The factory is session-scoped.** Extensions reload on `/clear`, and a run belongs to the session
  that started it.
