import { createServer } from "node:http";
import { createCanvas, CanvasError, joinSession } from "@github/copilot-sdk/extension";
import { loadAutodevState, locateAutodevDir } from "./autodev-data.mjs";
import { renderHtml } from "./renderer.mjs";

const servers = new Map();
// Plugin extensions execute from their installed location, but inherit the consumer workspace cwd.
const autodevAnchors = [process.cwd()];
let autodevDir = null;
let autodevDiscovery = null;

async function resolveAutodevDir() {
    if (autodevDir) {
        return autodevDir;
    }

    if (!autodevDiscovery) {
        autodevDiscovery = locateAutodevDir(autodevAnchors).finally(() => {
            autodevDiscovery = null;
        });
    }

    const discovered = await autodevDiscovery;
    if (discovered) {
        autodevDir = discovered;
    }
    return discovered;
}

async function getState() {
    const directory = await resolveAutodevDir();
    if (!directory) {
        throw new CanvasError(
            "autodev_data_missing",
            "Could not find a .autodev directory in this workspace.",
        );
    }

    return loadAutodevState(directory);
}

function writeJson(res, statusCode, body) {
    res.writeHead(statusCode, {
        "Cache-Control": "no-store",
        "Content-Type": "application/json; charset=utf-8",
    });
    res.end(JSON.stringify(body));
}

async function startServer(instanceId, initialView) {
    const server = createServer(async (req, res) => {
        try {
            const url = new URL(req.url ?? "/", "http://127.0.0.1");

            if (req.method === "GET" && url.pathname === "/api/state") {
                writeJson(res, 200, await getState());
                return;
            }

            if (req.method === "POST" && url.pathname === "/api/refresh") {
                writeJson(res, 200, await getState());
                return;
            }

            if (req.method === "GET" && url.pathname === "/") {
                res.writeHead(200, {
                    "Cache-Control": "no-store",
                    "Content-Security-Policy": [
                        "default-src 'none'",
                        "script-src 'unsafe-inline'",
                        "style-src 'unsafe-inline'",
                        "connect-src 'self'",
                        "img-src 'self' data:",
                    ].join("; "),
                    "Content-Type": "text/html; charset=utf-8",
                });
                res.end(renderHtml({ instanceId, initialView }));
                return;
            }

            writeJson(res, 404, { error: "Not found" });
        } catch (error) {
            writeJson(res, 500, {
                error: error instanceof Error ? error.message : "Unable to load autodev state.",
            });
        }
    });

    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });

    const address = server.address();
    const port = typeof address === "object" && address ? address.port : 0;
    return { server, url: `http://127.0.0.1:${port}/` };
}

const session = await joinSession({
    canvases: [
        createCanvas({
            id: "autodev-workflow",
            displayName: "Autodev workflow",
            description:
                "Live visualization of autodev plan gates, implementation milestones, review loops, and current workflow status.",
            inputSchema: {
                type: "object",
                additionalProperties: false,
                properties: {
                    view: {
                        type: "string",
                        enum: ["overview", "activity", "feedback"],
                        description: "The view to show when the canvas opens.",
                    },
                },
            },
            actions: [
                {
                    name: "get_status",
                    description: "Read the latest summarized autodev workflow status.",
                    inputSchema: {
                        type: "object",
                        additionalProperties: false,
                    },
                    handler: async () => {
                        const state = await getState();
                        return {
                            generatedAt: state.generatedAt,
                            workflow: state.workflow,
                            plan: {
                                status: state.plan.status,
                                currentPhase: state.plan.currentPhase,
                                gates: state.plan.gates,
                            },
                            implementation: {
                                status: state.implementation.status,
                                currentPhase: state.implementation.currentPhase,
                                completedMilestones: state.implementation.completedMilestones,
                                milestoneCount: state.implementation.milestoneCount,
                                gates: state.implementation.gates,
                            },
                            warnings: state.warnings,
                        };
                    },
                },
                {
                    name: "refresh",
                    description: "Reload and return the latest autodev workflow state from disk.",
                    inputSchema: {
                        type: "object",
                        additionalProperties: false,
                    },
                    handler: async () => getState(),
                },
            ],
            open: async (ctx) => {
                const directory = await resolveAutodevDir();
                let entry = servers.get(ctx.instanceId);
                if (!entry) {
                    const initialView =
                        ctx.input?.view === "activity" || ctx.input?.view === "feedback"
                            ? ctx.input.view
                            : "overview";
                    entry = await startServer(ctx.instanceId, initialView);
                    servers.set(ctx.instanceId, entry);
                }

                return {
                    title: "Autodev workflow",
                    status: directory ? "Live workspace state" : "No .autodev data found",
                    url: entry.url,
                };
            },
            onClose: async (ctx) => {
                const entry = servers.get(ctx.instanceId);
                if (!entry) {
                    return;
                }

                servers.delete(ctx.instanceId);
                await new Promise((resolve) => entry.server.close(resolve));
            },
        }),
    ],
});
