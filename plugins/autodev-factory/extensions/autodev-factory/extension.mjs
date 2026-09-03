/**
 * autodev — one Agent Factory that runs the whole software-development loop.
 *
 * It replaces the two orchestrator agents (`autodev-plan` and `autodev-implement`) with code:
 * the phase machine, the attempt caps, the verdict handling and the escalation paths all live
 * here rather than in a markdown document that a model is asked to obey. The reviewers and
 * workers are unchanged — their instructions are lifted verbatim from the canonical
 * `.agent.md` files by `scripts/sync-autodev-prompts.sh` into `prompts.generated.mjs`.
 *
 * Why the instructions travel in the prompt: `ctx.agent(prompt, options)` accepts only `label`,
 * `schema` and `model`. There is no `agent_type`, and a factory subagent's own `task` tool sees
 * only the built-in agents, so a factory simply cannot delegate to a plugin agent. Carrying the
 * body in the prompt and the frontmatter model in `options.model` is the closest faithful
 * equivalent, and it keeps one source of truth for what a reviewer actually says.
 *
 * What the hooks in the plugin workflows did, this does directly. Plugin `subagentStart` and
 * `subagentStop` hooks never fire for factory subagents, so the gate tracker could not police
 * this workflow even if it were installed. It does not need to: a loop that only exits on a
 * parsed `AUTODEV-VERDICT: PASS` is a stronger guarantee than a hook that watches an agent
 * choosing to obey a document. The audit trail the tracker used to write is still written, under
 * `.autodev/`, so the run remains inspectable after the fact.
 */

import { joinSession, defineFactory } from "@github/copilot-sdk/extension";
import { PROMPTS, PLAN_TEMPLATE, GENERATED_FROM } from "./prompts.generated.mjs";
import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, isAbsolute, relative as relativePath, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/**
 * Every loop in this workflow is bounded. These are the same ceilings the plugin orchestrators
 * documented, so a run here terminates in the same places a plugin run would have.
 */
const CAPS = Object.freeze({
    clarifyRounds: 4,
    planApprovalRounds: 6,
    planGateAttempts: 10,
    planReviewerCalls: 40,
    taskingAttempts: 3,
    implementationAttempts: 3,
    codeReviewRounds: 10,
    finalReviewRounds: 10,
    userReviewRounds: 6,
    escalationsPerStage: 2,
    milestones: 24,
});

const PHASES = Object.freeze([
    { title: "Intake", detail: "Resolve paths and orient in the repository" },
    { title: "Clarify", detail: "Requirements conversation with the user" },
    { title: "Draft plan", detail: "Write the implementation plan" },
    { title: "Plan approval", detail: "User reviews the plan before the gates run" },
    { title: "Architecture gate", detail: "Isolated architecture review of the plan" },
    { title: "Security gate", detail: "Isolated security review of the plan" },
    { title: "Privacy gate", detail: "Isolated privacy review of the plan" },
    { title: "Implementation handoff", detail: "Ask whether to start implementing" },
    { title: "Tasking", detail: "Decompose the plan into milestones" },
    { title: "Milestones", detail: "Implement and review each milestone" },
    { title: "Code checkpoint", detail: "User reviews the implementation" },
    { title: "Code security review", detail: "Whole-implementation security review" },
    { title: "Code privacy review", detail: "Whole-implementation privacy review" },
    { title: "Wrapup", detail: "Report what was built and what the reviews changed" },
]);

const PLAN_GATES = Object.freeze([
    { key: "architecture", title: "Architecture", prompt: "autodev-architecture-review" },
    { key: "security", title: "Security", prompt: "autodev-security-review" },
    { key: "privacy", title: "Privacy", prompt: "autodev-privacy-review" },
]);

/* -------------------------------------------------------------------------------------------
 * Structured-output schemas.
 *
 * Only `type`, `required`, `enum`, `const`, recursive `properties`/`items` and the `anyOf`
 * family are enforced by the runtime. Nothing here relies on a keyword outside that subset.
 * ------------------------------------------------------------------------------------------- */

const ORIENTATION_SCHEMA = {
    type: "object",
    properties: {
        projectContext: { type: "string" },
        buildCommand: { type: "string" },
        testCommand: { type: "string" },
        conventions: { type: "string" },
    },
    required: ["projectContext", "buildCommand", "testCommand"],
};

const QUESTIONS_SCHEMA = {
    type: "object",
    properties: {
        done: { type: "boolean" },
        rationale: { type: "string" },
        questions: {
            type: "array",
            items: {
                type: "object",
                properties: {
                    key: { type: "string" },
                    title: { type: "string" },
                    description: { type: "string" },
                    kind: { type: "string", enum: ["choice", "text", "boolean"] },
                    options: { type: "array", items: { type: "string" } },
                    recommended: { type: "string" },
                },
                required: ["key", "title", "kind"],
            },
        },
    },
    required: ["done", "questions"],
};

/* -------------------------------------------------------------------------------------------
 * Prompts authored here rather than lifted from an agent.
 *
 * These three cover work the plugin orchestrators did in their own context — conducting the
 * requirements conversation, writing the plan, and revising it in response to a gate. The
 * factory delegates all three to subagents, so they need instructions of their own. The plan
 * structure itself is not duplicated: PLAN_TEMPLATE is extracted from the canonical
 * `autodev-plan` agent by the sync script.
 * ------------------------------------------------------------------------------------------- */

const CLARIFIER_INSTRUCTIONS = `# Requirements Analyst

You are the clarifying stage of the \`autodev\` workflow. You do not talk to the user directly —
you produce the questions that will be put to them as a form, and the orchestrator returns their
answers to you on the next round.

## Absolute rules

1. **Never ask what you can determine yourself.** Read the repository first. Asking which test
   framework a project uses when it is visible in the tree wastes the user's time and costs you
   their trust.
2. **Ask about decisions, not preferences.** Focus on things that change the shape of the
   implementation: scope boundaries, data, integrations, compatibility, failure behavior,
   permissions, rollout.
3. **Prefer concrete options over open questions.** Where you can enumerate the realistic
   choices, emit a \`choice\` question with those options and name the one you recommend.
4. **Batch.** Emit up to five questions per round. Fewer is better when fewer will do.
5. **Stop when you have enough.** Set \`done: true\` when you could hand the request to an
   engineer who has never spoken to the user and they would not have to come back with
   questions. Two or three rounds is usually right; if you are on round four you are asking
   about things you should decide yourself and record as an assumption.
6. **Never edit anything.** You read the repository and return JSON. Nothing else.

## Output

Return JSON matching the requested schema.

- \`done\` — true when no further questions are needed. When true, \`questions\` must be empty.
- \`questions[].key\` — a short lowercase identifier, unique within the round (\`storage_backend\`).
- \`questions[].title\` — the question as the user will read it, one line.
- \`questions[].description\` — why it matters and what each choice implies. Keep it to a sentence
  or two.
- \`questions[].kind\` — \`choice\` when you can enumerate the options, \`boolean\` for a yes/no,
  \`text\` when the answer is genuinely open-ended.
- \`questions[].options\` — required for \`choice\`, two to six entries, each a short readable label.
- \`questions[].recommended\` — for a \`choice\`, the option you would pick; the form pre-selects it.`;

const PLANNER_INSTRUCTIONS = `# Plan Author

You are the drafting stage of the \`autodev\` workflow. You turn a feature request, the answers
the user gave to the clarifying questions, and the reality of the repository into an
implementation plan that three independent reviewers will then try to tear apart.

## Absolute rules

1. **You write exactly one file:** the plan, at the path given in your prompt. Do not create,
   modify, or delete anything else. You are not implementing the feature.
2. **You never fabricate.** If something material is unknown, write it down under *Assumptions*
   as an explicit, falsifiable assumption. A plan that quietly invents a constraint is worse than
   one that admits an open question.
3. **You ground the plan in the code that actually exists.** Read the repository: module layout,
   existing abstractions, build and test setup, naming and testing conventions. A plan that
   proposes a parallel way of doing something the codebase already does will not survive the
   architecture gate.
4. **You honor the user's answers.** The clarifying answers in your prompt are decisions, not
   suggestions. Where an answer conflicts with what you would have chosen, follow the answer and
   note the tension under *Risks and open questions*.
5. **You never ask questions.** There is no human available to you.

## Depth

Adapt depth to the size of the change. A small feature does not need a long document, and padding
a thin plan makes it worse rather than better. Every section should carry weight; a section with
nothing to say gets one honest line, not three paragraphs of filler.

The *Approach* section is what makes the plan reviewable rather than merely readable: state the
alternatives you considered and why you rejected them.

## Plan structure

Write the plan as Markdown in exactly this structure:

${PLAN_TEMPLATE}

Leave *Review notes* as "None yet." — the review gates maintain it.

## Output

Write the file, then reply with a short summary for the user: two or three sentences on the
approach, the number of implementation steps, and anything you had to assume. Do not paste the
plan back — the user has the path.`;

const PLAN_REVISER_INSTRUCTIONS = `# Plan Reviser

You are the revision stage of the \`autodev\` workflow. A review gate has returned findings
against the plan and you apply them.

## Absolute rules

1. **You edit exactly one file:** the plan, at the path given in your prompt. You do not touch
   product code, and you do not implement anything.
2. **You fix every \`blocker\` and every \`major\`.** These are what forced the \`ISSUES\` verdict, and
   the gate will not pass until they are genuinely resolved — not restated more vaguely, not
   deferred to "a follow-up".
3. **You apply \`minor\` and \`nit\` findings when they are cheap and clearly right.** You are
   already editing the file; leaving an easy improvement behind only guarantees another round.
4. **You never silently ignore a finding.** If you genuinely disagree with one, record the
   disagreement and your reasoning under *Review notes* in the plan. The reviewer sees that
   section on the re-review and may accept the argument. An unrecorded disagreement just reads
   as a finding you failed to address.
5. **You never ask questions.** Where a finding admits several resolutions, choose the one that
   best fits the codebase, apply it, and record the choice under *Assumptions* or *Review notes*.
6. **You write the fixes into the file.** The reviewer re-reads the plan from disk on the next
   attempt, so an unwritten fix does not count.

## Output

Reply with a list of the findings and what you did about each one — resolved and how, or
disputed and why. This list is passed verbatim to the reviewer as the record of what changed, so
be specific: "added a \`## Rollback\` subsection to *Implementation steps* describing the feature
flag" tells the reviewer where to look; "addressed the rollback concern" does not.`;

/**
 * Factory subagents get the full tool set, including `create`, `edit` and a shell. The plugin
 * versions of the reviewers are declared `tools: ["read", "search"]` and cannot write at all.
 * That restriction has no equivalent on `ctx.agent`, so it is restated in the prompt and then
 * verified afterwards against the artifacts.
 */
const REVIEWER_ENVIRONMENT_NOTE = `## Environment note

You are running as a factory subagent, so the host has handed you write-capable tools — \`create\`,
\`edit\`, and a shell — that the agent version of you would not have had. Your instructions above
make you a reviewer, and they still govern: do not create, edit, or delete any file, and do not
run any command that changes the repository or the working tree. Report findings; the orchestrator
applies the fixes.

The orchestrator records the state of the artifacts before and after you run. A review that
modified them is reported as a process violation in the audit trail, and its findings are treated
as suspect.`;

/* -------------------------------------------------------------------------------------------
 * Small utilities.
 * ------------------------------------------------------------------------------------------- */

const VERDICT_PATTERN = /^[ \t]*AUTODEV-VERDICT:[ \t]*([A-Za-z][A-Za-z-]*)[ \t]*$/gm;

