<#
.SYNOPSIS
    Gate tracker for the autodev-plan plugin (Windows / PowerShell).

.DESCRIPTION
    Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
    writes exactly one JSON object to stdout.

    Responsibilities:
      * subagentStart - record that a review gate was invoked; increment its attempt counter.
      * subagentStop  - parse the reviewer's verdict, record it, and append a tracker footer
                        to the response the orchestrator receives.
      * agentStop     - block the orchestrator from ending its turn while gates are outstanding.
      * preToolUse    - deny ask_user while gating, so the gate phase stays autonomous.

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
$script:MaxAttempts = 5
# Kept below the CLI's own 8-block runaway guard so we surrender first.
$script:MaxBlocks = 5
# Absolute ceiling across all gates and all re-gate passes. Because a re-gate resets a gate's
# per-pass budget, this is what makes an unbounded re-gate cascade impossible.
$script:MaxTotalInvocations = 20

function Get-StateDirectory {
    $home_ = $env:COPILOT_HOME
    if ([string]::IsNullOrWhiteSpace($home_)) {
        $profileDir = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileDir)) { $profileDir = $HOME }
        $home_ = Join-Path $profileDir '.copilot'
    }
    $dir = Join-Path (Join-Path $home_ 'autodev-plan') 'gates'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
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
    param([hashtable]$State, [string]$Path)
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

function Resolve-Gate {
    param([string]$AgentName)
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return $null }
    # agentName arrives namespaced, e.g. "autodev-plan:autodev-privacy-review".
    if ($AgentName -match 'autodev-(architecture|security|privacy)-review\s*$') {
        return $Matches[1]
    }
    return $null
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
    $rawInput = [Console]::In.ReadToEnd()
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
        $payload = $rawInput | ConvertFrom-Json
    }
    if ($null -eq $payload) { Write-JsonResult @{}; exit 0 }

    $sessionId = Get-SafeSessionId -SessionId ([string]$payload.sessionId)
    $stateDir = Get-StateDirectory
    $statePath = Join-Path $stateDir "$sessionId.json"
    $auditPath = Join-Path $stateDir "$sessionId.md"

    switch ($EventName) {

        'subagentStart' {
            $gate = Resolve-Gate -AgentName ([string]$payload.agentName)
            if ($null -eq $gate) { Write-JsonResult @{}; exit 0 }

            $state = Read-State -Path $statePath -SessionId $sessionId
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
            Write-State -State $state -Path $statePath
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $gate `
                -Attempt ([int]$state["${gate}Attempts"]) -Action 'invoked' -Verdict '-'

            Write-JsonResult @{}
            exit 0
        }

        'subagentStop' {
            # subagentStop does not support a matcher, so filter here.
            $gate = Resolve-Gate -AgentName ([string]$payload.agentName)
            if ($null -eq $gate) { Write-JsonResult @{}; exit 0 }

            $response = [string]$payload.response
            $verdict = Read-VerdictFromResponse -Response $response

            $state = Read-State -Path $statePath -SessionId $sessionId
            if ([int]$state["${gate}Attempts"] -lt 1) {
                # subagentStart was missed somehow; still count this attempt.
                $state["${gate}Attempts"] = 1
            }
            $state["${gate}Verdict"] = $verdict
            Write-State -State $state -Path $statePath

            $attempt = [int]$state["${gate}Attempts"]
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Gate $gate `
                -Attempt $attempt -Action 'completed' -Verdict $verdict

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
            }
            elseif ($phase -eq 'escalated') {
                if ([int]$state['totalInvocations'] -ge $script:MaxTotalInvocations) {
                    $footerLines += "Next required action: the review gates have used all $script:MaxTotalInvocations permitted reviewer invocations for this session without reaching a clean state. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again."
                }
                else {
                    # Name the gate that is actually stuck, which is not necessarily the gate
                    # that just reported.
                    $stuck = Get-StuckGates -State $state
                    $stuckList = $stuck -join ', '
                    $footerLines += "Next required action: the $stuckList gate(s) reached the $script:MaxAttempts-attempt limit without passing. Stop looping and escalate to the user now, per your escalation protocol. ask_user is permitted again. This session can no longer reach a clean 'all gates passed' state; say so plainly at wrap-up."
                }
                $footerLines += "Audit trail: $auditPath"
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
            Write-State -State $state -Path $statePath

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
            # hooks.json restricts this hook to ask_user via a matcher, but do not rely on that
            # alone: without this check a broadened or missing matcher would deny *every* tool
            # while gating, including the task tool the orchestrator needs to invoke the next
            # gate, deadlocking it against the agentStop block.
            $toolName = [string]$payload.toolName
            if ($toolName -notmatch '^(?:ask_user|AskUserQuestion)$') { Write-JsonResult @{}; exit 0 }

            if (-not (Test-Path -LiteralPath $statePath)) { Write-JsonResult @{}; exit 0 }
            $state = Read-State -Path $statePath -SessionId $sessionId
            if ((Get-Phase -State $state) -ne 'gating') { Write-JsonResult @{}; exit 0 }

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
