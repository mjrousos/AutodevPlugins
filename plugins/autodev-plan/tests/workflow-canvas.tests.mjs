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
    class FakeElement {
        constructor() {
            this.attributes = {};
            this.children = [];
            this.className = "";
            this.dataset = {};
            this.disabled = false;
            this.style = {};
            this.textContent = "";
        }

        addEventListener() {}

        append(...children) {
            this.children.push(...children);
        }

        focus() {}

        querySelector() {
            return null;
        }

        querySelectorAll() {
            return [];
        }

        replaceChildren(...children) {
            this.children = children;
        }

        setAttribute(name, value) {
            this.attributes[name] = value;
        }
    }

    const elements = new Map(
        ["content", "refresh", "workflow-badge", "workflow-subtitle", "workflow-progress", "workflow-percent"]
            .map((id) => [id, new FakeElement()]),
    );
    const workflowState = {
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
            gates: [],
            phases: [],
        },
        implementation: {
            completedMilestones: 0,
            currentPhase: "Not started",
            gates: [],
            milestoneCount: 0,
            milestones: [],
            phases: [],
        },
    };
    const responses = [
        { ok: true, json: async () => workflowState },
        { ok: false, json: async () => ({ error: "Temporary read failure" }) },
        { ok: true, json: async () => workflowState },
    ];
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

    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(elements.get("workflow-badge").textContent, "In progress");

    await poll();
    assert.equal(elements.get("workflow-badge").textContent, "Unavailable");

    await poll();
    assert.equal(elements.get("workflow-badge").textContent, "In progress");
});