/**
 * Reads the trailing verdict line. Every agent's output format ends with "The verdict must be the
 * final line of your response", and this holds them to exactly that: the last match wins, and it
 * only counts when nothing but whitespace follows it.
 *
 * Both halves matter. Taking the last match stops a quoted example — the reviewers routinely
 * restate their output format before answering — from deciding a gate. Requiring it to be last
 * stops the mirror image, which is the dangerous one: a reviewer that quotes `PASS` while
 * restating the format, then reports blockers and forgets its own verdict line, must not be read
 * as having passed. An unreadable verdict costs one wasted attempt; a false PASS opens a gate.
 */
function readVerdict(text) {
    if (typeof text !== "string" || text.length === 0) return null;
    const pattern = new RegExp(VERDICT_PATTERN.source, "gm");
    let last = null;
    let end = -1;
    for (const match of text.matchAll(pattern)) {
        last = match[1];
        end = match.index + match[0].length;
    }
    if (last === null || text.slice(end).trim().length > 0) return null;
    return last.toUpperCase();
}

function asText(value) {
    if (typeof value === "string") return value;
    if (value === null || value === undefined) return "";
    return JSON.stringify(value);
}

function truncate(text, limit) {
    const value = asText(text);
    return value.length <= limit ? value : `${value.slice(0, limit)}\n…[truncated ${value.length - limit} characters]`;
}

function timestamp() {
    return new Date().toISOString();
}

/**
 * `ctx.phase` sets a single run-global value and does not report it back, so the status mirror
 * would otherwise be stuck on whatever phase the run started in.
 */
function setPhase(ctx, run, title) {
    run.phase = title;
    ctx.phase(title);
}

async function git(repoRoot, args) {
    try {
        const { stdout } = await execFileAsync("git", args, { cwd: repoRoot, windowsHide: true, maxBuffer: 16 * 1024 * 1024 });
        return { ok: true, stdout: stdout.replace(/\r/g, "").trim() };
    } catch (error) {
        return { ok: false, stdout: "", error: error?.message ? String(error.message) : String(error) };
    }
}

/**
 * `git` for output that must survive verbatim. The helper above trims and strips carriage
 * returns, which is right for human-readable output and wrong for NUL-delimited path lists — a
 * filename may legitimately contain a CR.
 */
async function gitRaw(repoRoot, args) {
    try {
        const { stdout } = await execFileAsync("git", args, {
            cwd: repoRoot,
            windowsHide: true,
            maxBuffer: 16 * 1024 * 1024,
        });
        return { ok: true, stdout };
    } catch (error) {
        return { ok: false, stdout: "", error: error?.message ? String(error.message) : String(error) };
    }
}

async function fileExists(path) {
    try {
        const info = await stat(path);
        return info.isFile() && info.size > 0;
    } catch {
        return false;
    }
}

async function hashFile(path) {
    try {
        return createHash("sha256").update(await readFile(path)).digest("hex");
    } catch {
        return null;
    }
}

/**
 * A porcelain snapshot of the working tree. Used to describe what a milestone changed.
 */
async function worktreeSnapshot(repoRoot) {
    const result = await git(repoRoot, ["status", "--porcelain"]);
    return result.ok ? result.stdout : null;
}

/**
 * The read-only guard for a code reviewer, and a strictly stronger thing than a porcelain
 * snapshot. Porcelain reports only *which* paths are dirty, so a reviewer that edits a file the
 * implementation stage had already modified leaves the output byte-identical — precisely the
 * files a reviewer is most likely to "helpfully" fix. Hashing the tracked diff closes that hole,
 * and the workflow artifacts are hashed by name because `.autodev/` is normally git-ignored and
 * so appears in neither.
 *
 * Kept separate from `worktreeSnapshot` because `describeChanges` parses porcelain lines and
 * would report these digests as changed files.
 *
 * Returns null only when git itself is unavailable, which `callReviewer` reports as an
 * unverifiable guard rather than as a clean result.
 */
async function codeSnapshot(repoRoot, artifactPaths = []) {
    const status = await git(repoRoot, ["status", "--porcelain"]);
    if (!status.ok) return null;

    // Tracked content, staged and unstaged. Deliberately *not* `git diff HEAD`, which is the
    // obvious spelling and fails outright with "ambiguous argument 'HEAD'" in a repository that
    // has no commits yet — a state this factory can perfectly well be run in, and one where the
    // guard failing closed would escalate every single review.
    const unstaged = await git(repoRoot, ["diff"]);
    if (!unstaged.ok) return null;
    const staged = await git(repoRoot, ["diff", "--cached"]);
    if (!staged.ok) return null;

    // Untracked content. Porcelain names an untracked path without saying anything about what is
    // in it, and may not even name it individually — git collapses a wholly untracked directory
    // to a single entry. Implementation milestones create new files constantly, so without this a
    // reviewer could rewrite the very code it was asked to review and leave the snapshot
    // identical. `-z` because `git ls-files` C-quotes any path that is not plain ASCII, and a
    // quoted name is not a path that can be opened.
    const untracked = await gitRaw(repoRoot, ["ls-files", "--others", "--exclude-standard", "-z"]);
    if (!untracked.ok) return null;

    const parts = [
        status.stdout,
        createHash("sha256").update(unstaged.stdout).digest("hex"),
        createHash("sha256").update(staged.stdout).digest("hex"),
    ];
    for (const relative of untracked.stdout.split("\0").filter(Boolean).sort()) {
        parts.push(`${relative}:${await fileSnapshot(resolve(repoRoot, relative))}`);
    }
    for (const path of artifactPaths) parts.push(`${path}:${await fileSnapshot(path)}`);
    return parts.join("\n");
}

/**
 * A file's identity for guard purposes. Never null: a reviewer that deletes the plan must read as
 * a change, and comparing null to null would have read as "untouched".
 */
async function fileSnapshot(path) {
    return (await hashFile(path)) ?? "absent";
}

function resolveUnder(repoRoot, candidate, fallback) {
    const value = typeof candidate === "string" && candidate.trim() ? candidate.trim() : fallback;
    // Every artifact path is model-supplied and is handed to write-capable subagents, so all of
    // them are kept inside the repository the user named. An absolute path is accepted when it
    // points inside that repository and otherwise falls back to the default: the factory has no
    // way to tell "the user asked for the plan over there" from an argument a model invented, and
    // the cost of guessing wrong is an overwritten file somewhere the user never mentioned.
    const resolved = isAbsolute(value) ? resolve(value) : resolve(repoRoot, value);
    const relative = relativePath(repoRoot, resolved);
    if (relative === "" || relative.startsWith("..") || isAbsolute(relative)) {
        return resolve(repoRoot, fallback);
    }
    return resolved;
}

/**
 * Where the run's artifacts live. Recomputed once the git root is known, because `run()` can only
 * resolve them against the working directory and that may be a subdirectory of the repository.
 */
function artifactPaths(repoRoot, pathArgs = {}) {
    return {
        planPath: resolveUnder(repoRoot, pathArgs.planPath, ".autodev/plan.md"),
        todosPath: resolveUnder(repoRoot, pathArgs.todosPath, ".autodev/todos.md"),
        auditPath: resolveUnder(repoRoot, null, ".autodev/factory-audit.md"),
        feedbackPath: resolveUnder(repoRoot, null, ".autodev/factory-feedback.md"),
        statusPath: resolveUnder(repoRoot, null, ".autodev/factory-status.json"),
        summaryPath: resolveUnder(repoRoot, null, ".autodev/factory-summary.md"),
    };
}

function parseMilestones(text) {
    const heading = /^##[ \t]+Milestone[ \t]+(\d+)\b[ \t]*[—–-]?[ \t]*(.*)$/;
    // `autodev-tasking` is explicit that this line is part of the machine-readable contract:
    // "Every milestone has a `**Status:**` line immediately under its heading, whose value is one
    // of `not-started`, `in-progress`, or `complete`." The stage tracker in `autodev-implement`
    // reads it, so a milestone without a usable one is a milestone nothing can report on.
    const status = /^[ \t]*\*\*Status:\*\*[ \t]*([A-Za-z][A-Za-z-]*)?[ \t]*$/;
    const found = [];
    let awaitingStatus = false;
    for (const line of asText(text).split(/\r?\n/)) {
        const match = heading.exec(line);
        if (match) {
            found.push({ number: Number(match[1]), title: match[2].trim(), status: null });
            awaitingStatus = true;
            continue;
        }
        if (!awaitingStatus) continue;
        if (line.trim() === "") continue;
        // The first non-blank line after the heading is the only place the status may appear.
        // Anything else means the milestone opened with something other than its status line.
        const statusMatch = status.exec(line);
        if (statusMatch) found[found.length - 1].status = (statusMatch[1] ?? "").toLowerCase();
        awaitingStatus = false;
    }
    return found;
}

const MILESTONE_STATUSES = Object.freeze(["not-started", "in-progress", "complete"]);

/**
 * The stage tracker in `autodev-implement` walks the todo list by these headings, and
 * `autodev-tasking` is told the format is a machine-readable contract. The factory checks the
 * same contract so a malformed list is caught while tasking can still be re-run.
 */
function milestonesAreWellFormed(milestones) {
    if (milestones.length === 0) return "no `## Milestone <n>` headings were found";
    for (let index = 0; index < milestones.length; index += 1) {
        if (milestones[index].number !== index + 1) {
            return `milestone headings are not numbered consecutively from 1 (saw ${milestones
                .map((m) => m.number)
                .join(", ")})`;
        }
    }
    if (milestones.length > CAPS.milestones) {
        return `${milestones.length} milestones exceeds the supported maximum of ${CAPS.milestones}`;
    }
    const statusless = milestones
        .filter((milestone) => !MILESTONE_STATUSES.includes(milestone.status))
        .map((m) => m.number);
    if (statusless.length > 0) {
        return `milestone ${statusless.join(", ")} has no \`**Status:**\` line immediately under the heading with one of ${MILESTONE_STATUSES.join(", ")} as its value`;
    }
    return null;
}

/* -------------------------------------------------------------------------------------------
 * A note on hooks.
 *
 * The plugin workflows lean on command hooks — `subagentStart`, `subagentStop`, `preToolUse` —
 * to police an orchestrator that might not follow its own document. None of that machinery is
 * reachable from here: plugin command hooks do not fire for factory subagents at all, so the
 * gate and stage trackers cannot see this workflow even when their plugins are installed.
 *
 * Extension SDK hooks *can* observe factory subagent tool calls, and an earlier revision of this
 * file registered `onPreToolUse` to record them in the audit trail. That was removed. Registering
 * extension hooks was observed to leave the session's hook processor in a state where every
 * subsequent `subagentStart` failed with "Hook processor is not configured for session id",
 * which takes down subagent spawning for the whole session — including this factory's own
 * subagents. A column in an audit table is not worth that risk.
 *
 * What replaces it is stronger anyway. The loop that only exits on a parsed
 * `AUTODEV-VERDICT: PASS` is the enforcement; the artifact guards below are the evidence.
 * ------------------------------------------------------------------------------------------- */

/* -------------------------------------------------------------------------------------------
 * The audit trail.
 *
 * `.autodev/factory-audit.md` — one row per subagent invocation.
 * `.autodev/factory-feedback.md` — every reviewer response, verbatim.
 * `.autodev/factory-status.json` — a live mirror of the run's state.
 *
 * The names differ from the plugins' `gate-audit.md` and `feedback-log.md` on purpose, so a
 * factory run and a plugin run in the same repository do not overwrite each other's evidence.
 * ------------------------------------------------------------------------------------------- */

