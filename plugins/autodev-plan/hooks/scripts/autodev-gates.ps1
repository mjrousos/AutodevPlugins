<#
.SYNOPSIS
    Gate tracker for the autodev-plan plugin (Windows / PowerShell).

.DESCRIPTION
    Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
    writes exactly one JSON object to stdout.

    Responsibilities:
      * subagentStart - record that a review gate was invoked; increment its attempt counter.
      * subagentStop  - parse the reviewer's verdict, record it, log the reviewer's full
                        feedback, and append a tracker footer to the response the orchestrator
                        receives.
      * agentStop     - block the orchestrator from ending its turn while gates are outstanding.
      * preToolUse    - deny ask_user while gating, so the gate phase stays autonomous, and deny
                        further reviewer invocations once the attempt budget is spent.

    Enforcement state lives at '<COPILOT_HOME>/autodev-plan/gates/<sessionId>.json', outside the
    workspace and keyed by session. That matters for two reasons: concurrent sessions in one
    repository must not clobber each other's attempt counters, and the orchestrator is allowed to
    edit files in the workspace, so state it could rewrite would not be enforcement at all.

    A mirror of that state, the audit trail and the reviewer feedback log are written into
    '<session cwd>/.autodev/' so a developer can watch a run in progress and read the reviews
    afterwards, next to the plan the gates are reviewing. Those three files are a *view*: nothing
    reads them back, so tampering with them cannot weaken a gate.

    SAFETY: preToolUse command hooks are fail-closed - any non-zero exit or crash denies the
    tool call. A bug here would permanently break ask_user for the user, so every path is
    wrapped and this script always emits valid JSON and always exits 0.

    Written for Windows PowerShell 5.1 compatibility (no -AsHashtable, no ternaries, no
    three-argument Join-Path).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('subagentStart', 'subagentStop', 'agentStop', 'preToolUse')]
    [string]$EventName
)

$ErrorActionPreference = 'Stop'

# Gate evaluation order. Also the order the orchestrator must run them in.
$script:GateOrder = @('architecture', 'security', 'privacy')
# Per gate, per pass. A gate that is re-run after previously passing starts a fresh budget.
$script:MaxAttempts = 10
# Kept below the CLI's own 8-block runaway guard so we surrender first.
$script:MaxBlocks = 5
# Absolute ceiling across all gates and all re-gate passes. Because a re-gate resets a gate's
# per-pass budget, this is what makes an unbounded re-gate cascade impossible. Must stay above
# GateOrder.Count * MaxAttempts, or it would fire before a single pass could spend the per-gate
# budget and would silently become the real limit.
$script:MaxTotalInvocations = 40

function Get-StateDirectory {
    # Enforcement state stays outside the workspace, keyed by session id. Two sessions running
    # in the same repository must not share a state file, and the orchestrator must not be able
    # to edit its way past a gate.
    #
    # This resolves a path but deliberately does NOT create anything; see Confirm-Directory.
    $home_ = $env:COPILOT_HOME
    if ([string]::IsNullOrWhiteSpace($home_)) {
        $profileDir = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileDir)) { $profileDir = $HOME }
        $home_ = Join-Path $profileDir '.copilot'
    }
    return (Join-Path (Join-Path $home_ 'autodev-plan') 'gates')
}

function Get-ViewDirectory {
    # Where the developer-facing artifacts go: '.autodev' beside the plan the gates are
    # reviewing. Returns an empty string when there is no usable working directory, in which
    # case the caller falls back to the state directory.
    param([string]$Cwd)
    if (-not [string]::IsNullOrWhiteSpace($Cwd) -and (Test-Path -LiteralPath $Cwd -PathType Container)) {
        return (Join-Path $Cwd '.autodev')
    }
    return ''
}

