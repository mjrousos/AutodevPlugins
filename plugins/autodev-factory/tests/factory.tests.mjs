/**
 * Unit tests for the autodev-factory pure logic.
 *
 * The orchestration itself cannot be tested without a live CLI session, so what is covered here
 * is everything that decides *what the orchestration does*: how a verdict is read, how the todo
 * list's machine-readable contract is validated, how a model's suggested questions become a form
 * the host will accept, and how paths resolve. Those are the places where a quiet bug would turn
 * a review gate into a rubber stamp.
 *
 * Run: node --import ./plugins/autodev-factory/tests/register-stub.mjs --test plugins/autodev-factory/tests/factory.tests.mjs
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";

process.env.AUTODEV_FACTORY_TEST = "1";

const {
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
} = await import("../extensions/autodev-factory/extension.mjs");

/* ---------------------------------------------------------------------------------------------
 * readVerdict — a missing verdict must never read as a pass.
 * ------------------------------------------------------------------------------------------- */

test("readVerdict reads a well-formed trailing verdict", () => {
    assert.equal(readVerdict("## Findings\n\nNone.\n\nAUTODEV-VERDICT: PASS"), "PASS");
    assert.equal(readVerdict("blah\nAUTODEV-VERDICT: ISSUES\n"), "ISSUES");
    assert.equal(readVerdict("AUTODEV-VERDICT: DONE"), "DONE");
    assert.equal(readVerdict("AUTODEV-VERDICT: BLOCKED"), "BLOCKED");
});

test("readVerdict returns null when there is no verdict at all", () => {
    assert.equal(readVerdict("I reviewed it and it looks fine to me."), null);
    assert.equal(readVerdict(""), null);
    assert.equal(readVerdict(null), null);
    assert.equal(readVerdict(undefined), null);
    assert.equal(readVerdict({ verdict: "PASS" }), null);
});

test("readVerdict takes the last verdict, not a quoted one", () => {
    // Reviewers sometimes restate their output format before answering. Taking the first match
    // would let a quoted example decide a gate.
    const response = [
        "I will end with the verdict line when the plan is clean.",
        "AUTODEV-VERDICT: PASS",
        "",
        "## Findings",
        "### [blocker] no authorization on the share endpoint",
        "",
        "AUTODEV-VERDICT: ISSUES",
    ].join("\n");
    assert.equal(readVerdict(response), "ISSUES");
});

test("readVerdict tolerates indentation and casing but not decoration", () => {
    assert.equal(readVerdict("   AUTODEV-VERDICT: pass"), "PASS");
    assert.equal(readVerdict("AUTODEV-VERDICT:\tISSUES  "), "ISSUES");
    // A verdict with trailing commentary on the same line is not a verdict.
    assert.equal(readVerdict("AUTODEV-VERDICT: PASS (with reservations)"), null);
    assert.equal(readVerdict("**AUTODEV-VERDICT: PASS**"), null);
});

test("readVerdict refuses a verdict that is not the last thing in the response", () => {
    // The mirror image of the quoted-example case, and the dangerous direction: a reviewer that
    // restates its output format with PASS in the example, then reports blockers and forgets its
    // own verdict line, must not open the gate. Unreadable costs one attempt; a false PASS
    // costs the gate.
    const response = [
        "I will finish with a line like:",
        "AUTODEV-VERDICT: PASS",
        "",
        "## Findings",
        "### [blocker] the token is logged in cleartext",
    ].join("\n");
    assert.equal(readVerdict(response), null);
    // Trailing whitespace and blank lines are still a trailing verdict.
    assert.equal(readVerdict("## Findings\n\nNone.\n\nAUTODEV-VERDICT: PASS\n\n   \n"), "PASS");
});

/* ---------------------------------------------------------------------------------------------
 * The todo list contract.
 * ------------------------------------------------------------------------------------------- */

const wellFormedTodos = [
    "# Implementation todos — thing",
    "",
    "## Overview",
    "",
    "## Milestone 1 — data model",
    "",
    "**Status:** not-started",
    "",
    "## Milestone 2 — sync worker",
    "",
    "**Status:** not-started",
].join("\n");