async function initTrail(run) {
    await mkdir(dirname(run.auditPath), { recursive: true });
    const header = [
        `# autodev factory audit`,
        ``,
        `Run: \`${run.runId}\``,
        `Started: ${run.startedAt}`,
        `Plan: \`${run.planPath}\``,
        `Todos: \`${run.todosPath}\``,
        ``,
        `| Time | Phase | Stage | Attempt | Model | Verdict | Chars | Notes |`,
        `| --- | --- | --- | --- | --- | --- | --- | --- |`,
        ``,
    ].join("\n");

    // A resumed run re-executes this code with the same run id, and its journaled subagent calls
    // replay into the trail. Appending rather than truncating keeps the first attempt's evidence
    // — including whatever it was that made the run stop — instead of quietly erasing it.
    const resuming = await fileExists(run.auditPath);
    if (resuming) {
        await appendFile(run.auditPath, `\n\n${header}`, "utf8");
        await appendFile(run.feedbackPath, `\n\n---\n\n# Resumed ${run.startedAt}\n`, "utf8").catch(() => {});
        run.notes.push("This run was resumed; the audit trail contains more than one attempt.");
        return;
    }

    await writeFile(run.auditPath, header, "utf8");
    await writeFile(
        run.feedbackPath,
        `# autodev factory feedback log\n\nRun: \`${run.runId}\`\nStarted: ${run.startedAt}\n\nEvery subagent response, verbatim.\n`,
        "utf8",
    );
}

function escapeCell(value) {
    return asText(value).replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
}

async function recordAttempt(run, entry) {
    run.attempts.push(entry);
    const row = `| ${entry.time} | ${escapeCell(entry.phase)} | ${escapeCell(entry.stage)} | ${
        entry.attempt ?? ""
    } | ${escapeCell(entry.model ?? "default")} | ${escapeCell(entry.verdict ?? "—")} | ${
        entry.chars ?? 0
    } | ${escapeCell(entry.notes ?? "")} |\n`;
    await appendFile(run.auditPath, row, "utf8").catch(() => {});
    if (entry.response) {
        const block = [
            ``,
            `---`,
            ``,
            `## ${entry.stage}${entry.attempt ? ` — attempt ${entry.attempt}` : ""} — ${entry.verdict ?? "no verdict"}`,
            ``,
            `*${entry.time} · model ${entry.model ?? "default"} · label \`${entry.label}\`*`,
            ``,
            entry.response,
            ``,
        ].join("\n");
        await appendFile(run.feedbackPath, block, "utf8").catch(() => {});
    }
    await writeStatus(run);
}

async function writeStatus(run) {
    const status = {
        runId: run.runId,
        startedAt: run.startedAt,
        updatedAt: timestamp(),
        phase: run.phase,
        planPath: run.planPath,
        todosPath: run.todosPath,
        subagentCalls: run.subagentCalls,
        planReviewerCalls: run.planReviewerCalls,
        gates: run.gates,
        milestones: run.milestones,
        violations: run.violations,
        notes: run.notes,
    };
    await writeFile(run.statusPath, `${JSON.stringify(status, null, 2)}\n`, "utf8").catch(() => {});
}

/* -------------------------------------------------------------------------------------------
 * Subagent invocation.
 * ------------------------------------------------------------------------------------------- */

/**
 * One subagent call, with the two guards every factory call needs: a null result is an ordinary
 * failure rather than an exception, and a declared model may simply not exist on this host.
 */
async function callAgent(ctx, run, { label, prompt, model, schema, maxInvocations = 2 }) {
    const options = { label };
    if (model) options.model = model;
    if (schema) options.schema = schema;

    let result = await ctx.agent(prompt, options);
    let usedModel = model;
    // Counted per actual `ctx.agent` call, not per logical stage. The fallback below is a second
    // real subagent, and counting the pair as one would let the advertised ceilings — and the
    // accounting the wrapup reports — understate what the run actually spent.
    let invocations = 1;

    if (result === null && model && maxInvocations > 1) {
        // A model named in an agent's frontmatter may not be enabled for this host. Retrying on
        // the default is better than failing the stage over a model id. The label differs, so
        // this is a genuinely new subagent rather than a memoized replay of the failed one.
        ctx.log(`${label}: no result on ${model}; retrying on the host default model`);
        const retryOptions = { label: `${label}:default-model` };
        if (schema) retryOptions.schema = schema;
        result = await ctx.agent(prompt, retryOptions);
        invocations += 1;
        usedModel = result === null ? model : "default";
    }

    run.subagentCalls += invocations;
    return { result, model: usedModel, invocations };
}

/**
 * A reviewer call: instructions from the canonical agent, the read-only restatement, then the
 * task. Returns a parsed verdict and the artifact-integrity check.
 */
async function callReviewer(ctx, run, { promptKey, label, phase, stage, attempt, task, guard, maxInvocations }) {
    const agent = PROMPTS[promptKey];
    if (!agent) throw new Error(`prompt bundle is missing '${promptKey}'; re-run scripts/sync-autodev-prompts.sh`);

    const before = guard ? await guard() : null;
    const prompt = [
        `You are operating as \`${agent.name}\`. Your complete operating instructions follow. Follow them exactly.`,
        ``,
        `---`,
        ``,
        agent.body,
        ``,
        `---`,
        ``,
        REVIEWER_ENVIRONMENT_NOTE,
        ``,
        `---`,
        ``,
        `# Your task`,
        ``,
        task,
    ].join("\n");

    const { result, model, invocations } = await callAgent(ctx, run, {
        label,
        prompt,
        model: agent.model,
        maxInvocations,
    });
    const response = asText(result);
    const verdict = readVerdict(response);
    const after = guard ? await guard() : null;

    const notes = [];
    if (result === null) notes.push("subagent returned nothing");
    else if (!verdict) notes.push("no parseable verdict — counted as ISSUES");
    let violated = false;
    let unverified = false;
    if (guard && (before === null || after === null)) {
        // git was unavailable, so the reviewer's read-only claim could not be checked at all.
        // Now that the snapshot no longer needs a HEAD, this means git itself is broken — and an
        // unverifiable PASS is not a PASS, for the same reason a violated one is not.
        unverified = true;
        notes.push("read-only guard unavailable — the reviewer's restraint could not be verified");
        run.violations.push({ stage, attempt, label, kind: "guard-unavailable", time: timestamp() });
    } else if (before !== after) {
        violated = true;
        notes.push("reviewer modified the artifacts it was reviewing");
        run.violations.push({ stage, attempt, label, kind: "reviewer-write", time: timestamp() });
    }

    await recordAttempt(run, {
        time: timestamp(),
        phase,
        stage,
        attempt,
        label,
        model,
        verdict: verdict ?? (result === null ? "NO RESPONSE" : "UNPARSEABLE"),
        chars: response.length,
        notes: notes.join("; "),
        response: response || null,
    });

    return {
        response,
        verdict,
        empty: result === null || response.trim().length === 0,
        violated,
        unverified,
        invocations,
    };
}

/**
 * A worker call — tasking, implementation, fixes. Same verdict contract, no read-only guard,
 * because these agents are supposed to change things.
 */
async function callWorker(ctx, run, { promptKey, label, phase, stage, attempt, task }) {
    const agent = PROMPTS[promptKey];
    if (!agent) throw new Error(`prompt bundle is missing '${promptKey}'; re-run scripts/sync-autodev-prompts.sh`);

    const prompt = [
        `You are operating as \`${agent.name}\`. Your complete operating instructions follow. Follow them exactly.`,
        ``,
        `---`,
        ``,
        agent.body,
        ``,
        `---`,
        ``,
        `# Your task`,
        ``,
        task,
    ].join("\n");

    const { result, model } = await callAgent(ctx, run, { label, prompt, model: agent.model });
    const response = asText(result);
    const verdict = readVerdict(response);

    await recordAttempt(run, {
        time: timestamp(),
        phase,
        stage,
        attempt,
        label,
        model,
        verdict: verdict ?? (result === null ? "NO RESPONSE" : "UNPARSEABLE"),
        chars: response.length,
        notes: result === null ? "subagent returned nothing" : "",
        response: response || null,
    });

    return { response, verdict, empty: result === null || response.trim().length === 0 };
}

/**
 * The plan reviser. Its instructions are authored here rather than lifted from an agent, because
 * neither plugin has an agent that edits a plan: `autodev-code-fix` is the closest fit and its own
 * scope rules say "Do not edit `.autodev/plan.md`", so handing it this job would ask it to
 * violate the instructions it was just given. It also has no verdict to give — the reviewer
 * re-reads the plan from disk on its next attempt, so what comes back is a change log, not a
 * judgment.
 */
async function callPlanReviser(ctx, run, { label, phase, stage, attempt, task }) {
    const { result, model } = await callAgent(ctx, run, {
        label,
        model: "claude-opus-5",
        prompt: [PLAN_REVISER_INSTRUCTIONS, ``, `---`, ``, `# Your task`, ``, task].join("\n"),
    });
    const response = asText(result);

    await recordAttempt(run, {
        time: timestamp(),
        phase,
        stage,
        attempt,
        label,
        model,
        verdict: result === null ? "NO RESPONSE" : "REVISED",
        chars: response.length,
        notes: result === null ? "subagent returned nothing" : "",
        response: response || null,
    });

    return { response, empty: result === null || response.trim().length === 0 };
}

/* -------------------------------------------------------------------------------------------
 * Talking to the user.
 *
 * Every prompt goes through `ctx.step`, so a resumed run replays the answer from the journal
 * instead of asking again. Keys are versioned; change the suffix if the meaning of a question
 * changes.
 * ------------------------------------------------------------------------------------------- */

function elicitationUnavailable(session) {
    return session?.capabilities?.ui?.elicitation !== true;
}

async function ask(ctx, key, params) {
    return ctx.step(key, async () => {
        if (elicitationUnavailable(ctx.session)) {
            return { action: "decline", content: {}, unavailable: true };
        }
        try {
            const result = await ctx.session.ui.elicitation(params);
            return { action: result?.action ?? "cancel", content: result?.content ?? {} };
        } catch (error) {
            ctx.log(`could not reach the user: ${error?.message ?? error}`);
            return { action: "cancel", content: {}, error: String(error?.message ?? error) };
        }
    });
}

function choiceField(title, description, options, recommended) {
    const field = { type: "string", title, description, enum: options };
    if (recommended && options.includes(recommended)) field.default = recommended;
    return field;
}

function sanitizeKey(value, index) {
    const cleaned = asText(value).toLowerCase().replace(/[^a-z0-9_]+/g, "_").replace(/^_+|_+$/g, "");
    return cleaned || `question_${index + 1}`;
}

function questionsToSchema(questions) {
    const properties = {};
    const titles = new Map();
    let count = 0;
    for (const [index, question] of questions.entries()) {
        if (count >= 6) break;
        const key = sanitizeKey(question?.key, index);
        if (properties[key]) continue;
        const title = asText(question?.title).slice(0, 120) || `Question ${index + 1}`;
        const description = asText(question?.description).slice(0, 400) || undefined;
        const options = Array.isArray(question?.options)
            ? question.options.map((option) => asText(option).slice(0, 80)).filter(Boolean).slice(0, 8)
            : [];

        if (question?.kind === "boolean") {
            properties[key] = { type: "boolean", title, description };
        } else if (question?.kind === "choice" && options.length >= 2) {
            properties[key] = choiceField(title, description, options, asText(question?.recommended));
        } else {
            properties[key] = { type: "string", title, description };
        }
        // Keyed rather than positional: questions are skipped for duplicate keys and capped at
        // six, so the schema's key order stops matching the source array's indices.
        titles.set(key, title);
        count += 1;
    }
    return { schema: { type: "object", properties }, titles };
}