function Confirm-Directory {
    # Called only once a real review gate has been identified, so directories appear exactly
    # when the workflow starts using them. Creating them on every hook event would litter an
    # empty '.autodev' into any repository where an unrelated session called the task tool.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (Test-Path -LiteralPath $Path) { return $true }
    try {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-SafeSessionId {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return 'unknown-session' }
    # Defend against path traversal via a hostile session id.
    return ($SessionId -replace '[^A-Za-z0-9._-]', '_')
}

function New-DefaultState {
    param([string]$SessionId)
    $state = @{
        sessionId        = $SessionId
        createdAt        = (Get-Date).ToUniversalTime().ToString('o')
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        blocks           = 0
        totalInvocations = 0
    }
    foreach ($gate in $script:GateOrder) {
        $state["${gate}Attempts"] = 0
        $state["${gate}Verdict"] = 'pending'
    }
    return $state
}

function Read-State {
    param([string]$Path, [string]$SessionId)
    $state = New-DefaultState -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        # Corrupt or unreadable state is treated as absent. Never fatal.
        return $state
    }
    # State is keyed by session id in its filename, so a mismatch should be impossible. Require
    # an exact match anyway: adopting a file whose owner is unknown or missing would let a
    # hand-edited or truncated file drive enforcement in a session it has nothing to do with.
    $ownerProp = $parsed.PSObject.Properties['sessionId']
    if ($null -eq $ownerProp -or [string]$ownerProp.Value -ne $SessionId) {
        return $state
    }
    foreach ($key in @($state.Keys)) {
        $prop = $parsed.PSObject.Properties[$key]
        if ($null -ne $prop -and $null -ne $prop.Value) {
            $state[$key] = $prop.Value
        }
    }
    # Normalize numeric fields that may have round-tripped as strings.
    $state['blocks'] = [int]$state['blocks']
    $state['totalInvocations'] = [int]$state['totalInvocations']
    foreach ($gate in $script:GateOrder) {
        $state["${gate}Attempts"] = [int]$state["${gate}Attempts"]
    }
    return $state
}

function Write-State {
    param([hashtable]$State, [string]$Path, [string]$MirrorPath)
    $State['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $json = $State | ConvertTo-Json -Depth 5
    # Write then rename, so a concurrent reader never observes a half-written file. A torn read
    # would be treated as absent state, which would silently switch enforcement off.
    $tmp = "$Path.$PID.tmp"
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        # If the rename failed (for example a transient lock) the temp file would otherwise be
        # orphaned in the gates directory, so clean it up unconditionally.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    # Best-effort human-facing copy. Nothing ever reads this back, so a failure here must not
    # affect enforcement.
    if (-not [string]::IsNullOrWhiteSpace($MirrorPath)) {
        try { Set-Content -LiteralPath $MirrorPath -Value $json -Encoding UTF8 -ErrorAction Stop }
        catch { }
    }
}

function Add-AuditRow {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Gate,
        [int]$Attempt,
        [string]$Action,
        [string]$Verdict
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        $header = @(
            '# autodev-plan review gate audit',
            '',
            "Session: ``$SessionId``",
            "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
            '',
            'Every row below was written by a hook observing a real sub-agent lifecycle event.',
            'The orchestrator cannot write to this file.',
            '',
            '| Time (UTC) | Gate | Attempt | Event | Verdict |',
            '| --- | --- | --- | --- | --- |'
        )
        Set-Content -LiteralPath $Path -Value ($header -join [Environment]::NewLine) -Encoding UTF8
    }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -LiteralPath $Path -Value "| $ts | $Gate | $Attempt | $Action | $Verdict |" -Encoding UTF8
}