test("parseMilestones finds numbered milestone headings", () => {
    const milestones = parseMilestones(wellFormedTodos);
    assert.deepEqual(milestones, [
        { number: 1, title: "data model", status: "not-started" },
        { number: 2, title: "sync worker", status: "not-started" },
    ]);
    assert.equal(milestonesAreWellFormed(milestones), null);
});

test("parseMilestones reads the Status line the stage tracker depends on", () => {
    // `autodev-tasking` specifies this line exactly: immediately under the heading, with one of
    // three values. A milestone without a usable one is a milestone nothing can report on, so
    // tasking is re-run rather than accepted.
    const missing = parseMilestones(
        ["## Milestone 1 — has one", "", "**Status:** not-started", "## Milestone 2 — has none", "Some prose."].join("\n"),
    );
    assert.deepEqual(
        missing.map((m) => m.status),
        ["not-started", null],
    );
    assert.match(milestonesAreWellFormed(missing), /milestone 2 has no `\*\*Status:\*\*` line/);
    // A bare heading with nothing under it is the degenerate case and must not be accepted.
    assert.match(milestonesAreWellFormed(parseMilestones("## Milestone 1")), /has no `\*\*Status:\*\*` line/);
    // A label with no value, or an unknown value, is not a status.
    assert.equal(parseMilestones("## Milestone 1 — x\n**Status:**")[0].status, "");
    assert.match(milestonesAreWellFormed(parseMilestones("## Milestone 1 — x\n**Status:**")), /has no `\*\*Status:\*\*`/);
    assert.match(
        milestonesAreWellFormed(parseMilestones("## Milestone 1 — x\n**Status:** whenever")),
        /has no `\*\*Status:\*\*`/,
    );
    // It has to be the first thing under the heading, not buried further down.
    assert.match(
        milestonesAreWellFormed(parseMilestones("## Milestone 1 — x\n### Goal\nsomething\n\n**Status:** not-started")),
        /has no `\*\*Status:\*\*`/,
    );
    // The other two legal values still parse — the factory is not the only writer of this file.
    assert.equal(parseMilestones("## Milestone 1 — x\n**Status:** in-progress")[0].status, "in-progress");
    assert.equal(parseMilestones("## Milestone 1 — x\n**Status:** complete")[0].status, "complete");
});

test("parseMilestones accepts the separators the tasking agent may emit", () => {
    const parsed = parseMilestones("## Milestone 1 - hyphen\n## Milestone 2 – en dash\n## Milestone 3 plain");
    assert.deepEqual(
        parsed.map((m) => m.title),
        ["hyphen", "en dash", "plain"],
    );
});

test("parseMilestones ignores headings at the wrong level or in prose", () => {
    const text = ["### Milestone 1 — not a milestone heading", "Some prose about Milestone 2.", "## Milestones"].join("\n");
    assert.deepEqual(parseMilestones(text), []);
});

test("milestonesAreWellFormed rejects lists the tracker could not walk", () => {
    assert.match(milestonesAreWellFormed([]), /no `## Milestone <n>` headings/);
    assert.match(
        milestonesAreWellFormed([
            { number: 1, title: "a", status: "not-started" },
            { number: 3, title: "c", status: "not-started" },
        ]),
        /not numbered consecutively/,
    );
    assert.match(
        milestonesAreWellFormed([
            { number: 2, title: "b", status: "not-started" },
            { number: 1, title: "a", status: "not-started" },
        ]),
        /not numbered consecutively/,
    );
    const tooMany = Array.from({ length: CAPS.milestones + 1 }, (_, index) => ({
        number: index + 1,
        title: "x",
        status: "not-started",
    }));
    assert.match(milestonesAreWellFormed(tooMany), /exceeds the supported maximum/);
});

test("parseMilestones handles CRLF, which is what a Windows worker writes", () => {
    const parsed = parseMilestones("## Milestone 1 — one\r\n**Status:** not-started\r\n## Milestone 2 — two\r\n");
    assert.equal(parsed.length, 2);
    assert.equal(parsed[1].title, "two");
});

/* ---------------------------------------------------------------------------------------------
 * Elicitation form construction. The questions come from a model, so anything here may be
 * malformed; the host rejects a malformed schema and the clarifying round would be lost.
 * ------------------------------------------------------------------------------------------- */