function renderAnswers(rounds) {
    if (rounds.length === 0) return "The user was not asked any clarifying questions.";
    const lines = [];
    for (const round of rounds) {
        lines.push(`### Round ${round.round}`, ``);
        if (round.skipped) {
            lines.push(`The user declined to answer this round.`, ``);
            continue;
        }
        for (const item of round.answers) {
            lines.push(`- **${item.title}**`, `  - Answer: ${item.answer}`);
        }
        lines.push(``);
    }
    return lines.join("\n");
}

/* -------------------------------------------------------------------------------------------
 * Escalation.
 *
 * A loop that runs out of attempts hands the decision back to the user rather than pretending
 * to a verdict it never received. This is the plugins' escalation path, with the same options.
 * ------------------------------------------------------------------------------------------- */

async function escalate(ctx, run, { key, stage, attempts, lastFindings }) {
    const answer = await ask(ctx, key, {
        message: [
            `The ${stage} is not converging: ${attempts} attempts without a PASS.`,
            ``,
            `Most recent findings:`,
            truncate(lastFindings || "(the reviewer returned nothing usable)", 1400),
            ``,
            `The full history is in ${run.feedbackPath}.`,
            ``,
            `How should this run proceed? An escalated review never becomes a passed review — if you`,
            `accept the risk, the audit trail will keep reporting it as escalated.`,
        ].join("\n"),
        requestedSchema: {
            type: "object",
            properties: {
                decision: choiceField(
                    "How should we proceed?",
                    "Retrying with guidance gives the loop a fresh budget of attempts.",
                    ["Retry with the guidance below", "Accept the risk and continue", "Stop the run here"],
                    "Retry with the guidance below",
                ),
                guidance: {
                    type: "string",
                    title: "Guidance or missing context",
                    description:
                        "What the reviewer does not know: a constraint, a decision already made, or the reason a finding does not apply here.",
                },
            },
        },
    });

    const decision = asText(answer?.content?.decision);
    const guidance = asText(answer?.content?.guidance).trim();

    if (answer?.action !== "accept") {
        run.notes.push(`${stage}: escalated and the user did not respond; stopping.`);
        return { action: "stop", guidance: "" };
    }
    if (decision.startsWith("Accept")) {
        run.notes.push(`${stage}: escalated after ${attempts} attempts; the user accepted the risk.`);
        return { action: "accept", guidance };
    }
    if (decision.startsWith("Stop")) {
        run.notes.push(`${stage}: escalated after ${attempts} attempts; the user stopped the run.`);
        return { action: "stop", guidance };
    }
    run.notes.push(`${stage}: escalated after ${attempts} attempts; retrying with user guidance.`);
    return { action: "retry", guidance };
}

/* -------------------------------------------------------------------------------------------
 * Phase 1 — Intake.
 * ------------------------------------------------------------------------------------------- */

async function intake(ctx, run, { requireRequest }) {
    setPhase(ctx, run, "Intake");

    const gitRoot = await git(run.repoRoot, ["rev-parse", "--show-toplevel"]);
    if (gitRoot.ok && gitRoot.stdout) {
        const root = resolve(gitRoot.stdout);
        if (root !== run.repoRoot) {
            // The factory was invoked from a subdirectory. Everything else in the run is anchored
            // to the repository root — the `.autodev` ignore check, the root handed to every
            // subagent, the worktree snapshots — so the default artifact paths have to move with
            // it. Otherwise the plan lands in whichever subdirectory the CLI happened to start in
            // while the reviewers are told to look for it at the root.
            run.repoRoot = root;
            Object.assign(run, artifactPaths(root, run.pathArgs));
        }
    }

    const head = await git(run.repoRoot, ["rev-parse", "HEAD"]);
    run.baseline = head.ok ? head.stdout : "uncommitted working tree";

    if (!run.request && requireRequest) {
        const answer = await ask(ctx, "intake:request-v1", {
            message: "What would you like autodev to plan and implement?",
            requestedSchema: {
                type: "object",
                properties: {
                    request: {
                        type: "string",
                        title: "Feature or project description",
                        description:
                            "A paragraph is plenty. The clarifying round will pull out whatever else is needed.",
                    },
                },
                required: ["request"],
            },
        });
        run.request = asText(answer?.content?.request).trim();
        if (!run.request) {
            return { stop: "No feature description was given, so there is nothing to plan." };
        }
    }

    // The plan, the todo list and the audit trail all land in `.autodev/`. Creating that
    // directory in a repository that does not ignore it means the user's next `git status` is
    // full of files they did not ask for, so ask before it happens rather than after.
    const ignored = await git(run.repoRoot, ["check-ignore", "-q", ".autodev"]);
    if (!ignored.ok) {
        const answer = await ask(ctx, "intake:gitignore-v1", {
            message: [
                `\`.autodev/\` is not ignored by git in this repository.`,
                ``,
                `autodev writes the plan, the todo list and the audit trail there. Unless it is ignored,`,
                `all of it will show up as untracked changes — and the code reviewers will see it.`,
            ].join("\n"),
            requestedSchema: {
                type: "object",
                properties: {
                    decision: choiceField(
                        "Add `.autodev/` to .gitignore?",
                        "Nothing is written to .gitignore unless you say so here.",
                        ["Yes, add it", "No, leave .gitignore alone"],
                        "Yes, add it",
                    ),
                },
            },
        });
        if (asText(answer?.content?.decision).startsWith("Yes")) {
            await appendGitignore(run.repoRoot);
            run.notes.push("Added `.autodev/` to .gitignore.");
        } else {
            run.notes.push("`.autodev/` is not ignored; its files will appear as untracked changes.");
        }
    }

    await initTrail(run);

    ctx.log("orienting in the repository");
    const { result } = await callAgent(ctx, run, {
        label: "intake:orientation",
        model: "claude-sonnet-4.6",
        schema: ORIENTATION_SCHEMA,
        prompt: [
            `Orient yourself in the repository at ${run.repoRoot} and report what a planning agent`,
            `would need to know about it. Read the build files, the test setup, the top-level layout`,
            `and a representative source file or two. Prefer grep and glob over reading large files.`,
            ``,
            `The feature under consideration is: ${run.request}`,
            ``,
            `Return JSON:`,
            `- projectContext: one or two sentences — the language, the framework, and what this codebase is.`,
            `- buildCommand: the command that builds this project, or "none found".`,
            `- testCommand: the command that runs its tests, or "none found".`,
            `- conventions: the conventions an implementer must follow here — naming, layout, testing style, error handling.`,
            ``,
            `Do not modify anything.`,
        ].join("\n"),
    });

    if (result && typeof result === "object") {
        run.project = {
            context: asText(result.projectContext).slice(0, 800),
            build: asText(result.buildCommand).slice(0, 200) || "none found",
            test: asText(result.testCommand).slice(0, 200) || "none found",
            conventions: asText(result.conventions).slice(0, 1200),
        };
    } else {
        run.project = {
            context: "Not determined — the orientation subagent returned nothing.",
            build: "none found",
            test: "none found",
            conventions: "",
        };
        run.notes.push("Repository orientation failed; subagents were briefed without it.");
    }

    await recordAttempt(run, {
        time: timestamp(),
        phase: "Intake",
        stage: "orientation",
        attempt: 1,
        label: "intake:orientation",
        model: "claude-sonnet-4.6",
        verdict: result ? "OK" : "NO RESPONSE",
        chars: asText(JSON.stringify(result ?? null)).length,
        notes: `build: ${run.project.build}; test: ${run.project.test}`,
    });

    ctx.log(`repository: ${run.project.context}`);
    return {};
}

async function appendGitignore(repoRoot) {
    const path = resolve(repoRoot, ".gitignore");
    let existing = "";
    try {
        existing = await readFile(path, "utf8");
    } catch {
        existing = "";
    }
    if (/^\.autodev\/?\s*$/m.test(existing)) return;
    const prefix = existing.length === 0 || existing.endsWith("\n") ? "" : "\n";
    await writeFile(path, `${existing}${prefix}.autodev/\n`, "utf8");
}

/* -------------------------------------------------------------------------------------------
 * Phase 2 — Clarify.
 * ------------------------------------------------------------------------------------------- */

async function clarify(ctx, run) {
    setPhase(ctx, run, "Clarify");

    if (elicitationUnavailable(ctx.session)) {
        run.notes.push("The host does not support interactive prompts, so the clarifying conversation was skipped.");
        ctx.log("no interactive prompt support — skipping the clarifying round");
        return;
    }

    const maxRounds = Math.min(run.clarifyRounds, CAPS.clarifyRounds);
    for (let round = 1; round <= maxRounds; round += 1) {
        const { result } = await callAgent(ctx, run, {
            label: `clarify:round-${round}`,
            model: "claude-opus-5",
            schema: QUESTIONS_SCHEMA,
            prompt: [
                CLARIFIER_INSTRUCTIONS,
                ``,
                `---`,
                ``,
                `# Your task`,
                ``,
                `Repository root: ${run.repoRoot}`,
                `Project context: ${run.project.context}`,
                `Conventions: ${run.project.conventions || "not determined"}`,
                ``,
                `The user wants to build:`,
                ``,
                run.request,
                ``,
                `This is round ${round} of at most ${maxRounds}.`,
                ``,
                round === 1
                    ? `No questions have been asked yet. Read the repository before deciding what to ask.`
                    : `Questions already asked and answered:\n\n${renderAnswers(run.clarifications)}`,
                ``,
                `Return JSON matching the schema.`,
            ].join("\n"),
        });

        const questions = Array.isArray(result?.questions) ? result.questions : [];
        if (result?.done === true || questions.length === 0) {
            ctx.log(`clarifying complete after ${round - 1} round(s)`);
            await recordAttempt(run, {
                time: timestamp(),
                phase: "Clarify",
                stage: "question generation",
                attempt: round,
                label: `clarify:round-${round}`,
                model: "claude-opus-5",
                verdict: "DONE",
                chars: 0,
                notes: asText(result?.rationale).slice(0, 200) || "no further questions",
            });
            return;
        }

        const { schema, titles } = questionsToSchema(questions);
        const keys = Object.keys(schema.properties);
        if (keys.length === 0) return;

        const answer = await ask(ctx, `clarify:answers-${round}-v1`, {
            message:
                round === 1
                    ? "A few questions before I write the plan. Leave anything blank that you would rather I decide."
                    : `A few follow-up questions (round ${round}).`,
            requestedSchema: schema,
        });

        if (answer?.action !== "accept") {
            run.clarifications.push({ round, skipped: true, answers: [] });
            run.notes.push(`Clarifying round ${round} was skipped by the user.`);
            ctx.log(`round ${round} skipped by the user; proceeding with what is known`);
            return;
        }

        const answers = [];
        for (const key of keys) {
            const value = answer.content?.[key];
            if (value === undefined || value === null || value === "") continue;
            answers.push({ key, title: titles.get(key) ?? key, answer: asText(value) });
        }
        run.clarifications.push({ round, skipped: false, answers });

        await recordAttempt(run, {
            time: timestamp(),
            phase: "Clarify",
            stage: "user answers",
            attempt: round,
            label: `clarify:answers-${round}`,
            verdict: "ANSWERED",
            chars: answers.map((a) => a.answer.length).reduce((total, value) => total + value, 0),
            notes: `${answers.length} of ${keys.length} question(s) answered`,
        });

        if (answers.length === 0) {
            run.notes.push(`Clarifying round ${round} came back empty; remaining decisions were left to the planner.`);
            return;
        }
    }
}

/* -------------------------------------------------------------------------------------------
 * Phase 3 — Draft.
 * ------------------------------------------------------------------------------------------- */