function Add-FeedbackEntry {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Gate,
        [int]$Attempt,
        [string]$Verdict,
        [string]$Response
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        $header = @(
            '# autodev-plan reviewer feedback log',
            '',
            "Session: ``$SessionId``",
            "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
            '',
            'Each entry is the reviewer sub-agent''s verbatim response, captured by a hook as the',
            'sub-agent finished. The orchestrator cannot edit this file, so it records what the',
            'reviewers actually said rather than what the orchestrator chose to relay.'
        )
        Set-Content -LiteralPath $Path -Value ($header -join [Environment]::NewLine) -Encoding UTF8
    }
    $ts = (Get-Date).ToUniversalTime().ToString('u')
    if ([string]::IsNullOrWhiteSpace($Response)) { $Response = '_(the reviewer returned no content)_' }
    $entry = @(
        '',
        '---',
        '',
        # Level 1: reviewers use '##' and '###' for their own sections, so an entry header at
        # the same level would be indistinguishable from the content it introduces.
        "# $Gate - attempt $Attempt - $Verdict",
        '',
        # Braces are required: "$ts_" would be parsed as a variable named 'ts_'.
        "_${ts}_",
        '',
        $Response.TrimEnd()
    )
    Add-Content -LiteralPath $Path -Value ($entry -join [Environment]::NewLine) -Encoding UTF8
}

function Resolve-Gate {
    param([string]$AgentName)
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return $null }
    # agentName arrives namespaced, e.g. "autodev-plan:autodev-privacy-review".
    if ($AgentName -match 'autodev-(architecture|security|privacy)-review\s*$') {
        return $Matches[1]
    }
    return $null
}

function Get-TaskAgentType {
    param($ToolArgs)
    # toolArgs arrives as a JSON *string* rather than an object, so it needs a second parse.
    if ($null -eq $ToolArgs) { return '' }
    try {
        if ($ToolArgs -is [string]) {
            if ([string]::IsNullOrWhiteSpace($ToolArgs)) { return '' }
            $parsed = $ToolArgs | ConvertFrom-Json -ErrorAction Stop
        }
        else {
            $parsed = $ToolArgs
        }
        $prop = $parsed.PSObject.Properties['agent_type']
        if ($null -eq $prop) { return '' }
        return [string]$prop.Value
    }
    catch {
        return ''
    }
}

function Get-Phase {
    param([hashtable]$State)
    $started = $false
    $allPassed = $true
    $escalated = $false
    foreach ($gate in $script:GateOrder) {
        $attempts = [int]$State["${gate}Attempts"]
        $verdict = [string]$State["${gate}Verdict"]
        if ($attempts -gt 0) { $started = $true }
        if ($verdict -ne 'PASS') {
            $allPassed = $false
            if ($attempts -ge $script:MaxAttempts) { $escalated = $true }
        }
    }
    if (-not $started) { return 'idle' }
    if ($allPassed) { return 'complete' }
    if ($escalated) { return 'escalated' }
    if ([int]$State['totalInvocations'] -ge $script:MaxTotalInvocations) { return 'escalated' }
    return 'gating'
}

function Get-StuckGates {
    param([hashtable]$State)
    $stuck = @()
    foreach ($gate in $script:GateOrder) {
        if ([string]$State["${gate}Verdict"] -ne 'PASS' -and
            [int]$State["${gate}Attempts"] -ge $script:MaxAttempts) {
            $stuck += $gate
        }
    }
    return $stuck
}

function Get-NextGate {
    param([hashtable]$State)
    foreach ($gate in $script:GateOrder) {
        if ([string]$State["${gate}Verdict"] -ne 'PASS') { return $gate }
    }
    return $null
}

function Get-GateStatusLine {
    param([hashtable]$State)
    $parts = @()
    foreach ($gate in $script:GateOrder) {
        $verdict = [string]$State["${gate}Verdict"]
        $attempts = [int]$State["${gate}Attempts"]
        if ($attempts -eq 0) {
            $parts += "$gate=not-yet-run"
        }
        else {
            $parts += "$gate=$verdict($attempts/$script:MaxAttempts)"
        }
    }
    return ($parts -join ', ')
}

