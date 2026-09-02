import { access, readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLAN_GATES = [
    { key: "architecture", label: "Architecture" },
    { key: "security", label: "Security" },
    { key: "privacy", label: "Privacy" },
];

const IMPLEMENT_GATES = [
    { key: "code-security-review", label: "Security" },
    { key: "code-privacy-review", label: "Privacy" },
];

function toPath(value) {
    return value instanceof URL ? fileURLToPath(value) : value;
}

async function exists(candidate) {
    try {
        await access(candidate);
        return true;
    } catch {
        return false;
    }
}

export async function locateAutodevDir(anchors) {
    for (const rawAnchor of anchors) {
        let current = path.resolve(toPath(rawAnchor));
        while (true) {
            const candidate = path.join(current, ".autodev");
            if (await exists(candidate)) {
                return candidate;
            }

            const parent = path.dirname(current);
            if (parent === current) {
                break;
            }
            current = parent;
        }
    }

    return null;
}

async function readOptional(filePath) {
    try {
        return (await readFile(filePath, "utf8")).replace(/^\uFEFF/, "");
    } catch (error) {
        if (error && typeof error === "object" && error.code === "ENOENT") {
            return null;
        }
        throw error;
    }
}

function parseJson(text, fileName, warnings) {
    if (!text) {
        return {};
    }

    try {
        return JSON.parse(text);
    } catch {
        warnings.push(`${fileName} is not valid JSON.`);
        return {};
    }
}

function splitTableRow(line) {
    return line
        .split("|")
        .slice(1, -1)
        .map((cell) => cell.trim());
}

function parseTable(text, requiredHeading) {
    if (!text) {
        return [];
    }

    const lines = text.split(/\r?\n/);
    let headerIndex = -1;
    for (let index = lines.length - 1; index >= 0; index -= 1) {
        const line = lines[index];
        if (line.startsWith("|") && line.toLowerCase().includes(requiredHeading)) {
            headerIndex = index;
            break;
        }
    }
    if (headerIndex < 0) {
        return [];
    }

    const headers = splitTableRow(lines[headerIndex]).map((header) => header.toLowerCase());
    const rows = [];
    for (let index = headerIndex + 2; index < lines.length; index += 1) {
        const line = lines[index];
        if (!line?.startsWith("|")) {
            break;
        }

        const values = splitTableRow(line);
        rows.push(Object.fromEntries(headers.map((header, cell) => [header, values[cell] ?? ""])));
    }
    return rows;
}

function asTimestamp(value) {
    if (!value || value === "-") {
        return null;
    }
    return value.includes("T") ? value : `${value.replace(" ", "T")}Z`;
}

function parsePlanEvents(text) {
    return parseTable(text, "gate").map((row) => ({
        time: asTimestamp(row["time (utc)"]),
        stage: row.gate,
        label: PLAN_GATES.find((gate) => gate.key === row.gate)?.label ?? row.gate,
        milestone: null,
        attempt: Number(row.attempt) || 0,
        event: row.event,
        verdict: row.verdict === "-" ? null : row.verdict,
        process: "plan",
    }));
}

function parseImplementEvents(text) {
    return parseTable(text, "stage").map((row) => ({
        time: asTimestamp(row["time (utc)"]),
        stage: row.stage,
        label: row.stage,
        milestone: row.milestone === "-" ? null : Number(row.milestone),
        attempt: Number(row.attempt) || 0,
        event: row.event,
        verdict: row.verdict === "-" ? null : row.verdict,
        process: "implementation",
    }));
}

function cleanSummary(value) {
    return value
        .replace(/\r?\n/g, " ")
        .replace(/[`*_]/g, "")
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, 900);
}

function latestSessionSection(text) {
    const sessions = [...text.matchAll(/^Session: `[^`\r\n]+`\s*$/gm)];
    return sessions.length > 0 ? text.slice(sessions.at(-1).index) : text;
}

function parseFeedback(text, process) {
    if (!text) {
        return [];
    }

    const sessionText = latestSessionSection(text);
    const headerPattern = /^# (.+?) - attempt (\d+) - ([A-Z]+)\s*$/gm;
    const matches = [...sessionText.matchAll(headerPattern)];
    return matches.map((match, index) => {
        const body = sessionText.slice(
            match.index,
            matches[index + 1]?.index ?? sessionText.length,
        );
        const descriptor = match[1];
        const milestoneMatch = descriptor.match(/^(.+?) \(milestone (\d+)\)$/);
        const stage = milestoneMatch?.[1] ?? descriptor;
        const summaryMatch = body.match(
            /## Summary\s+([\s\S]*?)(?=\r?\n## |\r?\nAUTODEV-VERDICT|$)/,
        );
        const findings = [...body.matchAll(/^### \[([^\]]+)\] (.+)$/gm)].map((finding) => ({
            severity: finding[1],
            title: finding[2].trim(),
        }));

        return {
            process,
            sequence: index + 1,
            stage,
            milestone: milestoneMatch ? Number(milestoneMatch[2]) : null,
            attempt: Number(match[2]),
            verdict: match[3],
            summary: summaryMatch ? cleanSummary(summaryMatch[1]) : "",
            findings,
        };
    });
}

function parseMilestones(text) {
    if (!text) {
        return [];
    }

    const pattern = /^## Milestone (\d+) [—-] (.+)$/gm;
    const matches = [...text.matchAll(pattern)];
    return matches.map((match, index) => {
        const body = text.slice(match.index, matches[index + 1]?.index ?? text.length);
        const status = body.match(/\*\*Status:\*\*\s*([^\r\n]+)/i)?.[1]?.trim() ?? "unknown";
        const tasks = [...body.matchAll(/^- \[([ xX])\]/gm)];
        return {
            number: Number(match[1]),
            title: match[2].trim(),
            declaredStatus: status,
            completedTasks: tasks.filter((task) => task[1].toLowerCase() === "x").length,
            taskCount: tasks.length,
        };
    });
}

function groupAttempts(events, feedback, stage, milestone = null) {
    const relevant = events.filter(
        (event) => event.stage === stage && event.milestone === milestone,
    );
    const runs = [];
    for (const event of relevant) {
        if (event.event === "invoked") {
            runs.push({
                attempt: event.attempt,
                startedAt: event.time,
                completedAt: null,
                verdict: "RUNNING",
            });
            continue;
        }

        if (event.event === "completed") {
            let run = [...runs]
                .reverse()
                .find(
                    (candidate) =>
                        candidate.attempt === event.attempt && candidate.completedAt === null,
                );
            if (!run) {
                run = {
                    attempt: event.attempt,
                    startedAt: null,
                    completedAt: null,
                    verdict: "RUNNING",
                };
                runs.push(run);
            }
            run.completedAt = event.time;
            run.verdict = event.verdict ?? "DONE";
        }
    }

    const matchingFeedback = feedback.filter(
        (entry) => entry.stage === stage && entry.milestone === milestone,
    );
    const usedFeedback = new Set();

    return runs.map((run) => {
        const feedbackIndex = matchingFeedback.findIndex(
            (entry, index) =>
                !usedFeedback.has(index) &&
                entry.attempt === run.attempt &&
                (entry.verdict === run.verdict || run.verdict === "RUNNING"),
        );
        if (feedbackIndex >= 0) {
            usedFeedback.add(feedbackIndex);
        }
        const feedbackEntry =
            feedbackIndex >= 0 ? matchingFeedback[feedbackIndex] : undefined;

        return {
            attempt: run.attempt,
            verdict: run.verdict ?? feedbackEntry?.verdict ?? "RUNNING",
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            durationMs:
                run.startedAt && run.completedAt
                    ? Math.max(0, Date.parse(run.completedAt) - Date.parse(run.startedAt))
                    : null,
            summary: feedbackEntry?.summary ?? "",
            findings: feedbackEntry?.findings ?? [],
        };
    });
}

function normalizeVerdict(verdict, fallback = "PENDING") {
    const normalized = String(verdict ?? "").trim().toUpperCase();
    return normalized || fallback;
}

function gateStatus(attempts, statusVerdict) {
    const latest = attempts.at(-1);
    const verdict = normalizeVerdict(latest?.verdict ?? statusVerdict);
    if (verdict === "PASS" || verdict === "DONE") {
        return "complete";
    }
    if (verdict === "RUNNING") {
        return "active";
    }
    if (verdict === "ISSUES") {
        return "issues";
    }
    if (verdict === "BLOCKED") {
        return "issues";
    }
    return "pending";
}

function buildPlan(events, feedback, status) {
    const gates = PLAN_GATES.map(({ key, label }) => {
        const attempts = groupAttempts(events, feedback, key);
        const verdict = normalizeVerdict(attempts.at(-1)?.verdict ?? status[`${key}Verdict`]);
        return {
            key,
            label,
            status: gateStatus(attempts, verdict),
            verdict,
            attempts,
            issueLoops: attempts.filter((attempt) => attempt.verdict === "ISSUES").length,
        };
    });

    const allPassed = gates.every((gate) => gate.status === "complete");
    const activeGate = gates.find((gate) => gate.status === "active");
    const issueGate = [...gates].reverse().find((gate) => gate.status === "issues");
    const hasStarted =
        events.length > 0 || gates.some((gate) => gate.status !== "pending");
    const currentPhase = allPassed
        ? "Complete"
        : activeGate
          ? `Gate: ${activeGate.label}`
          : issueGate
            ? `Draft refinement after ${issueGate.label}`
            : hasStarted
              ? "Gate review"
              : "Intake";

    const prereqsComplete = hasStarted;
    const phases = [
        { key: "intake", label: "Intake", status: prereqsComplete ? "complete" : "active" },
        { key: "clarify", label: "Clarify", status: prereqsComplete ? "complete" : "pending" },
        { key: "draft", label: "Draft", status: prereqsComplete ? "complete" : "pending" },
        { key: "approve", label: "Approve", status: prereqsComplete ? "complete" : "pending" },
        ...gates.map((gate) => ({
            key: gate.key,
            label: `Gate: ${gate.label}`,
            status: gate.status,
        })),
    ];

    return {
        status: allPassed ? "complete" : hasStarted ? "active" : "pending",
        currentPhase,
        sessionId: status.sessionId ?? null,
        startedAt: events[0]?.time ?? null,
        updatedAt: status.updatedAt ?? events.at(-1)?.time ?? null,
        phases,
        gates,
        events,
        feedback,
    };
}

function buildImplementation(events, feedback, status, milestoneData) {
    const auditMilestones = events
        .map((event) => event.milestone)
        .filter((milestone) => Number.isInteger(milestone));
    const milestoneCount = Math.max(
        Number(status.milestoneCount) || 0,
        ...milestoneData.map((milestone) => milestone.number),
        ...auditMilestones,
        0,
    );
    const statusCompletedMilestones = Number(status.completedMilestones) || 0;
    const cappedMilestones = new Set(
        String(status.cappedMilestones ?? "")
            .split(",")
            .map((milestone) => Number(milestone.trim()))
            .filter((milestone) => Number.isInteger(milestone) && milestone > 0),
    );

    const milestones = Array.from({ length: milestoneCount }, (_, index) => {
        const number = index + 1;
        const declared = milestoneData.find((milestone) => milestone.number === number);
        const implementationAttempts = groupAttempts(events, feedback, "implementation", number);
        const reviewAttempts = groupAttempts(events, feedback, "code-review", number);
        const fixAttempts = groupAttempts(events, feedback, "code-fix", number);
        const closedEvent = [...events].reverse().find(
            (event) =>
                event.stage === "milestone" &&
                event.milestone === number &&
                event.event.startsWith("milestone-closed"),
        );
        const auditedClosure = closedEvent?.event.match(/^milestone-closed \(([^)]+)\)$/)?.[1];
        const closure =
            auditedClosure ??
            (cappedMilestones.has(number)
                ? "capped"
                : number <= statusCompletedMilestones
                  ? "passed"
                  : null);
        const closed = closure !== null;
        const isCurrentMilestone = number === Number(status.currentMilestone);
        const statusImplementVerdict = isCurrentMilestone
            ? normalizeVerdict(status.implementVerdict, "")
            : "";
        const statusReviewVerdict = isCurrentMilestone
            ? normalizeVerdict(status.reviewVerdict, "")
            : "";
        const running = [...implementationAttempts, ...reviewAttempts, ...fixAttempts].some(
            (attempt) => normalizeVerdict(attempt.verdict) === "RUNNING",
        ) || statusImplementVerdict === "RUNNING" || statusReviewVerdict === "RUNNING";
        const hasIssues =
            normalizeVerdict(reviewAttempts.at(-1)?.verdict, "") === "ISSUES" ||
            statusReviewVerdict === "ISSUES";
        const blockedWorker = [implementationAttempts.at(-1), fixAttempts.at(-1)].some(
            (attempt) => normalizeVerdict(attempt?.verdict, "") === "BLOCKED",
        ) || statusImplementVerdict === "BLOCKED";
        const implementationStarted =
            implementationAttempts.length > 0 ||
            ["RUNNING", "DONE", "BLOCKED"].includes(statusImplementVerdict);

        return {
            number,
            title: declared?.title ?? `Milestone ${number}`,
            status: closure === "capped"
                ? "capped"
                : closed
                  ? "complete"
                : running
                  ? "active"
                  : hasIssues || blockedWorker
                    ? "issues"
                    : implementationStarted
                      ? "active"
                      : "pending",
            completedTasks: declared?.completedTasks ?? 0,
            taskCount: declared?.taskCount ?? 0,
            closure,
            implementationAttempts,
            reviewAttempts,
            fixAttempts,
            reviewLoops: reviewAttempts.filter((attempt) => attempt.verdict === "ISSUES").length,
        };
    });

    const gates = IMPLEMENT_GATES.map(({ key, label }) => {
        const attempts = groupAttempts(events, feedback, key);
        const statusKey = key === "code-security-review" ? "securityVerdict" : "privacyVerdict";
        const verdict = normalizeVerdict(attempts.at(-1)?.verdict ?? status[statusKey]);
        return {
            key,
            label,
            status: gateStatus(attempts, verdict),
            verdict,
            attempts,
            issueLoops: attempts.filter((attempt) => attempt.verdict === "ISSUES").length,
        };
    });

    const taskingAttempts = groupAttempts(events, feedback, "tasking");
    const taskingComplete =
        normalizeVerdict(taskingAttempts.at(-1)?.verdict, "") === "DONE" ||
        normalizeVerdict(status.taskingVerdict, "") === "DONE";
    const completedMilestones = milestones.filter((milestone) =>
        ["complete", "capped"].includes(milestone.status),
    ).length;
    const userReviewReached =
        Number(status.userReviewReached) > 0 ||
        events.some((event) => event.stage === "user-review");
    const statusHasStarted = [
        "taskingVerdict",
        "implementVerdict",
        "reviewVerdict",
        "securityVerdict",
        "privacyVerdict",
    ].some((key) => normalizeVerdict(status[key]) !== "PENDING");
    const hasStarted = events.length > 0 || statusHasStarted;
    const gatesStarted = gates.some((gate) => gate.status !== "pending");
    const allGatesPassed = gates.every((gate) => gate.status === "complete");
    const allComplete =
        taskingComplete &&
        milestoneCount > 0 &&
        completedMilestones === milestoneCount &&
        allGatesPassed;

    let currentPhase = "Intake";
    if (allComplete) {
        currentPhase = "Complete";
    } else {
        const activeGate = gates.find((gate) => gate.status === "active");
        const issueGate = [...gates].reverse().find((gate) => gate.status === "issues");
        const activeMilestone = milestones.find((milestone) =>
            ["active", "issues"].includes(milestone.status),
        );
        if (activeGate) {
            currentPhase = `Gate: ${activeGate.label}`;
        } else if (issueGate) {
            currentPhase = `Fixing ${issueGate.label} findings`;
        } else if (gatesStarted) {
            currentPhase = "Final gate review";
        } else if (userReviewReached) {
            currentPhase = "User approval";
        } else if (activeMilestone) {
            currentPhase = `Milestone ${activeMilestone.number}`;
        } else if (taskingComplete) {
            currentPhase = "Implementation";
        } else if (hasStarted) {
            currentPhase = "Tasking";
        }
    }

    const phases = [
        { key: "intake", label: "Intake", status: hasStarted ? "complete" : "active" },
        {
            key: "tasking",
            label: "Tasking",
            status: taskingComplete ? "complete" : hasStarted ? "active" : "pending",
        },
        {
            key: "milestones",
            label: `${completedMilestones}/${milestoneCount} milestones`,
            status:
                completedMilestones === milestoneCount && milestoneCount > 0
                    ? "complete"
                    : milestones.some((milestone) => milestone.status === "issues")
                      ? "issues"
                      : taskingComplete
                        ? "active"
                        : "pending",
        },
        {
            key: "approval",
            label: "User approval",
            status: gatesStarted ? "complete" : userReviewReached ? "active" : "pending",
        },
        ...gates.map((gate) => ({
            key: gate.key,
            label: `Gate: ${gate.label}`,
            status: gate.status,
        })),
    ];

    return {
        status: allComplete ? "complete" : hasStarted ? "active" : "pending",
        currentPhase,
        sessionId: status.sessionId ?? null,
        startedAt: events[0]?.time ?? null,
        updatedAt: status.updatedAt ?? events.at(-1)?.time ?? null,
        phases,
        milestones,
        completedMilestones,
        milestoneCount,
        taskingAttempts,
        userReviewReached,
        gates,
        events,
        feedback,
    };
}