async function draftPlan(ctx, run) {
    setPhase(ctx, run, "Draft plan");

    for (let attempt = 1; attempt <= 3; attempt += 1) {
        ctx.log(attempt === 1 ? "drafting the plan" : `re-drafting the plan (attempt ${attempt})`);

        // The pre-attempt digest is journaled on its own, and nothing else here is. `ctx.agent`
        // replays from the journal on a resumed run *without* re-running the write, so judging
        // freshness against a live "before" would call the completed attempt a failure and
        // re-draft — over a plan the gates may already have amended. Journaling the whole attempt
        // instead would leave a crash window: step producers are at-least-once, so a failure
        // between the inner agent committing and the outer step committing would re-run the
        // producer, and its fresh "before" would already include the write. A digest is inert, so
        // replaying it is always correct.
        const before = await ctx.step(`draft:before-${attempt}-v1`, () => fileSnapshot(run.planPath));

        // A plan left behind by an earlier run is not this run's plan. Without this, a planner
        // that returned nothing at all would be credited with whatever `.autodev/plan.md` already
        // happened to contain, and the gates would go on to review a stale document.
        const { result, model } = await callAgent(ctx, run, {
            label: `draft:attempt-${attempt}`,
            model: "claude-opus-5",
            prompt: [
                PLANNER_INSTRUCTIONS,
                ``,
                `---`,
                ``,
                `# Your task`,
                ``,
                `Write the implementation plan to: ${run.planPath}`,
                ``,
                `Repository root: ${run.repoRoot}`,
                `Project context: ${run.project.context}`,
                `Build command: ${run.project.build}`,
                `Test command: ${run.project.test}`,
                `Conventions: ${run.project.conventions || "not determined"}`,
                ``,
                `## The request`,
                ``,
                run.request,
                ``,
                `## Clarifying answers`,
                ``,
                renderAnswers(run.clarifications),
                attempt > 1
                    ? `\n## Previous attempt\n\nYour previous attempt did not leave a new plan at that path — either nothing was written, or the file was left exactly as it already was. Write the plan this time, and confirm in your reply that you wrote it.`
                    : ``,
            ].join("\n"),
        });

        const response = asText(result);
        const written = (await fileExists(run.planPath)) && (await fileSnapshot(run.planPath)) !== before;

        await recordAttempt(run, {
            time: timestamp(),
            phase: "Draft plan",
            stage: "plan drafting",
            attempt,
            label: `draft:attempt-${attempt}`,
            model,
            verdict: written ? "WRITTEN" : "NO FILE",
            chars: response.length,
            notes: written ? "" : "the subagent left no new plan at the expected path",
            response: response || null,
        });

        if (written) {
            run.planSummary = truncate(response, 2000);
            return {};
        }
    }

    return { stop: `The planning subagent did not produce a plan at ${run.planPath} after three attempts.` };
}

/* -------------------------------------------------------------------------------------------
 * Phase 4 — Plan approval.
 *
 * The plugin workflow is explicit that leaving APPROVE is the user's decision and that the
 * orchestrator must not start the gates on its own initiative. The same rule applies here.
 * ------------------------------------------------------------------------------------------- */

async function approvePlan(ctx, run) {
    setPhase(ctx, run, "Plan approval");

    if (elicitationUnavailable(ctx.session)) {
        run.notes.push("The host does not support interactive prompts, so the plan was gated without user approval.");
        return { proceed: true };
    }

    for (let round = 1; round <= CAPS.planApprovalRounds; round += 1) {
        const answer = await ask(ctx, `approve:round-${round}-v1`, {
            message: [
                `The plan is written to:`,
                run.planPath,
                ``,
                run.planSummary || "",
                ``,
                `Read it and tell me how to proceed. The three review gates — architecture, then security,`,
                `then privacy — run without further input once they start, and I will report back when the`,
                `plan is clean.`,
            ].join("\n"),
            requestedSchema: {
                type: "object",
                properties: {
                    decision: choiceField(
                        "How should we proceed?",
                        "The gates do not start until you say so.",
                        ["Run the review gates", "Make the changes below first", "Stop here"],
                        "Run the review gates",
                    ),
                    changes: {
                        type: "string",
                        title: "Changes you want first",
                        description: "Anything wrong, missing, or out of scope. Passed to the reviser verbatim.",
                    },
                },
            },
        });

        if (answer?.action !== "accept") {
            return { stop: "The plan was not approved, so the review gates did not run." };
        }

        const decision = asText(answer.content?.decision);
        const changes = asText(answer.content?.changes).trim();

        if (decision.startsWith("Stop")) {
            return { stop: "You chose to stop after drafting. The plan is written but has not been reviewed." };
        }
        if (decision.startsWith("Run")) {
            return { proceed: true };
        }
        if (!changes) {
            // They asked for changes and described none. That is not approval of the plan as it
            // stands, so the gates do not start — the question is simply asked again.
            ctx.log("changes were requested at approval but none were described; asking again");
            run.notes.push(`Approval round ${round} requested changes without describing any; the plan was re-presented.`);
            continue;
        }

        ctx.log(`applying your changes to the plan (round ${round})`);
        const revision = await callPlanReviser(ctx, run, {
            label: `approve:revise-${round}`,
            phase: "Plan approval",
            stage: "user-requested plan changes",
            attempt: round,
            task: [
                `Revise the implementation plan at ${run.planPath}.`,
                ``,
                `Repository root: ${run.repoRoot}`,
                `Project context: ${run.project.context}`,
                `Build command: ${run.project.build}`,
                `Test command: ${run.project.test}`,
                ``,
                `## What the user asked for`,
                ``,
                `The user read the plan and asked for the following, in their own words. Treat it as`,
                `authoritative — it is the person the plan is for, not a reviewer you may argue with:`,
                ``,
                changes,
            ].join("\n"),
        });
        run.planSummary = truncate(revision.response, 2000);
    }

    // Running out of revision rounds is not approval. The user asked for changes every round and
    // never once chose "Run the review gates"; treating exhaustion as consent would start an
    // autonomous phase they did not authorize, which is the one thing this checkpoint exists to
    // prevent. So ask plainly, once, and default to stopping.
    const final = await ask(ctx, "approve:final-v1", {
        message: [
            `We have been round ${CAPS.planApprovalRounds} times on the plan at:`,
            run.planPath,
            ``,
            run.planSummary || "",
            ``,
            `That is as many revision rounds as I will do in one run. Should the review gates run on`,
            `this revision, or should I stop so you can edit the plan yourself?`,
        ].join("\n"),
        requestedSchema: {
            type: "object",
            properties: {
                decision: choiceField(
                    "Run the gates on this revision?",
                    "Stopping leaves the plan on disk; you can edit it and run again.",
                    ["Run the review gates", "Stop here"],
                    "Stop here",
                ),
            },
        },
    });

    if (final?.action === "accept" && asText(final.content?.decision).startsWith("Run")) {
        run.notes.push(
            `Plan approval used all ${CAPS.planApprovalRounds} revision rounds; you then approved the last revision.`,
        );
        return { proceed: true };
    }

    return {
        stop: `Plan approval used all ${CAPS.planApprovalRounds} revision rounds without an approval, so the gates did not run. The latest plan is at ${run.planPath}.`,
    };
}

/* -------------------------------------------------------------------------------------------
 * Phases 5-7 — The plan gates.
 *
 * Sequential, deliberately: each reviewer should see the plan as amended by the previous one.
 * ------------------------------------------------------------------------------------------- */

async function runPlanGates(ctx, run) {
    for (const gate of PLAN_GATES) {
        setPhase(ctx, run, `${gate.title} gate`);
        const outcome = await runPlanGate(ctx, run, gate);
        run.gates[gate.key] = outcome;
        await writeStatus(run);
        if (outcome.status === "stopped") {
            return { stop: `The ${gate.title.toLowerCase()} gate was stopped by you.` };
        }
    }
    return {};
}

async function runPlanGate(ctx, run, gate) {
    const guard = () => fileSnapshot(run.planPath);
    let previousFindings = null;
    let guidance = "";
    let escalations = 0;
    let attempt = 0;
    let budget = CAPS.planGateAttempts;

    while (attempt < budget) {
        if (run.planReviewerCalls >= CAPS.planReviewerCalls) {
            run.notes.push(
                `The ${gate.title.toLowerCase()} gate stopped at the ${CAPS.planReviewerCalls}-call ceiling for plan reviewers.`,
            );
            return { status: "escalated", attempts: attempt, reason: "session reviewer ceiling reached" };
        }

        attempt += 1;
        ctx.log(`${gate.title} gate — attempt ${attempt}`);

        const review = await callReviewer(ctx, run, {
            promptKey: gate.prompt,
            label: `plan-gate:${gate.key}:${attempt}`,
            phase: `${gate.title} gate`,
            stage: `${gate.title.toLowerCase()} review`,
            attempt,
            guard,
            // The model fallback is a second reviewer subagent, so it is only offered when the
            // ceiling can actually pay for it. Otherwise a run sitting at 39 could finish at 41.
            maxInvocations: CAPS.planReviewerCalls - run.planReviewerCalls,
            task: buildGateTask(run, gate, attempt, budget, previousFindings, guidance),
        });
        // Charged after the fact and by actual invocation count, because a model fallback inside
        // `callAgent` spends two reviewer subagents on one attempt.
        run.planReviewerCalls += review.invocations;

        if (review.verdict === "PASS" && !review.violated && !review.unverified) {
            ctx.log(`${gate.title} gate passed on attempt ${attempt}`);
            return { status: "passed", attempts: attempt };
        }

        // A reviewer that edited the plan it was reviewing does not get to approve the result of
        // its own edit, however clean the verdict looked, and neither does one whose restraint
        // could not be checked at all. The violation is already recorded; here the PASS simply
        // does not count, and the attempt is spent like any other failure. There is nothing for
        // the reviser to do with a clean report, so the reviewer is re-run instead.
        const rejectedPass = review.verdict === "PASS" && (review.violated || review.unverified);
        if (rejectedPass) {
            ctx.log(
                `${gate.title} gate — attempt ${attempt} returned PASS but ${
                    review.violated ? "modified the plan" : "could not be verified read-only"
                }; not accepted`,
            );
        }

        // A missing verdict is not a pass and never becomes one. When there is nothing to act on
        // the plan is left alone and the same reviewer is asked again — editing the plan to look
        // busy would only muddy the next review — and the attempt still counts, so a reviewer
        // that keeps malfunctioning walks the gate to its cap instead of looping forever.
        if (review.empty || rejectedPass) {
            if (review.empty) {
                ctx.log(`${gate.title} gate — attempt ${attempt} returned nothing; re-running the reviewer`);
            }
            if (attempt < budget) continue;
        } else {
            previousFindings = review.response;
            if (attempt < budget) {
                const revision = await callPlanReviser(ctx, run, {
                    label: `plan-revise:${gate.key}:${attempt}`,
                    phase: `${gate.title} gate`,
                    stage: `${gate.title.toLowerCase()} revision`,
                    attempt,
                    task: buildPlanRevisionTask(run, gate, review.response),
                });
                previousFindings = `${review.response}\n\n## What the reviser reports it changed\n\n${truncate(
                    revision.response,
                    4000,
                )}`;
                continue;
            }
        }

        // Out of attempts.
        escalations += 1;
        if (escalations > CAPS.escalationsPerStage) {
            run.notes.push(`The ${gate.title.toLowerCase()} gate escalated twice without converging.`);
            return { status: "escalated", attempts: attempt, reason: "escalation limit reached" };
        }
        const decision = await escalate(ctx, run, {
            key: `escalate:plan-${gate.key}-${escalations}-v1`,
            stage: `${gate.title.toLowerCase()} gate`,
            attempts: attempt,
            lastFindings: previousFindings,
        });
        if (decision.action === "stop") return { status: "stopped", attempts: attempt };
        if (decision.action === "accept") {
            return { status: "escalated", attempts: attempt, reason: "risk accepted by the user" };
        }
        guidance = decision.guidance;
        budget = attempt + CAPS.planGateAttempts;
    }

    return { status: "escalated", attempts: attempt, reason: "attempt budget exhausted" };
}