test("questionsToSchema builds the three supported field kinds", () => {
    const { schema, titles } = questionsToSchema([
        {
            key: "storage",
            title: "Where should it be stored?",
            kind: "choice",
            options: ["SQLite", "Postgres"],
            recommended: "Postgres",
        },
        { key: "flagged", title: "Behind a feature flag?", kind: "boolean" },
        { key: "notes", title: "Anything else?", kind: "text" },
    ]);
    assert.equal(schema.type, "object");
    assert.deepEqual(schema.properties.storage, {
        type: "string",
        title: "Where should it be stored?",
        description: undefined,
        enum: ["SQLite", "Postgres"],
        default: "Postgres",
    });
    assert.equal(schema.properties.flagged.type, "boolean");
    assert.equal(schema.properties.notes.type, "string");
    assert.equal(schema.properties.notes.enum, undefined);
    assert.equal(titles.get("storage"), "Where should it be stored?");
});

test("questionsToSchema never emits a default outside its own enum", () => {
    const { schema } = questionsToSchema([
        { key: "k", title: "t", kind: "choice", options: ["a", "b"], recommended: "c" },
    ]);
    assert.equal(schema.properties.k.default, undefined);
});

test("questionsToSchema degrades a one-option choice to free text", () => {
    // An enum of one is not a choice, and some hosts reject it outright.
    const { schema } = questionsToSchema([{ key: "k", title: "t", kind: "choice", options: ["only"] }]);
    assert.equal(schema.properties.k.type, "string");
    assert.equal(schema.properties.k.enum, undefined);
});

test("questionsToSchema drops duplicate keys and keeps titles aligned", () => {
    const { schema, titles } = questionsToSchema([
        { key: "same", title: "first", kind: "text" },
        { key: "same", title: "second", kind: "text" },
        { key: "other", title: "third", kind: "text" },
    ]);
    assert.deepEqual(Object.keys(schema.properties), ["same", "other"]);
    assert.equal(titles.get("same"), "first");
    assert.equal(titles.get("other"), "third");
});

test("questionsToSchema caps the form at six fields", () => {
    const questions = Array.from({ length: 12 }, (_, index) => ({
        key: `k${index}`,
        title: `t${index}`,
        kind: "text",
    }));
    const { schema } = questionsToSchema(questions);
    assert.equal(Object.keys(schema.properties).length, 6);
});

test("questionsToSchema survives junk from the model", () => {
    const { schema } = questionsToSchema([
        { key: "", title: "", kind: "choice" },
        { key: "!!!", title: "ok", kind: undefined },
        { key: "x", title: "y", kind: "choice", options: "not an array" },
    ]);
    for (const [key, field] of Object.entries(schema.properties)) {
        assert.ok(key.length > 0, "every key is non-empty");
        assert.ok(["string", "boolean"].includes(field.type));
        assert.ok(typeof field.title === "string" && field.title.length > 0);
    }
});

test("sanitizeKey produces a usable identifier from anything", () => {
    assert.equal(sanitizeKey("Storage Backend", 0), "storage_backend");
    assert.equal(sanitizeKey("--weird--", 0), "weird");
    assert.equal(sanitizeKey("", 3), "question_4");
    assert.equal(sanitizeKey(null, 0), "question_1");
    assert.equal(sanitizeKey("!!!", 1), "question_2");
});

/* ---------------------------------------------------------------------------------------------
 * Paths, change detection, and audit-table escaping.
 * ------------------------------------------------------------------------------------------- */

test("resolveUnder resolves relative paths under the repo", () => {
    const root = resolve("/tmp/repo");
    assert.equal(resolveUnder(root, null, ".autodev/plan.md"), resolve(root, ".autodev/plan.md"));
    assert.equal(resolveUnder(root, "  ", ".autodev/plan.md"), resolve(root, ".autodev/plan.md"));
    assert.equal(resolveUnder(root, "docs/plan.md", ".autodev/plan.md"), resolve(root, "docs/plan.md"));
});