function completedPhaseCount(phases) {
    return phases.filter((phase) => phase.status === "complete").length;
}

export async function loadAutodevState(autodevDir) {
    const warnings = [];
    const files = {
        planAudit: path.join(autodevDir, "gate-audit.md"),
        planStatus: path.join(autodevDir, "gate-status.json"),
        planFeedback: path.join(autodevDir, "feedback-log.md"),
        implementAudit: path.join(autodevDir, "implement-gate-audit.md"),
        implementStatus: path.join(autodevDir, "implement-status.json"),
        implementFeedback: path.join(autodevDir, "implement-feedback-log.md"),
        todos: path.join(autodevDir, "todos.md"),
    };

    const [
        planAuditText,
        planStatusText,
        planFeedbackText,
        implementAuditText,
        implementStatusText,
        implementFeedbackText,
        todosText,
    ] = await Promise.all(Object.values(files).map((filePath) => readOptional(filePath)));

    for (const [key, value] of Object.entries({
        "gate-audit.md": planAuditText,
        "implement-gate-audit.md": implementAuditText,
    })) {
        if (!value) {
            warnings.push(`${key} was not found.`);
        }
    }

    const planEvents = parsePlanEvents(planAuditText);
    const implementEvents = parseImplementEvents(implementAuditText);
    const plan = buildPlan(
        planEvents,
        parseFeedback(planFeedbackText, "plan"),
        parseJson(planStatusText, "gate-status.json", warnings),
    );
    const implementation = buildImplementation(
        implementEvents,
        parseFeedback(implementFeedbackText, "implementation"),
        parseJson(implementStatusText, "implement-status.json", warnings),
        parseMilestones(todosText),
    );

    const allPhases = [...plan.phases, ...implementation.phases];
    const completed = completedPhaseCount(allPhases);
    const total = allPhases.length;
    const workflowComplete = plan.status === "complete" && implementation.status === "complete";
    const workflowStatus = workflowComplete
        ? "complete"
        : plan.status === "pending" && implementation.status === "pending"
          ? "pending"
          : "active";
    const fileMetadata = await Promise.all(
        Object.entries(files).map(async ([name, filePath]) => {
            try {
                const details = await stat(filePath);
                return { name, modifiedAt: details.mtimeMs, size: details.size };
            } catch {
                return { name, modifiedAt: 0, size: -1 };
            }
        }),
    );
    const sourceUpdatedAt = Math.max(...fileMetadata.map((file) => file.modifiedAt), 0);

    return {
        generatedAt: new Date().toISOString(),
        sourceUpdatedAt: sourceUpdatedAt > 0 ? new Date(sourceUpdatedAt).toISOString() : null,
        sourceVersion: fileMetadata
            .map((file) => `${file.name}:${file.modifiedAt}:${file.size}`)
            .join("|"),
        workflow: {
            status: workflowStatus,
            label: workflowStatus === "complete"
                ? "Workflow complete"
                : workflowStatus === "active"
                  ? "Workflow in progress"
                  : "Workflow pending",
            percent: total > 0 ? Math.round((completed / total) * 100) : 0,
            completedPhases: completed,
            totalPhases: total,
            sessionId: plan.sessionId ?? implementation.sessionId,
        },
        plan,
        implementation,
        warnings,
    };
}