function buildGateTask(run, gate, attempt, budget, previousFindings, guidance) {
    const lines = [
        `Review the implementation plan at ${run.planPath}.`,
        ``,
        `Repository root: ${run.repoRoot}`,
        `Project context: ${run.project.context}`,
        `Feature being planned: ${truncate(run.request, 600)}`,
        ``,
        `This is attempt ${attempt} of at most ${budget} for this gate.`,
    ];
    if (guidance) {
        lines.push(
            ``,
            `## Context from the user`,
            ``,
            `The user supplied this after the gate failed to converge. Treat it as authoritative:`,
            ``,
            guidance,
        );
    }
    // The `## Previous findings` heading is a contract with the reviewers: they are stateless and
    // have no other way to tell a first review from a re-review. It must be absent on attempt 1.
    if (previousFindings) {
        lines.push(
            ``,
            `## Previous findings`,
            ``,
            `Your previous review raised the findings below. The plan has been revised in response.`,
            `Focus on verifying that each was genuinely addressed. Raise a new finding only if it is`,
            `blocker or major and the plan introduced it, worsened it, or it directly affects behavior`,
            `added or changed by the plan.`,
            ``,
            truncate(previousFindings, 12000),
        );
    }
    lines.push(``, `Follow your output format exactly and end with your AUTODEV-VERDICT line.`);
    return lines.join("\n");
}

function buildPlanRevisionTask(run, gate, findings) {
    return [
        `Revise the implementation plan at ${run.planPath}.`,
        ``,
        `Repository root: ${run.repoRoot}`,
        `Project context: ${run.project.context}`,
        `Reviewer: ${gate.title.toLowerCase()} gate`,
        ``,
        `## Findings`,
        ``,
        truncate(findings, 14000),
    ].join("\n");
}

/* -------------------------------------------------------------------------------------------
 * Phase 8 — Implementation handoff.
 *
 * The pause this factory exists for: planning is finished, and nothing is implemented until the
 * user says so.
 * ------------------------------------------------------------------------------------------- */

async function handoff(ctx, run) {
    setPhase(ctx, run, "Implementation handoff");

    const summary = PLAN_GATES.map((gate) => {
        const outcome = run.gates[gate.key];
        if (!outcome) return `- ${gate.title}: not run`;
        if (outcome.status === "passed") return `- ${gate.title}: passed on attempt ${outcome.attempts}`;
        return `- ${gate.title}: **escalated** after ${outcome.attempts} attempts (${outcome.reason})`;
    }).join("\n");

    const escalated = PLAN_GATES.filter((gate) => run.gates[gate.key]?.status !== "passed");

    if (elicitationUnavailable(ctx.session)) {
        run.notes.push("The host does not support interactive prompts, so the run stopped at the handoff.");
        return { proceed: false, reason: "no interactive prompt support at the handoff checkpoint" };
    }

    const answer = await ask(ctx, "handoff:decision-v1", {
        message: [
            `Planning is complete.`,
            ``,
            `Plan: ${run.planPath}`,
            `Audit trail: ${run.auditPath}`,
            `Reviewer feedback: ${run.feedbackPath}`,
            ``,
            `Gates:`,
            summary,
            escalated.length
                ? `\n${escalated.length} gate(s) did not pass. An escalated gate never becomes a passed gate — implementing now means implementing an unreviewed plan.`
                : ``,
            ``,
            `Ready to implement? Implementation runs autonomously through tasking and every milestone,`,
            `and comes back to you at the code checkpoint before the final security and privacy reviews.`,
        ].join("\n"),
        requestedSchema: {
            type: "object",
            properties: {
                decision: choiceField(
                    "Start implementation?",
                    "Stopping here leaves the plan on disk; you can re-run autodev later with startAt: \"implement\".",
                    [
                        "Yes — start implementing",
                        "No — stop here, the plan is what I wanted",
                        "No — I want to edit the plan first",
                    ],
                    escalated.length ? "No — stop here, the plan is what I wanted" : "Yes — start implementing",
                ),
            },
        },
    });

    if (answer?.action !== "accept") {
        return { proceed: false, reason: "no answer at the handoff checkpoint" };
    }
    const decision = asText(answer.content?.decision);
    if (decision.startsWith("Yes")) return { proceed: true };
    if (decision.includes("edit the plan")) {
        return {
            proceed: false,
            reason: `you chose to edit the plan first — re-run autodev with {"startAt": "implement"} when it is ready`,
        };
    }
    return { proceed: false, reason: "you chose to stop after planning" };
}

/* -------------------------------------------------------------------------------------------
 * Phase 9 — Tasking.
 * ------------------------------------------------------------------------------------------- */

async function tasking(ctx, run) {
    setPhase(ctx, run, "Tasking");

    let correction = "";
    for (let attempt = 1; attempt <= CAPS.taskingAttempts; attempt += 1) {
        ctx.log(attempt === 1 ? "decomposing the plan into milestones" : `re-running tasking (attempt ${attempt})`);

        // Journaled for the same reason, and in the same shape, as the draft attempts above: an
        // inert digest, taken before the subagent runs, so a resumed run compares against what
        // was on disk originally rather than against the write it is replaying.
        const before = await ctx.step(`tasking:before-${attempt}-v1`, () => fileSnapshot(run.todosPath));

        // As with the plan: a todo list from an earlier run must not be mistaken for this one's.
        // The milestone list drives everything that follows, so inheriting a stale one would send
        // the implementation agents off building a different feature entirely.
        const result = await callWorker(ctx, run, {
            promptKey: "autodev-tasking",
            label: `tasking:attempt-${attempt}`,
            phase: "Tasking",
            stage: "tasking",
            attempt,
            task: [
                `Break the implementation plan at ${run.planPath} into a milestone-structured todo list`,
                `at ${run.todosPath}.`,
                ``,
                `Repository root: ${run.repoRoot}`,
                `Project context: ${run.project.context}`,
                `Build command: ${run.project.build}`,
                `Test command: ${run.project.test}`,
                correction ? `\n## Previous attempt\n\n${correction}\nRevise it in place.` : ``,
                ``,
                `Follow your output format exactly and end with your AUTODEV-VERDICT line.`,
            ].join("\n"),
        });

        let todos = "";
        try {
            todos = await readFile(run.todosPath, "utf8");
        } catch {
            todos = "";
        }

        const fresh = (await fileSnapshot(run.todosPath)) !== before;
        const milestones = parseMilestones(todos);
        const problem = milestonesAreWellFormed(milestones);

        // `DONE` exactly. The tasking agent's own contract says a response without a parseable
        // verdict is recorded as BLOCKED, so accepting "anything but BLOCKED" would have accepted
        // precisely the responses it tells us to reject.
        if (!problem && fresh && result.verdict === "DONE") {
            run.milestones = milestones.map((milestone) => ({
                number: milestone.number,
                title: milestone.title,
                status: "pending",
                reviewRounds: 0,
                unresolvedFindings: null,
            }));
            ctx.log(`${milestones.length} milestone(s): ${milestones.map((m) => `${m.number}. ${m.title}`).join("; ")}`);
            await writeStatus(run);
            return {};
        }

        if (result.verdict === "BLOCKED") {
            correction = `You reported BLOCKED:\n\n${truncate(result.response, 3000)}\n\nWork from the plan and the repository, record any unresolved ambiguity as an assumption, and produce the list.`;
        } else if (!fresh) {
            correction = `You did not write ${run.todosPath}. Anything already at that path is left over from an earlier run and does not count — write the todo list yourself, from the plan.`;
        } else if (problem) {
            correction = `The todo list you wrote cannot be walked: ${problem}. The milestone heading format is a machine-readable contract — level-two headings reading "## Milestone <n>", numbered consecutively from 1, each followed immediately by a \`**Status:** not-started\` line.`;
        } else {
            correction = `You wrote the todo list but did not end with a parseable \`AUTODEV-VERDICT: DONE\` line, so the result could not be accepted. Confirm the list is complete and end your reply with that line, on its own line, as the very last thing you write.`;
        }
    }

    return { stop: `Tasking could not produce a usable todo list at ${run.todosPath} after ${CAPS.taskingAttempts} attempts.` };
}

/* -------------------------------------------------------------------------------------------
 * Phase 10 — The milestone loop.
 * ------------------------------------------------------------------------------------------- */

async function runMilestones(ctx, run) {
    setPhase(ctx, run, "Milestones");

    for (const milestone of run.milestones) {
        const label = `Milestone ${milestone.number} of ${run.milestones.length} — ${milestone.title}`;
        ctx.log(`${label}. Implementing.`);
        milestone.status = "implementing";
        await writeStatus(run);

        const before = await worktreeSnapshot(run.repoRoot);
        const implemented = await implementMilestone(ctx, run, milestone);
        if (implemented.stop) return implemented;

        const after = await worktreeSnapshot(run.repoRoot);
        milestone.changedAreas = describeChanges(before, after);

        milestone.status = "reviewing";
        const reviewed = await reviewMilestone(ctx, run, milestone);
        if (reviewed.stop) return reviewed;

        milestone.status = "complete";
        await writeStatus(run);
    }
    return {};
}

function describeChanges(before, after) {
    if (before === null || after === null) return "uncommitted working tree (git status unavailable)";
    const previous = new Set(before.split("\n").filter(Boolean));
    const changed = after
        .split("\n")
        .filter(Boolean)
        .filter((line) => !previous.has(line))
        .map((line) => line.slice(3).trim())
        .filter(Boolean);
    if (changed.length === 0) return "no working-tree changes were detected";
    return changed.slice(0, 40).join(", ") + (changed.length > 40 ? `, …and ${changed.length - 40} more` : "");
}

async function implementMilestone(ctx, run, milestone) {
    let correction = "";
    for (let attempt = 1; attempt <= CAPS.implementationAttempts; attempt += 1) {
        const result = await callWorker(ctx, run, {
            promptKey: "autodev-implementation",
            label: `implement:m${milestone.number}:${attempt}`,
            phase: "Milestones",
            stage: `milestone ${milestone.number} implementation`,
            attempt,
            task: [
                `Implement milestone ${milestone.number} of the todo list at ${run.todosPath}.`,
                ``,
                `Plan: ${run.planPath}`,
                `Repository root: ${run.repoRoot}`,
                `Project context: ${run.project.context}`,
                `Build command: ${run.project.build}`,
                `Test command: ${run.project.test}`,
                `Conventions: ${run.project.conventions || "not determined"}`,
                ``,
                `Implement ONLY milestone ${milestone.number}. Do not start any later milestone.`,
                correction ? `\n## Previous attempt\n\n${correction}` : ``,
                ``,
                `Follow your output format exactly and end with your AUTODEV-VERDICT line.`,
            ].join("\n"),
        });

        if (result.verdict === "DONE") return {};

        if (result.empty) {
            correction = `Your previous attempt returned nothing. Implement the milestone and report what you did.`;
            continue;
        }
        correction = [
            `Your previous attempt reported:`,
            ``,
            truncate(result.response, 4000),
            ``,
            `Resolution: decide the ambiguity yourself using the plan and the repository, record the`,
            `decision in the milestone's Review notes, and implement the milestone.`,
        ].join("\n");
    }

    run.notes.push(
        `Milestone ${milestone.number} never returned DONE after ${CAPS.implementationAttempts} attempts; it went to review in whatever state it was left.`,
    );
    milestone.unresolvedFindings = "the implementation stage never reported DONE";
    return {};
}