test("resolveUnder keeps every artifact path inside the repository", () => {
    // `planPath` and `todosPath` come from a model, and the agents that write them have a shell.
    // Anything that resolves outside the repository falls back to the default rather than
    // pointing them at a file the user never named.
    const root = resolve("/tmp/repo");
    assert.equal(resolveUnder(root, "../outside.md", ".autodev/plan.md"), resolve(root, ".autodev/plan.md"));
    assert.equal(resolveUnder(root, "a/../../outside.md", ".autodev/plan.md"), resolve(root, ".autodev/plan.md"));
    assert.equal(resolveUnder(root, resolve("/elsewhere/plan.md"), ".autodev/plan.md"), resolve(root, ".autodev/plan.md"));
    // Climbing out and back in is fine — it resolves inside the root.
    assert.equal(resolveUnder(root, "a/../docs/plan.md", ".autodev/plan.md"), resolve(root, "docs/plan.md"));
    // An absolute path that points inside the repository is honored as given.
    assert.equal(resolveUnder(root, resolve(root, "docs/plan.md"), ".autodev/plan.md"), resolve(root, "docs/plan.md"));
    // The root itself is not a file the plan can be written to.
    assert.equal(resolveUnder(root, ".", ".autodev/plan.md"), resolve(root, ".autodev/plan.md"));
});

test("artifactPaths anchors every artifact to the root it is given", () => {
    // Intake re-runs this once `git rev-parse` reports the real repository root, so a run started
    // in a subdirectory does not leave the plan there while telling the reviewers to read it from
    // the root.
    const sub = resolve("/tmp/repo/packages/api");
    const root = resolve("/tmp/repo");
    const inSub = artifactPaths(sub, {});
    const inRoot = artifactPaths(root, {});
    assert.equal(inSub.planPath, resolve(sub, ".autodev/plan.md"));
    assert.equal(inRoot.planPath, resolve(root, ".autodev/plan.md"));
    for (const key of ["planPath", "todosPath", "auditPath", "feedbackPath", "statusPath", "summaryPath"]) {
        assert.equal(inRoot[key], resolve(root, ".autodev", inRoot[key].split(/[\\/]/).pop()), `${key} lands in .autodev`);
    }
    // An explicitly supplied path still wins.
    assert.equal(artifactPaths(root, { planPath: "docs/plan.md" }).planPath, resolve(root, "docs/plan.md"));
});

test("describeChanges reports only what appeared after the baseline snapshot", () => {
    const before = " M src/existing.ts";
    const after = " M src/existing.ts\n?? src/new.ts\n M src/changed.ts";
    assert.equal(describeChanges(before, after), "src/new.ts, src/changed.ts");
});

test("describeChanges is honest when it cannot tell", () => {
    assert.match(describeChanges(null, "?? a.ts"), /git status unavailable/);
    assert.match(describeChanges(" M a.ts", " M a.ts"), /no working-tree changes/);
});

test("escapeCell keeps a response from breaking the audit table", () => {
    assert.equal(escapeCell("a | b"), "a \\| b");
    assert.equal(escapeCell("line one\nline two"), "line one line two");
    assert.equal(escapeCell("crlf\r\nhere"), "crlf here");
    assert.equal(escapeCell(null), "");
});

test("truncate marks what it dropped", () => {
    assert.equal(truncate("short", 100), "short");
    const result = truncate("x".repeat(50), 10);
    assert.ok(result.startsWith("x".repeat(10)));
    assert.match(result, /truncated 40 characters/);
});

/* ---------------------------------------------------------------------------------------------
 * The registration itself.
 * ------------------------------------------------------------------------------------------- */

test("the factory is registered with every phase it reports", () => {
    assert.equal(autodevFactory.meta.name, "autodev-factory");
    assert.equal(autodevFactory.meta.phases.length, 14);
    for (const phase of autodevFactory.meta.phases) {
        assert.ok(typeof phase.title === "string" && phase.title.length > 0);
    }
});

test("the description documents the argument shape, which is all the model gets", () => {
    // `run_factory` forwards args verbatim and its parameter is untyped, so the description is
    // the only contract an agent can read.
    for (const argument of ["request", "repoRoot", "planPath", "todosPath", "startAt", "clarifyRounds"]) {
        assert.match(autodevFactory.meta.description, new RegExp(argument), `description documents ${argument}`);
    }
});

test("no declared limits — every loop bounds itself", () => {
    assert.equal(autodevFactory.meta.limits, undefined);
    for (const [name, value] of Object.entries(CAPS)) {
        assert.ok(Number.isInteger(value) && value > 0, `${name} is a positive integer`);
    }
});