function Read-VerdictFromResponse {
    param([string]$Response)
    if ([string]::IsNullOrWhiteSpace($Response)) { return 'ISSUES' }
    # The contract requires the verdict on the FINAL line. Scanning the whole body would let a
    # reviewer that merely mentions a verdict mid-sentence ("I would say AUTODEV-VERDICT: PASS
    # if X were fixed") be recorded as a pass. Walk backwards to the last meaningful line and
    # judge only that; anything unexpected falls through to ISSUES.
    $lines = $Response -split "`r?`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        # Tolerate a trailing code fence wrapped around the verdict.
        if ($line -match '^`{3,}[A-Za-z0-9]*$') { continue }
        # Tolerate markdown emphasis, blockquote markers and trailing punctuation.
        if ($line -match '^[\s*`>_-]*AUTODEV-VERDICT:\s*(PASS|ISSUES)[\s*`.]*$') {
            return $Matches[1].ToUpperInvariant()
        }
        return 'ISSUES'
    }
    return 'ISSUES'
}

function Read-StandardInput {
    # [Console]::In decodes using the console's active code page, which mangles any non-ASCII
    # character in a reviewer's response (an en dash arrives as three Latin-1 characters). The
    # payload is always UTF-8, so decode it as UTF-8 explicitly.
    try {
        $stdin = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdin, (New-Object System.Text.UTF8Encoding($false)))
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    catch {
        return [Console]::In.ReadToEnd()
    }
}

function Write-JsonResult {
    param([hashtable]$Result)
    if ($null -eq $Result) { $Result = @{} }
    # Must be exactly one JSON object on stdout; -Compress keeps it on a single line.
    Write-Output ($Result | ConvertTo-Json -Depth 5 -Compress)
}

# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------