async function reviewMilestone(ctx, run, milestone) {
    const guard = () => codeSnapshot(run.repoRoot, [run.planPath, run.todosPath]);
    let previousFindings = null;

    for (let round = 1; round <= CAPS.codeReviewRounds; round += 1) {
        milestone.reviewRounds = round;
        const review = await callReviewer(ctx, run, {
            promptKey: "autodev-code-review",
            label: `code-review:m${milestone.number}:${round}`,
            phase: "Milestones",
            stage: `milestone ${milestone.number} review`,
            attempt: round,
            guard,
            task: buildCodeReviewTask(run, {
                scope: `the implementation of milestone ${milestone.number} in this repository`,
                changedAreas: milestone.changedAreas,
                round,
                budget: CAPS.codeReviewRounds,
                previousFindings,
            }),
        });

        if (review.verdict === "PASS" && !review.violated && !review.unverified) {
            ctx.log(`Milestone ${milestone.number} passed review on round ${round}.`);
            return {};
        }
        // A reviewer that changed the code it was reviewing cannot sign off on it, and neither
        // can one whose restraint could not be checked. Nothing to fix from a clean report, so
        // re-review instead of running the fix agent.
        const rejectedPass = review.verdict === "PASS" && (review.violated || review.unverified);
        if (rejectedPass) {
            ctx.log(
                `Milestone ${milestone.number} — round ${round} returned PASS but ${
                    review.violated ? "changed the tree" : "could not be verified read-only"
                }; not accepted`,
            );
        }
        if (review.empty || rejectedPass) {
            if (round < CAPS.codeReviewRounds) continue;
            break;
        }

        previousFindings = review.response;
        if (round < CAPS.codeReviewRounds) {
            const fix = await callWorker(ctx, run, {
                promptKey: "autodev-code-fix",
                label: `code-fix:m${milestone.number}:${round}`,
                phase: "Milestones",
                stage: `milestone ${milestone.number} fix`,
                attempt: round,
                task: buildFixTask(run, `code review of milestone ${milestone.number}`, review.response),
            });
            previousFindings = `${review.response}\n\n## What the fix agent reports it did\n\n${truncate(fix.response, 4000)}`;
        }
    }

    // Code review deliberately does not escalate. The plugin workflow records the outstanding
    // findings and moves on, because a milestone that will not converge should not stall the run
    // — but it must be said out loud at wrapup rather than quietly dropped.
    //
    // `unresolvedFindings` is what wrapup and the final `clean` calculation read, so reaching
    // here must always leave it truthy. A reviewer that returned nothing every single round
    // yields no findings text at all, and recording that empty string would have made a
    // milestone that never passed review indistinguishable from one that did. Any marker the
    // implementation stage left is kept rather than overwritten: "never reported DONE" and
    // "never passed review" are different facts and the user should get both.
    const outstanding = truncate(previousFindings, 4000).trim();
    milestone.unresolvedFindings = [
        milestone.unresolvedFindings,
        outstanding ||
            `code review never returned a PASS in ${CAPS.codeReviewRounds} rounds, and never returned readable findings either`,
    ]
        .filter(Boolean)
        .join("\n\n");
    run.notes.push(
        `Milestone ${milestone.number} did not pass code review within ${CAPS.codeReviewRounds} rounds; the outstanding findings are in ${run.feedbackPath}.`,
    );
    ctx.log(`Milestone ${milestone.number} hit the review cap; recording the findings and moving on.`);
    return {};
}

function buildCodeReviewTask(run, { scope, changedAreas, round, budget, previousFindings, guidance }) {
    const lines = [
        `Review ${scope}.`,
        ``,
        `Plan: ${run.planPath}`,
        `Todo list: ${run.todosPath}`,
        `Repository root: ${run.repoRoot}`,
        `Project context: ${run.project.context}`,
        `Changed areas: ${changedAreas || "not determined — inspect the working tree"}`,
        `Baseline: ${run.baseline} (the implementation is the uncommitted working tree on top of it)`,
        ``,
        `This is round ${round} of at most ${budget} for this review.`,
    ];
    if (guidance) {
        lines.push(``, `## Context from the user`, ``, guidance);
    }
    if (previousFindings) {
        lines.push(
            ``,
            `## Previous findings`,
            ``,
            `Your previous review raised the findings below. They have since been addressed. Verify each`,
            `was genuinely fixed, and review the current state of the code as a whole.`,
            ``,
            truncate(previousFindings, 12000),
        );
    }
    lines.push(``, `Follow your output format exactly and end with your AUTODEV-VERDICT line.`);
    return lines.join("\n");
}

function buildFixTask(run, reviewer, findings) {
    return [
        `Address the review findings below.`,
        ``,
        `Plan: ${run.planPath}`,
        `Todo list: ${run.todosPath}`,
        `Repository root: ${run.repoRoot}`,
        `Reviewer: ${reviewer}`,
        `Build command: ${run.project.build}`,
        `Test command: ${run.project.test}`,
        ``,
        `## Findings`,
        ``,
        truncate(findings, 14000),
        ``,
        `Follow your output format exactly and end with your AUTODEV-VERDICT line.`,
    ].join("\n");
}

/* -------------------------------------------------------------------------------------------
 * Phase 11 — The code checkpoint.
 * ------------------------------------------------------------------------------------------- */

async function codeCheckpoint(ctx, run) {
    setPhase(ctx, run, "Code checkpoint");

    if (elicitationUnavailable(ctx.session)) {
        run.notes.push("The host does not support interactive prompts, so the code checkpoint was skipped.");
        return { proceed: true };
    }

    const built = run.milestones
        .map((milestone) => {
            const suffix = milestone.unresolvedFindings ? " — **unresolved findings**" : "";
            return `- Milestone ${milestone.number}: ${milestone.title} (${milestone.reviewRounds} review round(s))${suffix}`;
        })
        .join("\n");

    for (let round = 1; round <= CAPS.userReviewRounds; round += 1) {
        const answer = await ask(ctx, `checkpoint:round-${round}-v1`, {
            message: [
                `Every milestone is implemented and its review loop has ended.`,
                ``,
                built,
                ``,
                `Todo list: ${run.todosPath}`,
                `Audit trail: ${run.auditPath}`,
                `Reviewer feedback: ${run.feedbackPath}`,
                run.notes.length ? `\nWorth a look:\n${run.notes.map((note) => `- ${note}`).join("\n")}` : ``,
                ``,
                `Review the code. When you are happy with it I will run the whole-implementation security`,
                `and privacy reviews, which run without further input.`,
            ].join("\n"),
            requestedSchema: {
                type: "object",
                properties: {
                    decision: choiceField(
                        "How does it look?",
                        "Anything you ask for goes through the fix agent, not through me.",
                        ["Looks good — run the final reviews", "Fix the issues below first", "Stop here"],
                        "Looks good — run the final reviews",
                    ),
                    changes: {
                        type: "string",
                        title: "What needs to change",
                        description: "Passed to the fix agent verbatim — your framing usually carries context a paraphrase loses.",
                    },
                },
            },
        });

        if (answer?.action !== "accept") {
            return { stop: "The code checkpoint went unanswered, so the final reviews did not run." };
        }
        const decision = asText(answer.content?.decision);
        const changes = asText(answer.content?.changes).trim();

        if (decision.startsWith("Stop")) {
            return { stop: "You stopped the run at the code checkpoint. The final reviews did not run." };
        }
        if (decision.startsWith("Looks good")) {
            return { proceed: true };
        }
        if (!changes) {
            // Same rule as plan approval: asking for fixes and naming none is not sign-off.
            ctx.log("fixes were requested at the checkpoint but none were described; asking again");
            run.notes.push(`Checkpoint round ${round} requested fixes without describing any; the code was re-presented.`);
            continue;
        }

        ctx.log(`applying your feedback (round ${round})`);
        await callWorker(ctx, run, {
            promptKey: "autodev-code-fix",
            label: `checkpoint-fix:${round}`,
            phase: "Code checkpoint",
            stage: "user-requested fixes",
            attempt: round,
            task: buildFixTask(run, "the user", changes),
        });
        // A fix here re-locks the checkpoint on purpose: the user should see the corrected code
        // before the final reviews run.
    }

    // Same rule as plan approval: exhausting the fix rounds is not the user saying "Looks good".
    // Running the final security and privacy reviews — and the autonomous fixes they trigger — on
    // code the user kept asking to change would be doing it unasked.
    const final = await ask(ctx, "checkpoint:final-v1", {
        message: [
            `We have been round ${CAPS.userReviewRounds} times on this implementation. That is as many`,
            `fix rounds as I will do in one run.`,
            ``,
            `Should the final security and privacy reviews run on the current code, or should I stop`,
            `here and leave it to you?`,
        ].join("\n"),
        requestedSchema: {
            type: "object",
            properties: {
                decision: choiceField(
                    "Run the final reviews?",
                    "Stopping leaves the code exactly as it is now.",
                    ["Run the final reviews", "Stop here"],
                    "Stop here",
                ),
            },
        },
    });

    if (final?.action === "accept" && asText(final.content?.decision).startsWith("Run")) {
        run.notes.push(
            `The code checkpoint used all ${CAPS.userReviewRounds} fix rounds; you then approved the current state.`,
        );
        return { proceed: true };
    }

    return {
        stop: `The code checkpoint used all ${CAPS.userReviewRounds} fix rounds without an approval, so the final security and privacy reviews did not run.`,
    };
}

/* -------------------------------------------------------------------------------------------
 * Phases 12-13 — Whole-implementation security and privacy review.
 * ------------------------------------------------------------------------------------------- */

const FINAL_REVIEWS = Object.freeze([
    { key: "codeSecurity", phase: "Code security review", title: "security", prompt: "autodev-code-security-review" },
    { key: "codePrivacy", phase: "Code privacy review", title: "privacy", prompt: "autodev-code-privacy-review" },
]);

async function runFinalReviews(ctx, run) {
    for (const review of FINAL_REVIEWS) {
        setPhase(ctx, run, review.phase);
        const outcome = await runFinalReview(ctx, run, review);
        run.gates[review.key] = outcome;
        await writeStatus(run);
        if (outcome.status === "stopped") {
            return { stop: `The ${review.title} review was stopped by you.` };
        }
    }
    return {};
}

