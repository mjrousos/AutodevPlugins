function escapeAttribute(value) {
    return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll('"', "&quot;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;");
}

export function renderHtml({ instanceId, initialView }) {
    return `<!doctype html>
<html lang="en" data-instance-id="${escapeAttribute(instanceId)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Autodev workflow</title>
  <style>
    :root {
      color-scheme: light dark;
    }
    * {
      box-sizing: border-box;
    }
    body {
      margin: 0;
      background: var(--background-color-default, #fff);
      color: var(--text-color-default, #1f2328);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif);
      font-size: var(--text-body-medium, 14px);
      line-height: var(--leading-body-medium, 20px);
    }
    button {
      font: inherit;
    }
    .button-reset {
      width: 100%;
      border: 0;
      color: inherit;
      font: inherit;
      text-align: left;
    }
    .app {
      min-width: 320px;
      min-height: 100vh;
    }
    .header {
      position: sticky;
      z-index: 10;
      top: 0;
      padding: 16px 18px 12px;
      border-bottom: 1px solid var(--border-color-default, #d0d7de);
      background: color-mix(in srgb, var(--background-color-default, #fff) 94%, transparent);
      backdrop-filter: blur(12px);
    }
    .header-top, .status-line, .section-heading, .gate-heading, .milestone-heading {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }
    h1, h2, h3, p {
      margin: 0;
    }
    h1 {
      font-size: var(--text-title-large, 24px);
      line-height: var(--leading-title-large, 30px);
      font-weight: var(--font-weight-semibold, 600);
      letter-spacing: -0.02em;
    }
    h2 {
      font-size: var(--text-title-medium, 18px);
      line-height: var(--leading-title-medium, 24px);
      font-weight: var(--font-weight-semibold, 600);
    }
    h3 {
      font-size: var(--text-body-medium, 14px);
      line-height: 20px;
      font-weight: var(--font-weight-semibold, 600);
    }
    .eyebrow {
      color: var(--text-color-muted, #656d76);
      font-size: var(--text-body-small, 12px);
      font-weight: var(--font-weight-semibold, 600);
      letter-spacing: .08em;
      text-transform: uppercase;
    }
    .subtitle, .muted {
      color: var(--text-color-muted, #656d76);
    }
    .subtitle {
      margin-top: 4px;
    }
    .refresh {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      min-height: 32px;
      padding: 5px 10px;
      border: 1px solid var(--border-color-default, #d0d7de);
      border-radius: 7px;
      background: var(--background-color-default, #fff);
      color: var(--text-color-default, #1f2328);
      cursor: pointer;
    }
    .refresh:hover {
      background: color-mix(in srgb, var(--text-color-default, #1f2328) 6%, transparent);
    }
    .refresh:focus-visible, .tab:focus-visible {
      outline: 2px solid var(--color-focus-outline, #0969da);
      outline-offset: 2px;
    }
    .refresh[disabled] {
      cursor: wait;
      opacity: .65;
    }
    .status-line {
      margin-top: 14px;
    }
    .progress {
      overflow: hidden;
      flex: 1;
      height: 8px;
      border-radius: 999px;
      background: color-mix(in srgb, var(--text-color-muted, #656d76) 20%, transparent);
    }
    .progress > span {
      display: block;
      height: 100%;
      border-radius: inherit;
      background: var(--true-color-blue, #0969da);
      transition: width .25s ease;
    }
    .tabs {
      display: flex;
      gap: 4px;
      padding: 8px 18px 0;
      border-bottom: 1px solid var(--border-color-default, #d0d7de);
    }
    .tab {
      margin-bottom: -1px;
      padding: 9px 11px;
      border: 0;
      border-bottom: 2px solid transparent;
      background: transparent;
      color: var(--text-color-muted, #656d76);
      cursor: pointer;
    }
    .tab[aria-selected="true"] {
      border-bottom-color: var(--true-color-blue, #0969da);
      color: var(--text-color-default, #1f2328);
      font-weight: var(--font-weight-semibold, 600);
    }
    main {
      padding: 18px;
    }
    .stack {
      display: grid;
      gap: 18px;
    }
    .summary-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
    }
    .card {
      border: 1px solid var(--border-color-default, #d0d7de);
      border-radius: 10px;
      background: color-mix(in srgb, var(--background-color-default, #fff) 97%, var(--text-color-default, #1f2328));
      box-shadow: 0 1px 2px color-mix(in srgb, var(--text-color-default, #1f2328) 8%, transparent);
    }
    .summary-card {
      padding: 14px;
    }
    .summary-link {
      position: relative;
      cursor: pointer;
      transition: border-color .15s ease, transform .15s ease, box-shadow .15s ease;
    }
    .summary-link:hover {
      border-color: var(--true-color-blue, #0969da);
      box-shadow: 0 3px 10px color-mix(in srgb, var(--text-color-default, #1f2328) 12%, transparent);
      transform: translateY(-1px);
    }
    .summary-link:focus-visible, .back-link:focus-visible {
      outline: 2px solid var(--color-focus-outline, #0969da);
      outline-offset: 2px;
    }
    .summary-link::after {
      position: absolute;
      right: 14px;
      bottom: 13px;
      color: var(--true-color-blue, #0969da);
      content: "View audit log →";
      font-size: var(--text-body-small, 12px);
      font-weight: var(--font-weight-semibold, 600);
    }
    .summary-link .muted {
      padding-right: 100px;
    }
    .summary-value {
      margin-top: 4px;
      font-size: var(--text-title-medium, 18px);
      font-weight: var(--font-weight-semibold, 600);
    }
    .section {
      display: grid;
      gap: 10px;
    }
    .section-heading {
      align-items: end;
    }
    .flow {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(110px, 1fr));
      gap: 6px;
    }
    .phase {
      position: relative;
      min-height: 70px;
      padding: 10px;
      border: 1px solid var(--border-color-default, #d0d7de);
      border-radius: 8px;
      background: var(--background-color-default, #fff);
    }
    .phase:not(:last-child)::after {
      position: absolute;
      z-index: 2;
      top: 50%;
      right: -7px;
      width: 7px;
      height: 2px;
      background: var(--border-color-default, #d0d7de);
      content: "";
    }
    .phase-title {
      display: block;
      margin-top: 5px;
      font-weight: var(--font-weight-semibold, 600);
    }
    .icon {
      display: inline-grid;
      width: 20px;
      height: 20px;
      place-items: center;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
    }
    .complete .icon {
      background: color-mix(in srgb, var(--true-color-blue, #0969da) 16%, transparent);
      color: var(--true-color-blue, #0969da);
    }
    .badge.complete {
      background: color-mix(in srgb, var(--true-color-green, #1a7f37) 15%, transparent);
      color: var(--true-color-green, #1a7f37);
    }
    .active .icon, .badge.active {
      background: color-mix(in srgb, var(--true-color-blue, #0969da) 16%, transparent);
      color: var(--true-color-blue, #0969da);
    }
    .issues .icon, .badge.issues {
      background: color-mix(in srgb, var(--true-color-red, #cf222e) 15%, transparent);
      color: var(--true-color-red, #cf222e);
    }
    .capped .icon, .badge.capped {
      background: color-mix(in srgb, var(--true-color-red, #cf222e) 15%, transparent);
      color: var(--true-color-red, #cf222e);
    }
    .pending .icon, .badge.pending {
      background: color-mix(in srgb, var(--text-color-muted, #656d76) 14%, transparent);
      color: var(--text-color-muted, #656d76);
    }
    .badge {
      display: inline-flex;
      align-items: center;
      width: fit-content;
      min-height: 22px;
      padding: 1px 8px;
      border-radius: 999px;
      font-size: var(--text-body-small, 12px);
      font-weight: var(--font-weight-semibold, 600);
      white-space: nowrap;
    }
    .gate-grid, .milestone-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 10px;
    }
    .gate, .milestone {
      padding: 13px;
    }
    .attempts {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
      margin-top: 10px;
    }
    .attempt {
      padding: 2px 7px;
      border: 1px solid var(--border-color-default, #d0d7de);
      border-radius: 999px;
      color: var(--text-color-muted, #656d76);
      font-size: var(--text-body-small, 12px);
    }
    .attempt[data-verdict="PASS"], .attempt[data-verdict="DONE"] {
      border-color: color-mix(in srgb, var(--true-color-green, #1a7f37) 45%, var(--border-color-default, #d0d7de));
      color: var(--true-color-green, #1a7f37);
    }
    .attempt[data-verdict="ISSUES"] {
      border-color: color-mix(in srgb, var(--true-color-red, #cf222e) 45%, var(--border-color-default, #d0d7de));
      color: var(--true-color-red, #cf222e);
    }
    .metric {
      margin-top: 7px;
      color: var(--text-color-muted, #656d76);
      font-size: var(--text-body-small, 12px);
    }
    .mini-progress {
      overflow: hidden;
      height: 5px;
      margin-top: 9px;
      border-radius: 999px;
      background: color-mix(in srgb, var(--text-color-muted, #656d76) 18%, transparent);
    }
    .mini-progress span {
      display: block;
      height: 100%;
      background: var(--true-color-blue, #0969da);
    }
    .notice {
      padding: 11px 13px;
      border: 1px solid color-mix(in srgb, var(--true-color-red, #cf222e) 35%, var(--border-color-default, #d0d7de));
      border-radius: 8px;
      background: color-mix(in srgb, var(--true-color-red-muted, #ffebe9) 35%, transparent);
    }
    .activity-table {
      overflow-x: auto;
    }
    .audit-header {
      display: grid;
      gap: 8px;
    }
    .back-link {
      display: inline-flex;
      align-items: center;
      width: fit-content;
      padding: 3px 0;
      border: 0;
      background: transparent;
      color: var(--true-color-blue, #0969da);
      cursor: pointer;
      font-weight: var(--font-weight-semibold, 600);
    }
    .source-path {
      width: fit-content;
      max-width: 100%;
      padding: 3px 7px;
      border-radius: 5px;
      background: color-mix(in srgb, var(--text-color-muted, #656d76) 10%, transparent);
      overflow-wrap: anywhere;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: var(--text-body-small, 12px);
    }
    th, td {
      padding: 9px 8px;
      border-bottom: 1px solid var(--border-color-default, #d0d7de);
      text-align: left;
      vertical-align: top;
    }
    th {
      color: var(--text-color-muted, #656d76);
      font-weight: var(--font-weight-semibold, 600);
    }
    code {
      font-family: var(--font-mono, Consolas, monospace);
      font-size: var(--text-code-inline, 12px);
    }
    .feedback-list {
      display: grid;
      gap: 10px;
    }
    details {
      padding: 12px 13px;
    }
    summary {
      cursor: pointer;
      font-weight: var(--font-weight-semibold, 600);
    }
    details p {
      margin-top: 9px;
      color: var(--text-color-muted, #656d76);
    }
    .findings {
      display: grid;
      gap: 5px;
      margin: 10px 0 0;
      padding: 0;
      list-style: none;
    }
    .finding {
      padding-left: 10px;
      border-left: 3px solid var(--true-color-red, #cf222e);
    }
    .empty, .loading, .error {
      display: grid;
      min-height: 240px;
      place-items: center;
      color: var(--text-color-muted, #656d76);
      text-align: center;
    }
    .spinner {
      width: 20px;
      height: 20px;
      margin: 0 auto 8px;
      border: 2px solid color-mix(in srgb, var(--text-color-muted, #656d76) 25%, transparent);
      border-top-color: var(--true-color-blue, #0969da);
      border-radius: 50%;
      animation: spin .8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (max-width: 620px) {
      .summary-grid {
        grid-template-columns: 1fr;
      }
      .header-top {
        align-items: flex-start;
      }
      .refresh-label {
        display: none;
      }
      .flow {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
      .phase::after {
        display: none;
      }
    }
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after {
        scroll-behavior: auto !important;
        animation-duration: .01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: .01ms !important;
      }
    }
  </style>
</head>
<body data-initial-view="${escapeAttribute(initialView)}">
  <div class="app">
    <header class="header">
      <div class="header-top">
        <div>
          <div class="eyebrow">Feature delivery</div>
          <h1>Autodev workflow</h1>
          <p class="subtitle" id="workflow-subtitle">Reading .autodev state…</p>
        </div>
        <button class="refresh" id="refresh" type="button" title="Reload from .autodev">
          <span aria-hidden="true">↻</span><span class="refresh-label">Refresh</span>
        </button>
      </div>
      <div class="status-line">
        <span class="badge pending" id="workflow-badge">Loading</span>
        <div class="progress" aria-label="Workflow progress"><span id="workflow-progress" style="width:0%"></span></div>
        <strong id="workflow-percent">0%</strong>
      </div>
    </header>
    <nav class="tabs" aria-label="Workflow views">
      <button class="tab" type="button" data-view="overview">Overview</button>
      <button class="tab" type="button" data-view="activity">Activity</button>
      <button class="tab" type="button" data-view="feedback">Feedback</button>
    </nav>
    <main id="content">
      <div class="loading"><div><div class="spinner"></div>Loading workflow state…</div></div>
    </main>
  </div>
  <script>
    const state = {
      data: null,
      view: document.body.dataset.initialView || "overview",
      auditKind: null,
      loading: false,
      renderFailed: false,
    };

    const content = document.getElementById("content");
    const refreshButton = document.getElementById("refresh");
    const badge = document.getElementById("workflow-badge");
    const subtitle = document.getElementById("workflow-subtitle");
    const progress = document.getElementById("workflow-progress");
    const percent = document.getElementById("workflow-percent");
    const tabs = [...document.querySelectorAll(".tab")];

    function node(tag, className, text) {
      const element = document.createElement(tag);
      if (className) element.className = className;
      if (text !== undefined && text !== null) element.textContent = String(text);
      return element;
    }

    function badgeNode(status, text) {
      return node("span", "badge " + status, text);
    }

    function statusLabel(status) {
      return {
        complete: "Complete",
        active: "In progress",
        issues: "Needs refinement",
        capped: "Closed with findings",
        pending: "Pending",
      }[status] || status;
    }

    function iconFor(status) {
      return { complete: "✓", active: "●", issues: "!", capped: "!", pending: "·" }[status] || "·";
    }

    function formatDate(value) {
      if (!value) return "—";
      const date = new Date(value);
      return Number.isNaN(date.valueOf())
        ? value
        : new Intl.DateTimeFormat(undefined, {
            month: "short",
            day: "numeric",
            hour: "numeric",
            minute: "2-digit",
          }).format(date);
    }

    function formatDuration(ms) {
      if (ms === null || ms === undefined) return "";
      const minutes = Math.max(1, Math.round(ms / 60000));
      if (minutes < 60) return minutes + "m";
      const hours = Math.floor(minutes / 60);
      return hours + "h " + (minutes % 60) + "m";
    }

    function phaseFlow(phases) {
      const flow = node("div", "flow");
      phases.forEach((phase) => {
        const item = node("div", "phase " + phase.status);
        item.append(node("span", "icon", iconFor(phase.status)));
        item.append(node("span", "phase-title", phase.label));
        item.append(node("span", "muted", statusLabel(phase.status)));
        flow.append(item);
      });
      return flow;
    }

    function attemptsList(attempts) {
      const list = node("div", "attempts");
      if (!attempts.length) {
        list.append(node("span", "muted", "Not started"));
        return list;
      }
      attempts.forEach((attempt) => {
        const label = "#" + attempt.attempt + " " + attempt.verdict +
          (attempt.durationMs !== null ? " · " + formatDuration(attempt.durationMs) : "");
        const item = node("span", "attempt", label);
        item.dataset.verdict = attempt.verdict;
        list.append(item);
      });
      return list;
    }

    function sectionHeading(title, detail) {
      const heading = node("div", "section-heading");
      const left = node("div");
      left.append(node("h2", "", title));
      if (detail) left.append(node("p", "muted", detail));
      heading.append(left);
      return heading;
    }

    function gateCards(gates) {
      const grid = node("div", "gate-grid");
      gates.forEach((gate) => {
        const card = node("article", "card gate");
        const heading = node("div", "gate-heading");
        heading.append(node("h3", "", gate.label));
        heading.append(badgeNode(gate.status, gate.verdict));
        card.append(heading);
        const metric = gate.issueLoops
          ? gate.issueLoops + " refinement loop" + (gate.issueLoops === 1 ? "" : "s")
          : gate.attempts.length + " attempt" + (gate.attempts.length === 1 ? "" : "s");
        card.append(node("p", "metric", metric));
        card.append(attemptsList(gate.attempts));
        grid.append(card);
      });
      return grid;
    }

    function processSection(title, process) {
      const section = node("section", "section");
      section.append(sectionHeading(title, "Current phase: " + process.currentPhase));
      section.append(phaseFlow(process.phases));
      return section;
    }

    function overview(data) {
      const root = node("div", "stack");
      if (data.warnings.length) {
        const warning = node("div", "notice");
        warning.append(node("strong", "", "Data warning"));
        warning.append(node("p", "", data.warnings.join(" ")));
        root.append(warning);
      }

      const summaries = node("div", "summary-grid");
      const planSummary = node("button", "card summary-card summary-link button-reset");
      planSummary.type = "button";
      planSummary.dataset.audit = "plan";
      planSummary.dataset.focusKey = "audit-link:plan";
      planSummary.setAttribute("aria-label", "View autodev plan audit log");
      planSummary.append(node("div", "eyebrow", "Autodev plan"));
      planSummary.append(node("div", "summary-value", data.plan.currentPhase));
      planSummary.append(node("p", "muted", data.plan.gates.reduce((sum, gate) => sum + gate.issueLoops, 0) + " refinement loops"));
      summaries.append(planSummary);

      const implementSummary = node("button", "card summary-card summary-link button-reset");
      implementSummary.type = "button";
      implementSummary.dataset.audit = "implementation";
      implementSummary.dataset.focusKey = "audit-link:implementation";
      implementSummary.setAttribute("aria-label", "View autodev implementation audit log");
      implementSummary.append(node("div", "eyebrow", "Autodev implement"));
      implementSummary.append(node("div", "summary-value", data.implementation.currentPhase));
      implementSummary.append(node("p", "muted", data.implementation.completedMilestones + " of " + data.implementation.milestoneCount + " milestones complete"));
      summaries.append(implementSummary);
      root.append(summaries);

      root.append(processSection("Plan", data.plan));
      const planGates = node("section", "section");
      planGates.append(sectionHeading("Plan validation gates", "Issues return the workflow to draft refinement."));
      planGates.append(gateCards(data.plan.gates));
      root.append(planGates);

      root.append(processSection("Implementation", data.implementation));
      const milestones = node("section", "section");
      milestones.append(sectionHeading("Milestones", "Implementation, review, and fix loops for each delivery unit."));
      const milestoneGrid = node("div", "milestone-grid");
      data.implementation.milestones.forEach((milestone) => {
        const card = node("article", "card milestone");
        const heading = node("div", "milestone-heading");
        const title = node("div");
        title.append(node("div", "eyebrow", "Milestone " + milestone.number));
        title.append(node("h3", "", milestone.title));
        heading.append(title);
        heading.append(badgeNode(milestone.status, statusLabel(milestone.status)));
        card.append(heading);

        const taskPercent = milestone.taskCount
          ? Math.round((milestone.completedTasks / milestone.taskCount) * 100)
          : milestone.status === "complete" ? 100 : 0;
        card.append(node("p", "metric", milestone.completedTasks + "/" + milestone.taskCount + " tasks · " +
          milestone.reviewAttempts.length + " review" + (milestone.reviewAttempts.length === 1 ? "" : "s") +
          (milestone.reviewLoops ? " · " + milestone.reviewLoops + " fix loop" + (milestone.reviewLoops === 1 ? "" : "s") : "")));
        const mini = node("div", "mini-progress");
        const fill = node("span");
        fill.style.width = taskPercent + "%";
        mini.append(fill);
        card.append(mini);
        card.append(attemptsList(milestone.reviewAttempts));
        milestoneGrid.append(card);
      });
      milestones.append(milestoneGrid);
      root.append(milestones);

      const finalGates = node("section", "section");
      finalGates.append(sectionHeading("Implementation validation gates", "Security and privacy findings trigger code-fix loops."));
      finalGates.append(gateCards(data.implementation.gates));
      root.append(finalGates);
      return root;
    }

    function auditLog(data, kind) {
      const process = kind === "implementation" ? data.implementation : data.plan;
      const processLabel = kind === "implementation" ? "Autodev implement" : "Autodev plan";
      const fileName = kind === "implementation" ? "implement-gate-audit.md" : "gate-audit.md";
      const root = node("div", "stack");
      const header = node("div", "audit-header");
      const back = node("button", "back-link", "← Back to overview");
      back.type = "button";
      back.dataset.backOverview = "true";
      back.dataset.focusKey = "audit-back:" + kind;
      header.append(back);
      header.append(node("div", "eyebrow", processLabel));
      header.append(node("h2", "", "Audit log"));
      header.append(node("p", "muted", "Read-only lifecycle events captured by autodev hooks."));
      header.append(node("code", "source-path", ".autodev/" + fileName));
      root.append(header);

      const summary = node("div", "summary-grid");
      const statusCard = node("article", "card summary-card");
      statusCard.append(node("div", "eyebrow", "Status"));
      statusCard.append(node("div", "summary-value", process.currentPhase));
      statusCard.append(badgeNode(process.status, statusLabel(process.status)));
      summary.append(statusCard);
      const eventCard = node("article", "card summary-card");
      eventCard.append(node("div", "eyebrow", "Audit events"));
      eventCard.append(node("div", "summary-value", process.events.length));
      eventCard.append(node("p", "muted", "Updated " + formatDate(process.updatedAt)));
      summary.append(eventCard);
      root.append(summary);

      if (!process.events.length) {
        root.append(node("div", "empty", "No audit events found in " + fileName + "."));
        return root;
      }

      const wrapper = node("div", "card activity-table");
      const table = node("table");
      const head = node("thead");
      const headRow = node("tr");
      const labels = kind === "implementation"
        ? ["Time", "Stage", "Milestone", "Attempt", "Event", "Verdict"]
        : ["Time", "Gate", "Attempt", "Event", "Verdict"];
      labels.forEach((label) => headRow.append(node("th", "", label)));
      head.append(headRow);
      table.append(head);
      const body = node("tbody");
      process.events.forEach((event) => {
        const row = node("tr");
        const values = kind === "implementation"
          ? [
              formatDate(event.time),
              event.stage,
              event.milestone ?? "—",
              event.attempt || "—",
              event.event,
              event.verdict || "—",
            ]
          : [
              formatDate(event.time),
              event.label,
              event.attempt || "—",
              event.event,
              event.verdict || "—",
            ];
        values.forEach((value) => row.append(node("td", "", value)));
        body.append(row);
      });
      table.append(body);
      wrapper.append(table);
      root.append(wrapper);
      return root;
    }

    function activity(data) {
      const root = node("div", "stack");
      root.append(sectionHeading("Activity", "Hook-observed lifecycle events, newest first."));
      const events = [...data.plan.events, ...data.implementation.events]
        .sort((left, right) => Date.parse(right.time || 0) - Date.parse(left.time || 0));
      if (!events.length) return node("div", "empty", "No audit events found.");

      const wrapper = node("div", "card activity-table");
      const table = node("table");
      const head = node("thead");
      const headRow = node("tr");
      ["Time", "Process", "Stage", "Attempt", "Event", "Verdict"].forEach((label) =>
        headRow.append(node("th", "", label)));
      head.append(headRow);
      table.append(head);
      const body = node("tbody");
      events.forEach((event) => {
        const row = node("tr");
        const stage = event.milestone ? event.stage + " · M" + event.milestone : event.stage;
        [
          formatDate(event.time),
          event.process === "plan" ? "Plan" : "Implement",
          stage,
          event.attempt || "—",
          event.event,
          event.verdict || "—",
        ].forEach((value) => row.append(node("td", "", value)));
        body.append(row);
      });
      table.append(body);
      wrapper.append(table);
      root.append(wrapper);
      return root;
    }

    function feedback(data) {
      const root = node("div", "stack");
      root.append(sectionHeading("Reviewer feedback", "Captured sub-agent summaries and findings by attempt."));
      const entries = [...data.plan.feedback, ...data.implementation.feedback]
        .filter((entry) => entry.summary || entry.findings.length)
        .reverse();
      if (!entries.length) return node("div", "empty", "No reviewer feedback found.");

      const list = node("div", "feedback-list");
      entries.forEach((entry) => {
        const item = node("details", "card");
        const feedbackKey = entry.process + ":" + entry.sequence;
        item.dataset.feedbackKey = feedbackKey;
        const milestone = entry.milestone ? " · Milestone " + entry.milestone : "";
        const summary = node("summary", "", entry.stage + milestone + " · Attempt " + entry.attempt + " · " + entry.verdict);
        summary.dataset.focusKey = "feedback:" + feedbackKey;
        item.append(summary);
        if (entry.summary) item.append(node("p", "", entry.summary));
        if (entry.findings.length) {
          const findings = node("ul", "findings");
          entry.findings.forEach((finding) => {
            const li = node("li", "finding");
            li.append(node("strong", "", finding.severity.toUpperCase() + " "));
            li.append(document.createTextNode(finding.title));
            findings.append(li);
          });
          item.append(findings);
        }
        list.append(item);
      });
      root.append(list);
      return root;
    }

    function render() {
      tabs.forEach((tab) => {
        const selected = tab.dataset.view === state.view;
        tab.setAttribute("aria-selected", String(selected));
      });
      if (!state.data) return;
      const view = state.view === "audit"
        ? auditLog(state.data, state.auditKind)
        : state.view === "activity"
        ? activity(state.data)
        : state.view === "feedback"
          ? feedback(state.data)
          : overview(state.data);
      content.replaceChildren(view);
    }

    function renderHeader(data) {
      badge.className = "badge " + data.workflow.status;
      badge.textContent = data.workflow.label;
      subtitle.textContent = data.workflow.sessionId
        ? "Session " + data.workflow.sessionId.slice(0, 8) + " · source updated " + formatDate(data.sourceUpdatedAt)
        : "Source updated " + formatDate(data.sourceUpdatedAt);
      progress.style.width = data.workflow.percent + "%";
      percent.textContent = data.workflow.percent + "%";
    }

    function scrollViewToTop() {
      if (document.scrollingElement) {
        document.scrollingElement.scrollTop = 0;
      }
      window.scrollTo(0, 0);
      requestAnimationFrame(() => window.scrollTo(0, 0));
    }

    function captureRenderedState() {
      const activeElement = document.activeElement;
      const table = content.querySelector(".activity-table");
      return {
        focusKey: activeElement?.dataset?.focusKey || null,
        openFeedback: [...content.querySelectorAll("details[open][data-feedback-key]")]
          .map((details) => details.dataset.feedbackKey),
        tableScrollLeft: table?.scrollLeft ?? 0,
        windowScrollX: window.scrollX,
        windowScrollY: window.scrollY,
      };
    }

    function restoreRenderedState(snapshot) {
      const openFeedback = new Set(snapshot.openFeedback);
      content.querySelectorAll("details[data-feedback-key]").forEach((details) => {
        details.open = openFeedback.has(details.dataset.feedbackKey);
      });

      if (snapshot.focusKey) {
        const focusTarget = [...content.querySelectorAll("[data-focus-key]")]
          .find((element) => element.dataset.focusKey === snapshot.focusKey);
        focusTarget?.focus({ preventScroll: true });
      }

      const restoreScroll = () => {
        const table = content.querySelector(".activity-table");
        if (table) {
          table.scrollLeft = snapshot.tableScrollLeft;
        }
        window.scrollTo(snapshot.windowScrollX, snapshot.windowScrollY);
      };
      restoreScroll();
      requestAnimationFrame(restoreScroll);
    }

    async function load(endpoint = "/api/state") {
      if (state.loading) return;
      state.loading = true;
      refreshButton.disabled = true;
      try {
        const response = await fetch(endpoint, { method: endpoint.includes("refresh") ? "POST" : "GET" });
        const body = await response.json();
        if (!response.ok) throw new Error(body.error || "Unable to load workflow state.");
        if (!state.renderFailed && state.data?.sourceVersion === body.sourceVersion) {
          return;
        }
        const renderedState = state.data ? captureRenderedState() : null;
        state.data = body;
        renderHeader(body);
        render();
        if (renderedState) {
          restoreRenderedState(renderedState);
        }
        state.renderFailed = false;
      } catch (error) {
        state.renderFailed = true;
        const message = error instanceof Error ? error.message : "Unable to load workflow state.";
        const errorView = node("div", "error");
        const box = node("div");
        box.append(node("strong", "", "Workflow data unavailable"));
        box.append(node("p", "muted", message));
        errorView.append(box);
        content.replaceChildren(errorView);
        badge.className = "badge issues";
        badge.textContent = "Unavailable";
        subtitle.textContent = message;
      } finally {
        state.loading = false;
        refreshButton.disabled = false;
      }
    }

    tabs.forEach((tab) => tab.addEventListener("click", () => {
      state.view = tab.dataset.view;
      state.auditKind = null;
      render();
    }));
    content.addEventListener("click", (event) => {
      const auditLink = event.target.closest("[data-audit]");
      if (auditLink) {
        state.auditKind = auditLink.dataset.audit;
        state.view = "audit";
        render();
        scrollViewToTop();
        return;
      }

      if (event.target.closest("[data-back-overview]")) {
        state.auditKind = null;
        state.view = "overview";
        render();
        scrollViewToTop();
      }
    });
    refreshButton.addEventListener("click", () => load("/api/refresh"));
    load();
    setInterval(() => load(), 15000);
  </script>
</body>
</html>`;
}