try {
    $rawInput = Read-StandardInput
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
        $payload = $rawInput | ConvertFrom-Json
    }
    if ($null -eq $payload) { Write-JsonResult @{}; exit 0 }

    $sessionId = Get-SafeSessionId -SessionId ([string]$payload.sessionId)
    $stateDir = Get-StateDirectory
    $statePath = Join-Path $stateDir "$sessionId.json"
    # Developer-facing artifacts go next to the plan when there is a workspace to put them in.
    $viewDir = Get-ViewDirectory -Cwd ([string]$payload.cwd)
    if ([string]::IsNullOrWhiteSpace($viewDir)) { $viewDir = $stateDir }
    $mirrorPath = Join-Path $viewDir 'gate-status.json'
    $auditPath = Join-Path $viewDir 'gate-audit.md'
    $feedbackPath = Join-Path $viewDir 'feedback-log.md'

    switch ($EventName) {

        'subagentStart' {
            $gate = Resolve-Gate -AgentName ([string]$payload.agentName)
            if ($null -eq $gate) { Write-JsonResult @{}; exit 0 }
            if (-not (Confirm-Directory -Path $stateDir)) { Write-JsonResult @{}; exit 0 }
            Confirm-Directory -Path $viewDir | Out-Null

            $state = Read-State -Path $statePath -SessionId $sessionId
            if ([int]$state['totalInvocations'] -eq 0) {
                # First gate of this session. The developer-facing artifacts live at fixed paths
                # in the workspace, so clear anything an earlier run left behind rather than
                # appending this session's rows to a stale file. State is per session, so this
                # fires exactly once per session.
                Remove-Item -LiteralPath $auditPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $feedbackPath -Force -ErrorAction SilentlyContinue
            }
            if ([string]$state["${gate}Verdict"] -eq 'PASS') {
                # This gate already passed, so this is a re-gate after a material change.
                # Start a fresh per-pass budget rather than charging it the old pass's attempts.
                $state["${gate}Attempts"] = 1
            }
            else {
                $state["${gate}Attempts"] = [int]$state["${gate}Attempts"] + 1
            }
            $state["${gate}Verdict"] = 'running'
            # Any later gate's verdict described an older version of the plan, so it is now
            # stale. Invalidating them keeps the tracker in step with the orchestrator's rule of
            # re-running every gate from the first one affected onward, and stops a re-gate from
            # reaching "complete" while downstream gates hold verdicts for a plan that changed.
            $gateIndex = [array]::IndexOf($script:GateOrder, $gate)
            for ($i = $gateIndex + 1; $i -lt $script:GateOrder.Count; $i++) {
                $later = $script:GateOrder[$i]
                $state["${later}Verdict"] = 'pending'
                $state["${later}Attempts"] = 0
            }
            $state['totalInvocations'] = [int]$state['totalInvocations'] + 1
            # Real progress was made, so forgive any earlier blocked stops.
            $state['blocks'] = 0
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $gate `
                -Attempt ([int]$state["${gate}Attempts"]) -Action 'invoked' -Verdict '-'

            Write-JsonResult @{}
            exit 0
        }

        'subagentStop' {
            # subagentStop does not support a matcher, so filter here.
            $gate = Resolve-Gate -AgentName ([string]$payload.agentName)
            if ($null -eq $gate) { Write-JsonResult @{}; exit 0 }
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $response = [string]$payload.response
            $verdict = Read-VerdictFromResponse -Response $response

            $state = Read-State -Path $statePath -SessionId $sessionId
            if ([int]$state["${gate}Attempts"] -lt 1) {
                # subagentStart was missed somehow; still count this attempt.
                $state["${gate}Attempts"] = 1
            }
            $state["${gate}Verdict"] = $verdict
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            $attempt = [int]$state["${gate}Attempts"]
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $gate `
                -Attempt $attempt -Action 'completed' -Verdict $verdict
            # Capture the review itself, not just that it happened, so the findings survive the
            # session and a developer can see what each gate actually objected to.
            Add-FeedbackEntry -Path $feedbackPath -SessionId $sessionId -Gate $gate `
                -Attempt $attempt -Verdict $verdict -Response $response

            $phase = Get-Phase -State $state
            $statusLine = Get-GateStatusLine -State $state

            $footerLines = @(
                '',
                '---',
                '[autodev-plan gate tracker]',
                "Gate: $gate | Attempt $attempt of $script:MaxAttempts | Recorded verdict: $verdict",
                "Gate status: $statusLine"
            )

            if ($phase -eq 'complete') {
                $footerLines += "Next required action: all three gates have passed. Proceed to WRAPUP."
                $footerLines += "Audit trail: $auditPath"
                $footerLines += "Reviewer feedback log: $feedbackPath"
            }
            elseif ($phase -eq 'escalated') {
                if ([int]$state['totalInvocations'] -ge $script:MaxTotalInvocations) {
                    $footerLines += "Next required action: the review gates have used all $script:MaxTotalInvocations permitted reviewer invocations for this session without reaching a clean state. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again, and further reviewer invocations are now refused."
                }
                else {
                    # Name the gate that is actually stuck, which is not necessarily the gate
                    # that just reported.
                    $stuck = Get-StuckGates -State $state
                    $stuckList = $stuck -join ', '
                    $footerLines += "Next required action: the $stuckList gate(s) reached the $script:MaxAttempts-attempt limit without passing. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again, and further reviewer invocations are now refused. This session can no longer reach a clean 'all gates passed' state; say so plainly at wrap-up."
                }
                $footerLines += "Audit trail: $auditPath"
                $footerLines += "Reviewer feedback log: $feedbackPath"
            }
            elseif ($verdict -eq 'PASS') {
                $nextGate = Get-NextGate -State $state
                $footerLines += "Next required action: the $gate gate is closed. Invoke autodev-plan:autodev-$nextGate-review next."
            }
            else {
                $remaining = $script:MaxAttempts - $attempt
                $footerLines += "Next required action: revise the plan file to address the findings above, then re-invoke autodev-plan:autodev-$gate-review. $remaining attempt(s) remain before escalation."
            }

            $footer = $footerLines -join [Environment]::NewLine
            Write-JsonResult @{ modifiedResponse = ($response + [Environment]::NewLine + $footer) }
            exit 0
        }

        'agentStop' {
            if (-not (Test-Path -LiteralPath $statePath)) { Write-JsonResult @{}; exit 0 }
            $state = Read-State -Path $statePath -SessionId $sessionId
            $phase = Get-Phase -State $state
            if ($phase -ne 'gating') { Write-JsonResult @{}; exit 0 }

            $blocks = [int]$state['blocks']
            if ($blocks -ge $script:MaxBlocks) {
                # Give up rather than fight the CLI's own runaway guard.
                Write-JsonResult @{}
                exit 0
            }
            $state['blocks'] = $blocks + 1
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            $nextGate = Get-NextGate -State $state
            $statusLine = Get-GateStatusLine -State $state
            $attempts = [int]$state["${nextGate}Attempts"]

            $reason = "You stopped while autodev-plan review gates are still outstanding. " +
            "Gate status: $statusLine. " +
            "Do not end your turn and do not ask the user anything. " +
            "Continue the workflow now by invoking the $nextGate gate via the task tool with " +
            "agent_type 'autodev-plan:autodev-$nextGate-review'"

            if ($attempts -gt 0) {
                $reason += ", after first revising the plan file to address that reviewer's outstanding findings"
            }
            $reason += '.'

            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $nextGate `
                -Attempt $attempts -Action 'premature-stop-blocked' -Verdict '-'

            Write-JsonResult @{ decision = 'block'; reason = $reason }
            exit 0
        }

        'preToolUse' {
            # hooks.json restricts this hook to ask_user and task via a matcher, but do not rely
            # on that alone: without this check a broadened or missing matcher would deny
            # *every* tool while gating, including the tools the orchestrator needs to revise
            # the plan, deadlocking it against the agentStop block.
            $toolName = [string]$payload.toolName
            if ($toolName -notmatch '^(?:ask_user|AskUserQuestion|task)$') { Write-JsonResult @{}; exit 0 }

            if (-not (Test-Path -LiteralPath $statePath)) { Write-JsonResult @{}; exit 0 }
            $state = Read-State -Path $statePath -SessionId $sessionId
            $phase = Get-Phase -State $state

            if ($toolName -eq 'task') {
                # Everything else in this plugin only *asks* the orchestrator to stop looping
                # once a gate is out of attempts. This is the part that actually stops it: once
                # the budget is spent, refuse to start another reviewer. Without it an
                # orchestrator that ignores the escalation instruction can keep re-invoking a
                # gate past its cap, which is exactly what the cap exists to prevent.
                if ($phase -ne 'escalated') { Write-JsonResult @{}; exit 0 }

                $targetGate = Resolve-Gate -AgentName (Get-TaskAgentType -ToolArgs $payload.toolArgs)
                if ($null -eq $targetGate) { Write-JsonResult @{}; exit 0 }

                $stuck = @(Get-StuckGates -State $state)
                if ($stuck.Count -gt 0) {
                    $limitReason = "the $($stuck -join ', ') gate(s) have used all $script:MaxAttempts permitted attempts"
                }
                else {
                    $limitReason = "this session has used all $script:MaxTotalInvocations permitted reviewer invocations"
                }
                $reason = "The autodev-plan review gates are out of budget: $limitReason. " +
                "Further reviewer invocations are refused, so re-running the $targetGate gate " +
                "cannot succeed. Stop looping and escalate to the user now, per your escalation " +
                "protocol: say which gate is stuck, summarise its outstanding findings, point at " +
                "the plan file and the feedback log, and state plainly that this session did not " +
                "reach a clean 'all gates passed' state. ask_user is available again."

                Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
                exit 0
            }

            if ($phase -ne 'gating') { Write-JsonResult @{}; exit 0 }

            $nextGate = Get-NextGate -State $state
            $reason = "The autodev-plan review gates run without human interaction. " +
            "The $nextGate gate is still outstanding, so ask_user is unavailable. " +
            "Resolve reviewer feedback yourself using your best engineering judgement and record " +
            "the decision in the plan's 'Review notes' section. If you truly cannot proceed, keep " +
            "looping until the gate reaches its attempt limit, at which point escalation to the " +
            "user is unlocked automatically."

            Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
            exit 0
        }
    }

    Write-JsonResult @{}
    exit 0
}
catch {
    # Fail open. preToolUse is fail-closed on a non-zero exit, so never let an internal
    # error here deny a tool call or block a turn.
    try { Write-JsonResult @{} } catch { Write-Output '{}' }
    exit 0
}