async function runFinalReview(ctx, run, review) {
    const guard = () => codeSnapshot(run.repoRoot, [run.planPath, run.todosPath]);
    let previousFindings = null;
    let guidance = "";
    let escalations = 0;
    let round = 0;
    let budget = CAPS.finalReviewRounds;

    while (round < budget) {
        round += 1;
        ctx.log(`${review.title} review — round ${round}`);

        const result = await callReviewer(ctx, run, {
            promptKey: review.prompt,
            label: `final-review:${review.key}:${round}`,
            phase: review.phase,
            stage: `${review.title} review`,
            attempt: round,
            guard,
            task: buildCodeReviewTask(run, {
                scope: "the whole implementation described by the todo list",
                changedAreas: truncate(run.milestones.map((m) => m.changedAreas).filter(Boolean).join("; "), 3000),
                round,
                budget,
                previousFindings,
                guidance,
            }),
        });

        if (result.verdict === "PASS" && !result.violated && !result.unverified) {
            ctx.log(`${review.title} review passed on round ${round}`);
            return { status: "passed", attempts: round };
        }
        // Same rule as the gates: it reviewed its own edit, or its restraint could not be
        // checked, so the PASS does not stand.
        const rejectedPass = result.verdict === "PASS" && (result.violated || result.unverified);
        if (rejectedPass) {
            ctx.log(
                `${review.title} review — round ${round} returned PASS but ${
                    result.violated ? "changed the tree" : "could not be verified read-only"
                }; not accepted`,
            );
        }

        if (result.empty || rejectedPass) {
            if (round < budget) continue;
        } else {
            previousFindings = result.response;
            if (round < budget) {
                const fix = await callWorker(ctx, run, {
                    promptKey: "autodev-code-fix",
                    label: `final-fix:${review.key}:${round}`,
                    phase: review.phase,
                    stage: `${review.title} fix`,
                    attempt: round,
                    task: buildFixTask(run, `${review.title} review`, result.response),
                });
                previousFindings = `${result.response}\n\n## What the fix agent reports it did\n\n${truncate(fix.response, 4000)}`;
                continue;
            }
        }

        escalations += 1;
        if (escalations > CAPS.escalationsPerStage) {
            run.notes.push(`The ${review.title} review escalated twice without converging.`);
            return { status: "escalated", attempts: round, reason: "escalation limit reached" };
        }
        const decision = await escalate(ctx, run, {
            key: `escalate:final-${review.key}-${escalations}-v1`,
            stage: `${review.title} review`,
            attempts: round,
            lastFindings: previousFindings,
        });
        if (decision.action === "stop") return { status: "stopped", attempts: round };
        if (decision.action === "accept") {
            return { status: "escalated", attempts: round, reason: "risk accepted by the user" };
        }
        guidance = decision.guidance;
        budget = round + CAPS.finalReviewRounds;
    }

    return { status: "escalated", attempts: round, reason: "round budget exhausted" };
}

/* -------------------------------------------------------------------------------------------
 * Phase 14 — Wrapup.
 * ------------------------------------------------------------------------------------------- */

function gateLine(title, outcome) {
    if (!outcome) return `- ${title}: not run`;
    if (outcome.status === "passed") return `- ${title}: passed on attempt ${outcome.attempts}`;
    if (outcome.status === "stopped") return `- ${title}: stopped by the user after ${outcome.attempts} attempts`;
    return `- ${title}: **escalated** after ${outcome.attempts} attempts (${outcome.reason})`;
}

async function wrapup(ctx, run, outcome) {
    setPhase(ctx, run, "Wrapup");

    const lines = [
        `# autodev run summary`,
        ``,
        `Run: \`${run.runId}\``,
        `Started: ${run.startedAt}`,
        `Finished: ${timestamp()}`,
        `Outcome: **${outcome.status}**${outcome.reason ? ` — ${outcome.reason}` : ""}`,
        ``,
        `## Artifacts`,
        ``,
        `- Plan: \`${run.planPath}\``,
        `- Todo list: \`${run.todosPath}\``,
        `- Audit trail: \`${run.auditPath}\``,
        `- Reviewer feedback: \`${run.feedbackPath}\``,
        `- Live status: \`${run.statusPath}\``,
        ``,
        `## Plan gates`,
        ``,
        gateLine("Architecture", run.gates.architecture),
        gateLine("Security", run.gates.security),
        gateLine("Privacy", run.gates.privacy),
        ``,
        `## Implementation`,
        ``,
        run.milestones.length
            ? run.milestones
                  .map(
                      (milestone) =>
                          `- Milestone ${milestone.number} — ${milestone.title}: ${milestone.status}, ${milestone.reviewRounds} review round(s)${
                              milestone.unresolvedFindings ? " — **unresolved findings**" : ""
                          }`,
                  )
                  .join("\n")
            : `- Implementation did not run.`,
        ``,
        gateLine("Whole-implementation security review", run.gates.codeSecurity),
        gateLine("Whole-implementation privacy review", run.gates.codePrivacy),
        ``,
        `## Notes`,
        ``,
        run.notes.length ? run.notes.map((note) => `- ${note}`).join("\n") : `- None.`,
        ``,
        `## Process violations`,
        ``,
        run.violations.length
            ? run.violations.map((violation) => `- ${violation.time} · ${violation.label} · ${violation.kind}`).join("\n")
            : `- None. No reviewer modified the artifacts it was reviewing.`,
        ``,
        `## Accounting`,
        ``,
        `- Subagent invocations: ${run.subagentCalls}`,
        `- Plan reviewer invocations: ${run.planReviewerCalls} (ceiling ${CAPS.planReviewerCalls})`,
        ``,
    ];

    await writeFile(run.summaryPath, lines.join("\n"), "utf8").catch(() => {});
    await writeStatus(run);

    return {
        status: outcome.status,
        reason: outcome.reason ?? null,
        runId: run.runId,
        repoRoot: run.repoRoot,
        planPath: run.planPath,
        todosPath: run.todosPath,
        auditPath: run.auditPath,
        feedbackPath: run.feedbackPath,
        statusPath: run.statusPath,
        summaryPath: run.summaryPath,
        planGates: {
            architecture: run.gates.architecture ?? null,
            security: run.gates.security ?? null,
            privacy: run.gates.privacy ?? null,
        },
        finalReviews: {
            security: run.gates.codeSecurity ?? null,
            privacy: run.gates.codePrivacy ?? null,
        },
        milestones: run.milestones,
        notes: run.notes,
        violations: run.violations,
        subagentCalls: run.subagentCalls,
        promptBundle: GENERATED_FROM,
    };
}

/* -------------------------------------------------------------------------------------------
 * The factory.
 * ------------------------------------------------------------------------------------------- */

const autodevFactory = defineFactory({
    meta: {
        name: "autodev-factory",
        description: [
            "Runs the complete autodev software-development loop in one run: the autodev-plan workflow",
            "(clarifying conversation, plan drafting, user approval, then isolated architecture, security",
            "and privacy gates), a pause to ask whether to proceed, and then the autodev-implement workflow",
            "(tasking into milestones, per-milestone implementation and code review, a user code checkpoint,",
            "and whole-implementation security and privacy reviews).",
            "",
            "args: {",
            '  request?: string      — what to plan and implement. Prompted for if omitted.',
            '  repoRoot?: string     — absolute path to the repository. Defaults to the working directory.',
            '  planPath?: string     — where the plan goes. Defaults to <repoRoot>/.autodev/plan.md.',
            '  todosPath?: string    — where the todo list goes. Defaults to <repoRoot>/.autodev/todos.md.',
            '  startAt?: "plan" | "implement" — "implement" skips planning and uses the existing plan. Defaults to "plan".',
            "  clarifyRounds?: number — how many rounds of clarifying questions to allow, 0-4. Defaults to 3.",
            "}",
            "",
            "Requires an interactive host: the run pauses for user approval before the gates, before",
            "implementation, and at the code checkpoint.",
        ].join("\n"),
        phases: PHASES,
    },

    run: async (ctx) => {
        const args = ctx.args && typeof ctx.args === "object" && !Array.isArray(ctx.args) ? ctx.args : {};
        const repoRoot = resolve(typeof args.repoRoot === "string" && args.repoRoot.trim() ? args.repoRoot.trim() : process.cwd());

        const run = {
            runId: ctx.runId,
            startedAt: timestamp(),
            repoRoot,
            request: typeof args.request === "string" ? args.request.trim() : "",
            // Kept so intake can re-anchor the artifacts once `git rev-parse` says where the
            // repository root actually is.
            pathArgs: { planPath: args.planPath, todosPath: args.todosPath },
            ...artifactPaths(repoRoot, { planPath: args.planPath, todosPath: args.todosPath }),
            clarifyRounds: Number.isFinite(args.clarifyRounds)
                ? Math.max(0, Math.min(CAPS.clarifyRounds, Math.trunc(args.clarifyRounds)))
                : 3,
            phase: "Intake",
            project: { context: "", build: "none found", test: "none found", conventions: "" },
            baseline: "uncommitted working tree",
            planSummary: "",
            clarifications: [],
            milestones: [],
            gates: {},
            notes: [],
            violations: [],
            attempts: [],
            subagentCalls: 0,
            planReviewerCalls: 0,
        };

        const startAt = args.startAt === "implement" ? "implement" : "plan";

        // --- Planning -------------------------------------------------------------------
        if (startAt === "plan") {
            const intakeResult = await intake(ctx, run, { requireRequest: true });
            if (intakeResult.stop) return wrapup(ctx, run, { status: "stopped", reason: intakeResult.stop });

            await clarify(ctx, run);

            const drafted = await draftPlan(ctx, run);
            if (drafted.stop) return wrapup(ctx, run, { status: "failed", reason: drafted.stop });

            const approved = await approvePlan(ctx, run);
            if (approved.stop) return wrapup(ctx, run, { status: "plan-drafted", reason: approved.stop });

            const gated = await runPlanGates(ctx, run);
            if (gated.stop) return wrapup(ctx, run, { status: "plan-incomplete", reason: gated.stop });
        } else {
            // Implementing an existing plan needs no feature description: the plan is the brief.
            const intakeResult = await intake(ctx, run, { requireRequest: false });
            if (intakeResult.stop) return wrapup(ctx, run, { status: "stopped", reason: intakeResult.stop });
            if (!(await fileExists(run.planPath))) {
                return wrapup(ctx, run, {
                    status: "failed",
                    reason: `startAt was "implement" but there is no plan at ${run.planPath}.`,
                });
            }
            if (!run.request) run.request = `the plan already written at ${run.planPath}`;
            run.notes.push(`Started at implementation against the existing plan at ${run.planPath}; the plan gates did not run.`);
        }

        // --- The handoff ----------------------------------------------------------------
        if (startAt === "plan") {
            const decision = await handoff(ctx, run);
            if (!decision.proceed) {
                return wrapup(ctx, run, { status: "plan-complete", reason: decision.reason });
            }
        }

        // --- Implementation -------------------------------------------------------------
        const tasked = await tasking(ctx, run);
        if (tasked.stop) return wrapup(ctx, run, { status: "failed", reason: tasked.stop });

        const built = await runMilestones(ctx, run);
        if (built.stop) return wrapup(ctx, run, { status: "implementation-incomplete", reason: built.stop });

        const checkpoint = await codeCheckpoint(ctx, run);
        if (checkpoint.stop) return wrapup(ctx, run, { status: "implemented", reason: checkpoint.stop });

        const finalReviews = await runFinalReviews(ctx, run);
        if (finalReviews.stop) return wrapup(ctx, run, { status: "implemented", reason: finalReviews.stop });

        const clean =
            run.gates.codeSecurity?.status === "passed" &&
            run.gates.codePrivacy?.status === "passed" &&
            run.milestones.every((milestone) => !milestone.unresolvedFindings);

        return wrapup(ctx, run, {
            status: clean ? "completed" : "completed-with-findings",
            reason: clean ? null : "some reviews did not reach a PASS — see the notes",
        });
    },
});

/* -------------------------------------------------------------------------------------------
 * Session join.
 *
 * Deliberately hookless — see the note on hooks above. Registering extension hooks was observed
 * to leave the session's hook processor unable to start any subagent at all, which would take
 * this factory's own reviewers with it.
 *
 * The guard exists for `tests/factory.tests.mjs`, which imports this module for the pure helpers
 * exported below. There is no CLI on the other end of stdio in a test process, so `joinSession`
 * would hang there.
 * ------------------------------------------------------------------------------------------- */

if (process.env.AUTODEV_FACTORY_TEST !== "1") {
    await joinSession({ factories: [autodevFactory] });
}

export {
    artifactPaths,
    autodevFactory,
    CAPS,
    describeChanges,
    escapeCell,
    milestonesAreWellFormed,
    parseMilestones,
    questionsToSchema,
    readVerdict,
    resolveUnder,
    sanitizeKey,
    truncate,
};
