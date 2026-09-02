import assert from "node:assert/strict";
import { access, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

import {
    loadAutodevState,
    locateAutodevDir,
} from "../extensions/autodev-workflow/autodev-data.mjs";
import { renderHtml } from "../extensions/autodev-workflow/renderer.mjs";

async function withTemporaryDirectory(run) {
    const root = path.join(
        tmpdir(),
        `autodev-workflow-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    );
    await mkdir(root, { recursive: true });
    try {
        await run(root);
    } finally {
        await rm(root, { recursive: true, force: true });
    }
}

class FakeElement {
    constructor() {
        this.attributes = {};
        this.children = [];
        this.className = "";
        this.dataset = {};
        this.disabled = false;
        this.listeners = {};
        this.style = {};
        this.textContent = "";
    }

    addEventListener(type, listener) {
        this.listeners[type] ??= [];
        this.listeners[type].push(listener);
    }

    append(...children) {
        this.children.push(...children);
    }

    dispatch(type, event) {
        for (const listener of this.listeners[type] ?? []) {
            listener(event);
        }
    }

    focus() {}

    matches(selector) {
        if (!selector.startsWith(".")) {
            return false;
        }
        return this.className.split(/\s+/).includes(selector.slice(1));
    }

    querySelector(selector) {
        return this.querySelectorAll(selector)[0] ?? null;
    }

    querySelectorAll(selector) {
        const matches = [];
        for (const child of this.children) {
            if (!(child instanceof FakeElement)) {
                continue;
            }
            if (child.matches(selector)) {
                matches.push(child);
            }
            matches.push(...child.querySelectorAll(selector));
        }
        return matches;
    }

    replaceChildren(...children) {
        this.children = children;
    }

    setAttribute(name, value) {
        this.attributes[name] = value;
    }
}

function createWorkflowState() {
    return {
        sourceUpdatedAt: "2026-09-01T12:00:00.000Z",
        sourceVersion: "unchanged",
        warnings: [],
        workflow: {
            label: "In progress",
            percent: 50,
            sessionId: "test-session",
            status: "active",
        },
        plan: {
            currentPhase: "Draft",
            events: [],
            gates: [],
            phases: [],
            status: "active",
            updatedAt: null,
        },
        implementation: {
            completedMilestones: 0,
            currentPhase: "Not started",
            events: [],
            gates: [],
            milestoneCount: 0,
            milestones: [],
            phases: [],
            status: "pending",
            updatedAt: null,
        },
    };
}

function launchCanvas(responses) {
    const elements = new Map(
        ["content", "refresh", "workflow-badge", "workflow-subtitle", "workflow-progress", "workflow-percent"]
            .map((id) => [id, new FakeElement()]),
    );
    let poll;
    const html = renderHtml({ instanceId: "test", initialView: "overview" });
    const script = html.match(/<script>([\s\S]*)<\/script>/)?.[1];
    assert.ok(script);

    runInNewContext(script, {
        document: {
            activeElement: null,
            body: { dataset: { initialView: "overview" } },
            createElement: () => new FakeElement(),
            createTextNode: (text) => text,
            getElementById: (id) => elements.get(id),
            querySelectorAll: () => [],
            scrollingElement: { scrollTop: 0 },
        },
        fetch: async () => responses.shift(),
        requestAnimationFrame: (callback) => callback(),
        setInterval: (callback) => {
            poll = callback;
            return 1;
        },
        window: {
            scrollTo() {},
            scrollX: 0,
            scrollY: 0,
        },
    });

    return {
        elements,
        poll: () => poll(),
    };
}

test("autodev-plan packages the workflow canvas as a normal extension", async () => {
    const manifestUrl = new URL("../plugin.json", import.meta.url);
    const manifest = JSON.parse(await readFile(manifestUrl, "utf8"));
    const entrypoint = await readFile(
        new URL("../extensions/autodev-workflow/extension.mjs", import.meta.url),
        "utf8",
    );

    assert.deepEqual(manifest.extensions, ["extensions/"]);
    await access(new URL("../extensions/autodev-workflow/extension.mjs", import.meta.url));
    await access(new URL("../extensions/autodev-workflow/autodev-data.mjs", import.meta.url));
    await access(new URL("../extensions/autodev-workflow/renderer.mjs", import.meta.url));
    assert.match(entrypoint, /const autodevAnchors = \[process\.cwd\(\)\];/);
    assert.doesNotMatch(entrypoint, /new URL\("\.", import\.meta\.url\)/);
});

test("autodev discovery retries after the workspace data appears", async () => {
    await withTemporaryDirectory(async (root) => {
        const workspace = path.join(root, "consumer", "nested");
        await mkdir(workspace, { recursive: true });

        assert.equal(await locateAutodevDir([workspace]), null);

        const autodevDir = path.join(root, "consumer", ".autodev");
        await mkdir(autodevDir);
        assert.equal(await locateAutodevDir([workspace]), autodevDir);
    });
});

test("empty workflow state omits local paths and has no source timestamp", async () => {
    await withTemporaryDirectory(async (root) => {
        const autodevDir = path.join(root, ".autodev");
        await mkdir(autodevDir);

        const state = await loadAutodevState(autodevDir);

        assert.equal(state.sourceUpdatedAt, null);
        assert.equal(Object.hasOwn(state, "sourceDir"), false);
    });
});

test("capped milestones count as completed workflow milestones", async () => {
    await withTemporaryDirectory(async (root) => {
        const autodevDir = path.join(root, ".autodev");
        await mkdir(autodevDir);
        await writeFile(
            path.join(autodevDir, "implement-status.json"),
            JSON.stringify({
                sessionId: "test-session",
                milestoneCount: 3,
                completedMilestones: 1,
                cappedMilestones: "2,3",
                taskingVerdict: "DONE",
                userReviewReached: 1,
                securityVerdict: "PASS",
                privacyVerdict: "PASS",
            }),
        );

        const state = await loadAutodevState(autodevDir);

        assert.equal(state.implementation.completedMilestones, 3);
        assert.deepEqual(
            state.implementation.milestones.map(({ status, closure }) => ({ status, closure })),
            [
                { status: "complete", closure: "passed" },
                { status: "capped", closure: "capped" },
                { status: "capped", closure: "capped" },
            ],
        );
        assert.equal(state.implementation.status, "complete");
    });
});

test("canvas recovers from a transient error when the source version is unchanged", async () => {
    const workflowState = createWorkflowState();
    const responses = [
        { ok: true, json: async () => workflowState },
        { ok: false, json: async () => ({ error: "Temporary read failure" }) },
        { ok: true, json: async () => workflowState },
    ];
    const canvas = launchCanvas(responses);

    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(canvas.elements.get("workflow-badge").textContent, "In progress");

    await canvas.poll();
    assert.equal(canvas.elements.get("workflow-badge").textContent, "Unavailable");

    await canvas.poll();
    assert.equal(canvas.elements.get("workflow-badge").textContent, "In progress");
});

test("canvas displays audit log paths with cross-platform separators", async () => {
    const canvas = launchCanvas([
        { ok: true, json: async () => createWorkflowState() },
    ]);
    await new Promise((resolve) => setImmediate(resolve));
    const content = canvas.elements.get("content");

    assert.doesNotThrow(() => content.dispatch("click", { target: {} }));

    const auditLink = {
        dataset: { audit: "plan" },
    };
    auditLink.closest = (selector) => selector === "[data-audit]" ? auditLink : null;
    content.dispatch("click", {
        target: {
            parentElement: auditLink,
        },
    });

    assert.equal(
        content.querySelector(".source-path").textContent,
        ".autodev/gate-audit.md",
    );
});
