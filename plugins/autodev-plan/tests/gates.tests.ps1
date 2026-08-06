<#
.SYNOPSIS
    Tests for the autodev-plan gate tracker (autodev-gates.ps1).

.DESCRIPTION
    Runs the hook script as a separate process for every case, exactly as the CLI does, feeding
    the hook payload on stdin and asserting on the single JSON object it writes to stdout.

    Tests run against an isolated COPILOT_HOME, and each test gets its own temporary working
    directory, so real session state is never touched. The tracker writes into
    '<cwd>/.autodev/', so a per-test cwd is what keeps tests isolated from each other.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/gates.tests.ps1
    Exit code is 0 when every test passes, 1 otherwise.
#>

$ErrorActionPreference = 'Stop'

$script:GateScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\scripts\autodev-gates.ps1'
$script:Root = Join-Path ([IO.Path]::GetTempPath()) "autodev-gate-tests-$PID"
$script:Passed = 0
$script:Failed = 0

if (-not (Test-Path -LiteralPath $script:GateScript)) {
    Write-Host "Cannot find gate script at $script:GateScript" -ForegroundColor Red
    exit 1
}

function Get-SessionCwd {
    param([string]$SessionId)
    $dir = Join-Path $script:Root $SessionId
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-StatePath {
    param([string]$SessionId)
    # Enforcement state is keyed by session and lives outside the workspace.
    return (Join-Path (Join-Path $script:Root 'autodev-plan\gates') "$SessionId.json")
}

function Get-MirrorPath {
    param([string]$SessionId)
    return (Join-Path (Join-Path (Get-SessionCwd $SessionId) '.autodev') 'gate-status.json')
}

function Get-AuditPath {
    param([string]$SessionId)
    return (Join-Path (Join-Path (Get-SessionCwd $SessionId) '.autodev') 'gate-audit.md')
}

function Get-FeedbackPath {
    param([string]$SessionId)
    return (Join-Path (Join-Path (Get-SessionCwd $SessionId) '.autodev') 'feedback-log.md')
}

function Invoke-Hook {
    param([string]$EventName, [hashtable]$Payload)
    # The tracker keys its files off the session working directory, so give every session its
    # own. Tests that need to model two sessions sharing a directory pass 'cwd' explicitly.
    if ($Payload.ContainsKey('sessionId') -and -not $Payload.ContainsKey('cwd')) {
        $Payload = $Payload.Clone()
        $Payload['cwd'] = Get-SessionCwd $Payload['sessionId']
    }
    $json = $Payload | ConvertTo-Json -Compress -Depth 5
    $out = $json | powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript $EventName
    return ($out | Out-String).Trim()
}

function Start-Gate {
    param([string]$SessionId, [string]$Gate)
    Invoke-Hook 'subagentStart' @{ sessionId = $SessionId; agentName = "autodev-plan:autodev-$Gate-review" } | Out-Null
}

function Stop-Gate {
    param([string]$SessionId, [string]$Gate, [string]$Response)
    return Invoke-Hook 'subagentStop' @{ sessionId = $SessionId; agentName = "autodev-plan:autodev-$Gate-review"; response = $Response }
}

function Invoke-Round {
    param([string]$SessionId, [string]$Gate, [string]$Verdict)
    Start-Gate -SessionId $SessionId -Gate $Gate
    return Stop-Gate -SessionId $SessionId -Gate $Gate -Response "Body text.`n`nAUTODEV-VERDICT: $Verdict"
}

function Get-Footer {
    param([string]$HookOutput)
    return ($HookOutput | ConvertFrom-Json).modifiedResponse
}

function New-SessionId {
    # A unique session id per test keeps state files from colliding.
    return "t$([guid]::NewGuid().ToString('N').Substring(0, 12))"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "expected '$Expected' but got '$Actual'. $Because" }
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Because = '')
    if ($Actual -notmatch $Pattern) { throw "expected match for '$Pattern' but got '$Actual'. $Because" }
}

$env:COPILOT_HOME = $script:Root
# The CLI writes the hook payload as UTF-8, so the harness must too, or a non-ASCII test case
# would be mangled before it ever reached the script.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force }
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

Write-Host ''
Write-Host 'autodev-plan gate tracker tests (PowerShell)' -ForegroundColor Cyan
Write-Host "script: $script:GateScript"

# ------------------------------------------------------------------------------------------
Write-Host "`nVerdict parsing (must read only the final meaningful line)" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

$fence = '```'
$verdictCases = @(
    @{ Name = 'clean PASS'; Body = "Summary.`n`nAUTODEV-VERDICT: PASS"; Expect = 'PASS' }
    @{ Name = 'clean ISSUES'; Body = "Findings.`n`nAUTODEV-VERDICT: ISSUES"; Expect = 'ISSUES' }
    @{ Name = 'trailing blank lines'; Body = "AUTODEV-VERDICT: PASS`n`n`n"; Expect = 'PASS' }
    @{ Name = 'wrapped in a code fence'; Body = "text`n$fence`nAUTODEV-VERDICT: PASS`n$fence"; Expect = 'PASS' }
    # A fence sharing the verdict's line is the one input where the two implementations used to
    # disagree, closing a gate on Windows and failing it on Linux.
    @{ Name = 'fence and verdict share a line'; Body = "text`n${fence}AUTODEV-VERDICT: PASS${fence}"; Expect = 'PASS' }
    @{ Name = 'bold markdown'; Body = "text`n`n**AUTODEV-VERDICT: PASS**"; Expect = 'PASS' }
    @{ Name = 'trailing period'; Body = "text`n`nAUTODEV-VERDICT: PASS."; Expect = 'PASS' }
    @{ Name = 'indented verdict line'; Body = "text`n`n    AUTODEV-VERDICT: PASS"; Expect = 'PASS' }
    # The reviewer templates show the verdict as a placeholder. If a model ever copies it
    # literally that must fail safe rather than read as a pass.
    @{ Name = 'literal template placeholder is not a pass'; Body = "Summary.`n`nAUTODEV-VERDICT: <PASS or ISSUES>"; Expect = 'ISSUES' }
    # The important negatives: a verdict mentioned in prose must never count as the verdict.
    @{ Name = 'mid-body PASS with no final verdict'; Body = "I would say AUTODEV-VERDICT: PASS if fixed.`n`n### blocker Missing authz"; Expect = 'ISSUES' }
    @{ Name = 'mid-body PASS then final ISSUES'; Body = "AUTODEV-VERDICT: PASS maybe`n`nAUTODEV-VERDICT: ISSUES"; Expect = 'ISSUES' }
    @{ Name = 'commentary after the verdict'; Body = "AUTODEV-VERDICT: PASS`nBut actually I am unsure."; Expect = 'ISSUES' }
    @{ Name = 'no verdict at all'; Body = 'I forgot to include one.'; Expect = 'ISSUES' }
    @{ Name = 'empty response'; Body = ''; Expect = 'ISSUES' }
)

foreach ($case in $verdictCases) {
    $c = $case
    Test-Case "verdict: $($c.Name)" {
        $sid = New-SessionId
        Start-Gate -SessionId $sid -Gate 'architecture'
        $footer = Get-Footer (Stop-Gate -SessionId $sid -Gate 'architecture' -Response $c.Body)
        Assert-Match "Recorded verdict: $($c.Expect)" $footer
    }.GetNewClosure()
}

# ------------------------------------------------------------------------------------------
Write-Host "`nFail-safes (a hook must never deny a tool call or crash)" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

Test-Case 'agentStop with no state returns empty' {
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = New-SessionId; stopReason = 'end_turn' })
}

Test-Case 'ask_user with no state is permitted' {
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = New-SessionId; toolName = 'ask_user' })
}

foreach ($agent in @('explore', 'general-purpose', 'security-review', 'code-review', 'task')) {
    $a = $agent
    Test-Case "non-reviewer sub-agent '$a' is ignored" {
        Assert-Equal '{}' (Invoke-Hook 'subagentStart' @{ sessionId = New-SessionId; agentName = $a })
    }.GetNewClosure()
}

Test-Case 'corrupt state file does not deny ask_user or block stopping' {
    $sid = New-SessionId
    $statePath = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $statePath -Value '{{{ not json'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' })
}

Test-Case 'a state file with no owner is never adopted' {
    # preToolUse is fail-closed, so a hand-edited or truncated file must not be able to deny
    # tools in a session it has nothing to do with.
    $sid = New-SessionId
    $statePath = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $statePath -Value '{"totalInvocations":30,"architectureAttempts":10,"architectureVerdict":"ISSUES","securityVerdict":"pending","privacyVerdict":"pending"}'
    $args_ = '{"agent_type":"autodev-plan:autodev-architecture-review"}'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $args_ })
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' })
}

Test-Case 'garbage stdin returns empty JSON and exits 0' {
    $out = 'this is not json' | powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript preToolUse
    Assert-Equal 0 $LASTEXITCODE 'hook must exit 0'
    Assert-Equal '{}' ($out | Out-String).Trim()
}

Test-Case 'empty stdin returns empty JSON and exits 0' {
    $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript preToolUse
    Assert-Equal 0 $LASTEXITCODE 'hook must exit 0'
    Assert-Equal '{}' ($out | Out-String).Trim()
}

Test-Case 'a hostile session id cannot escape the state directory' {
    $sid = '../../evil'
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = 'autodev-plan:autodev-security-review'; cwd = (Get-SessionCwd 'hostile-id-cwd') } | Out-Null
    foreach ($stray in @('evil.json', 'evil.md')) {
        if (Test-Path -LiteralPath (Join-Path $script:Root $stray)) {
            throw "state file '$stray' was written outside the state directory"
        }
    }
}

# ------------------------------------------------------------------------------------------
Write-Host "`nEnforcement" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

Test-Case 'agentStop is blocked while a gate is outstanding' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    $parsed = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $parsed.decision
    Assert-Match 'autodev-plan:autodev-architecture-review' $parsed.reason
}

Test-Case 'ask_user is denied while gating' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    $parsed = Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' } | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
}

foreach ($tool in @('view', 'edit', 'create', 'task', 'bash', 'powershell', 'grep', 'glob')) {
    $t = $tool
    Test-Case "'$t' is NOT denied while gating" {
        # Defense in depth. hooks.json scopes this hook to ask_user and task, but if that
        # matcher were ever broadened the orchestrator would be denied the tools it needs to
        # revise the plan and invoke the next gate, and would then deadlock against the
        # agentStop block. 'task' must stay allowed while a gate still has attempts left.
        $sid = New-SessionId
        Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = $t })
    }.GetNewClosure()
}

Test-Case 'invoking a reviewer is permitted while the gate still has attempts left' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    $args_ = '{"agent_type":"autodev-plan:autodev-architecture-review","prompt":"review"}'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $args_ })
}

Test-Case 'agentStop names the next gate once one passes' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $parsed = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Match 'autodev-plan:autodev-security-review' $parsed.reason
}

Test-Case 'all gates passing releases the block and permits ask_user' {
    $sid = New-SessionId
    foreach ($gate in @('architecture', 'security', 'privacy')) {
        Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS' | Out-Null
    }
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' })
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
}

# ------------------------------------------------------------------------------------------
Write-Host "`nLoop bounds" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

Test-Case 'a gate escalates after 10 failed attempts and unlocks the human' {
    $sid = New-SessionId
    1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' }) 'escalation must release the stop block'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' }) 'escalation must re-permit ask_user'
}

Test-Case 'a gate does NOT escalate one attempt short of the budget' {
    # Guards the off-by-one directly: 9 failures must still be a live gate.
    $sid = New-SessionId
    1..9 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    $parsed = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $parsed.decision 'the gate still has an attempt left, so stopping must still be blocked'
}

Test-Case 'escalation names the gate that is actually stuck' {
    $sid = New-SessionId
    1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    # A different gate reports next; the footer must still point at architecture.
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'security' -Verdict 'ISSUES')
    Assert-Match 'architecture gate' $footer
}

Test-Case 're-gating a passed gate starts a fresh attempt budget' {
    $sid = New-SessionId
    1..3 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES')
    Assert-Match 'Attempt 1 of 10' $footer 'a re-gate must not inherit the previous pass count'
}

Test-Case 'the block counter stops fighting the CLI runaway guard' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    $decisions = 1..7 | ForEach-Object {
        $parsed = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
        if ($parsed.decision -eq 'block') { '1' } else { '0' }
    }
    Assert-Equal '1111100' ($decisions -join '') 'expected 5 blocks then release'
}

Test-Case 'the session-wide invocation ceiling escalates a runaway cascade' {
    $sid = New-SessionId
    $escalated = $false
    foreach ($i in 1..20) {
        foreach ($gate in @('architecture', 'security', 'privacy')) {
            $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS')
            if ($footer -match 'permitted reviewer invocations') { $escalated = $true; break }
        }
        if ($escalated) { break }
    }
    if (-not $escalated) { throw 'cascade never hit the session-wide invocation ceiling' }
}

Test-Case 'the session-wide ceiling leaves room for every gate to spend its budget' {
    # If the ceiling were at or below (gates * per-gate budget) it would silently become the
    # real limit and the per-gate budget would never be reachable on the last gate.
    $sid = New-SessionId
    foreach ($gate in @('architecture', 'security')) {
        1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate $gate -Verdict 'ISSUES' | Out-Null }
        Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS' | Out-Null
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'privacy' -Verdict 'ISSUES')
    Assert-Match 'Attempt 1 of 10' $footer
    Assert-Match '9 attempt\(s\) remain' $footer 'the last gate must still get a full budget'
}

# ------------------------------------------------------------------------------------------
Write-Host "`nBudget exhaustion actually stops the loop" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

function Invoke-ReviewerTask {
    param([string]$SessionId, [string]$Gate)
    $args_ = "{`"agent_type`":`"autodev-plan:autodev-$Gate-review`",`"prompt`":`"review`"}"
    return Invoke-Hook 'preToolUse' @{ sessionId = $SessionId; toolName = 'task'; toolArgs = $args_ }
}

Test-Case 'once a gate is out of attempts, re-invoking any reviewer is refused' {
    # The footer only *asks* the orchestrator to stop. This is what makes the cap real: an
    # orchestrator that ignores the escalation instruction still cannot start an 11th review.
    $sid = New-SessionId
    1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    $parsed = (Invoke-ReviewerTask -SessionId $sid -Gate 'architecture') | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
    Assert-Match 'out of budget' $parsed.permissionDecisionReason
    Assert-Match 'architecture' $parsed.permissionDecisionReason
}

Test-Case 'a stuck gate also blocks moving on to a different reviewer' {
    # Skipping ahead to the next gate would produce a plan that never cleared architecture.
    $sid = New-SessionId
    1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    $parsed = (Invoke-ReviewerTask -SessionId $sid -Gate 'security') | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
}

Test-Case 'the refusal does not spill over onto non-reviewer sub-agents' {
    # The orchestrator may still need explore or general-purpose agents to write up the
    # escalation, so only reviewer invocations are refused.
    $sid = New-SessionId
    1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    foreach ($agent in @('explore', 'general-purpose', 'code-review', 'security-review')) {
        $args_ = "{`"agent_type`":`"$agent`",`"prompt`":`"go`"}"
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $args_ }) "'$agent' must still be allowed"
    }
}

Test-Case 'malformed task arguments never deny the tool call' {
    $sid = New-SessionId
    1..10 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    foreach ($bad in @('', 'not json at all', '{"no_agent_type":1}', '[]')) {
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $bad }) "toolArgs '$bad' must fail open"
    }
}

Test-Case 'reviewers are refused once the session-wide ceiling is reached' {
    $sid = New-SessionId
    $hit = $false
    foreach ($i in 1..20) {
        foreach ($gate in @('architecture', 'security', 'privacy')) {
            $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS')
            if ($footer -match 'permitted reviewer invocations') { $hit = $true; break }
        }
        if ($hit) { break }
    }
    if (-not $hit) { throw 'never reached the session-wide ceiling' }
    $parsed = (Invoke-ReviewerTask -SessionId $sid -Gate 'architecture') | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
    Assert-Match 'permitted reviewer invocations' $parsed.permissionDecisionReason
}

# ------------------------------------------------------------------------------------------
Write-Host "`nRe-gate invalidation" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

Test-Case 're-gating an earlier gate invalidates the later ones' {
    $sid = New-SessionId
    foreach ($gate in @('architecture', 'security', 'privacy')) {
        Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS' | Out-Null
    }
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' }) 'should be complete before the re-gate'

    # A material change re-runs architecture. The security and privacy verdicts described the
    # older plan, so they must not still count as passed.
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $parsed = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $parsed.decision 'stale downstream passes must not satisfy the tracker'
    Assert-Match 'autodev-plan:autodev-security-review' $parsed.reason
}

# ------------------------------------------------------------------------------------------
Write-Host "`nAudit trail" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

Test-Case 'every reviewer invocation is recorded' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $audit = Get-AuditPath $sid
    if (-not (Test-Path -LiteralPath $audit)) { throw "no audit trail at $audit" }
    $rows = @((Get-Content -LiteralPath $audit) | Where-Object { $_ -match '^\|\s+\d{4}-' })
    Assert-Equal 4 $rows.Count 'expected two invoked rows and two completed rows'
    Assert-Match 'completed \| ISSUES' ($rows -join "`n")
    Assert-Match 'completed \| PASS' ($rows -join "`n")
}

Test-Case 'state writes leave no orphaned temp files' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $stray = @(Get-ChildItem -LiteralPath (Split-Path (Get-StatePath $sid) -Parent) -Filter '*.tmp' -ErrorAction SilentlyContinue)
    Assert-Equal 0 $stray.Count 'temp files must be renamed away or cleaned up'
}

# ------------------------------------------------------------------------------------------
Write-Host "`nDeveloper-visible artifacts under .autodev/" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

Test-Case 'state, mirror, audit trail and feedback log are all reachable' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    foreach ($path in @((Get-StatePath $sid), (Get-MirrorPath $sid), (Get-AuditPath $sid), (Get-FeedbackPath $sid))) {
        if (-not (Test-Path -LiteralPath $path)) { throw "expected $path to exist" }
    }
}

Test-Case 'enforcement state lives outside the workspace, the mirror inside it' {
    # The orchestrator may edit workspace files while gating, so anything it could rewrite is
    # not enforcement. Only a read-only view belongs in .autodev.
    $sid = New-SessionId
    $cwd = Get-SessionCwd $sid
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    if ((Get-StatePath $sid).StartsWith($cwd, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'enforcement state must not live inside the workspace'
    }
    $mirror = (Get-Content -LiteralPath (Get-MirrorPath $sid) -Raw | ConvertFrom-Json)
    Assert-Equal 1 $mirror.architectureAttempts 'the mirror must reflect the real state'
    Assert-Equal 'ISSUES' $mirror.architectureVerdict
}

Test-Case 'tampering with the mirror does not weaken a gate' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    Set-Content -LiteralPath (Get-MirrorPath $sid) -Value '{"sessionId":"x","architectureVerdict":"PASS","securityVerdict":"PASS","privacyVerdict":"PASS","architectureAttempts":1,"securityAttempts":1,"privacyAttempts":1,"totalInvocations":3,"blocks":0}'
    $parsed = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $parsed.decision 'rewriting the mirror must not release the gate'
}

Test-Case 'two sessions in one directory keep independent attempt counters' {
    # This is what makes the caps real. If sessions shared one state file they would reset each
    # other and no gate would ever reach its limit.
    $shared = Get-SessionCwd (New-SessionId)
    $a = New-SessionId
    $b = New-SessionId
    foreach ($i in 1..6) {
        foreach ($sid in @($a, $b)) {
            Invoke-Hook 'subagentStart' @{ sessionId = $sid; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
            Invoke-Hook 'subagentStop' @{ sessionId = $sid; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "finding`n`nAUTODEV-VERDICT: ISSUES" } | Out-Null
        }
    }
    foreach ($sid in @($a, $b)) {
        $state = Get-Content -LiteralPath (Get-StatePath $sid) -Raw | ConvertFrom-Json
        Assert-Equal 6 $state.architectureAttempts "session $sid lost attempts to the other session"
        # Both are past the 10-attempt cap only after 10; at 6 they are still gating.
        $args_ = '{"agent_type":"autodev-plan:autodev-architecture-review"}'
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; cwd = $shared; toolName = 'task'; toolArgs = $args_ })
    }
    # Take one session all the way to its cap; the other must be unaffected.
    foreach ($i in 1..4) {
        Invoke-Hook 'subagentStart' @{ sessionId = $a; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
        Invoke-Hook 'subagentStop' @{ sessionId = $a; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "finding`n`nAUTODEV-VERDICT: ISSUES" } | Out-Null
    }
    $args2 = '{"agent_type":"autodev-plan:autodev-architecture-review"}'
    $denied = Invoke-Hook 'preToolUse' @{ sessionId = $a; cwd = $shared; toolName = 'task'; toolArgs = $args2 } | ConvertFrom-Json
    Assert-Equal 'deny' $denied.permissionDecision 'the session at its cap must be refused'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $b; cwd = $shared; toolName = 'task'; toolArgs = $args2 }) 'the other session must keep its own budget'
}

Test-Case 'the audit trail is reset once per session, not on every invocation' {
    $sid = New-SessionId
    1..3 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    $rows = @((Get-Content -LiteralPath (Get-AuditPath $sid)) | Where-Object { $_ -match '^\|\s+\d{4}-' })
    Assert-Equal 6 $rows.Count 'three rounds must leave six rows, not one'
    $entries = @((Get-Content -LiteralPath (Get-FeedbackPath $sid)) | Where-Object { $_ -match '^# \w+ - attempt ' })
    Assert-Equal 3 $entries.Count 'three rounds must leave three feedback entries'
}

Test-Case 'the feedback log records each reviewer response verbatim' {
    $sid = New-SessionId
    Start-Gate -SessionId $sid -Gate 'architecture'
    Stop-Gate -SessionId $sid -Gate 'architecture' `
        -Response "### blocker Unbounded retry loop`nThe worker never gives up.`n`nAUTODEV-VERDICT: ISSUES" | Out-Null
    $log = Get-Content -LiteralPath (Get-FeedbackPath $sid) -Raw
    Assert-Match 'blocker Unbounded retry loop' $log 'the reviewer findings must be preserved'
    Assert-Match 'The worker never gives up\.' $log
    Assert-Match '(?m)^# architecture - attempt 1 - ISSUES\r?$' $log 'entries must be labelled with gate, attempt and verdict'
}

Test-Case 'the feedback log accumulates every attempt of every gate' {
    $sid = New-SessionId
    Start-Gate -SessionId $sid -Gate 'architecture'
    Stop-Gate -SessionId $sid -Gate 'architecture' -Response "First round finding.`n`nAUTODEV-VERDICT: ISSUES" | Out-Null
    Start-Gate -SessionId $sid -Gate 'architecture'
    Stop-Gate -SessionId $sid -Gate 'architecture' -Response "Now resolved.`n`nAUTODEV-VERDICT: PASS" | Out-Null
    Start-Gate -SessionId $sid -Gate 'security'
    Stop-Gate -SessionId $sid -Gate 'security' -Response "Secrets in logs.`n`nAUTODEV-VERDICT: ISSUES" | Out-Null
    $log = Get-Content -LiteralPath (Get-FeedbackPath $sid) -Raw
    foreach ($needle in @('First round finding', 'Now resolved', 'Secrets in logs')) {
        Assert-Match $needle $log "the log must keep every round, missing '$needle'"
    }
    Assert-Match '(?m)^# security - attempt 1 - ISSUES\r?$' $log
}

Test-Case 'the footer points the orchestrator at the feedback log when gating finishes' {
    $sid = New-SessionId
    foreach ($gate in @('architecture', 'security')) {
        Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS' | Out-Null
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'privacy' -Verdict 'PASS')
    Assert-Match 'feedback-log\.md' $footer
    Assert-Match 'gate-audit\.md' $footer
}

Test-Case 'a new session does not inherit a previous run left in the same directory' {
    # The files sit at fixed paths now, so a stale run must never hand a fresh session three
    # passing gates or append its rows to the old session's audit trail.
    $shared = Get-SessionCwd (New-SessionId)
    $first = New-SessionId
    foreach ($gate in @('architecture', 'security', 'privacy')) {
        Invoke-Hook 'subagentStart' @{ sessionId = $first; cwd = $shared; agentName = "autodev-plan:autodev-$gate-review" } | Out-Null
        Invoke-Hook 'subagentStop' @{ sessionId = $first; cwd = $shared; agentName = "autodev-plan:autodev-$gate-review"; response = "ok`n`nAUTODEV-VERDICT: PASS" } | Out-Null
    }

    $second = New-SessionId
    # Before the new session runs anything, its gates must read as untouched.
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $second; cwd = $shared; stopReason = 'end_turn' }) 'an idle session must not be blocked'

    Invoke-Hook 'subagentStart' @{ sessionId = $second; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
    Invoke-Hook 'subagentStop' @{ sessionId = $second; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "ok`n`nAUTODEV-VERDICT: PASS" } | Out-Null

    # Count before the agentStop below, which legitimately adds its own blocked-stop row.
    $audit = Join-Path (Join-Path $shared '.autodev') 'gate-audit.md'
    $rows = @((Get-Content -LiteralPath $audit) | Where-Object { $_ -match '^\|\s+\d{4}-' })
    Assert-Equal 2 $rows.Count 'the audit trail must restart for the new session'

    $parsed = Invoke-Hook 'agentStop' @{ sessionId = $second; cwd = $shared; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $parsed.decision 'the old session''s security and privacy passes must not carry over'
}

Test-Case 'the feedback log stamps each entry with a readable timestamp' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null
    $log = Get-Content -LiteralPath (Get-FeedbackPath $sid) -Raw
    Assert-Match '_\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z_' $log 'each entry needs a timestamp, not an empty marker'
}

Test-Case 'non-ASCII reviewer text survives the round trip' {
    # Reviewers routinely emit en dashes and curly quotes. Decoding stdin with the console code
    # page corrupts them in both the feedback log and the footer handed back to the orchestrator.
    $sid = New-SessionId
    $dash = [char]0x2013
    $quote = [char]0x2019
    Start-Gate -SessionId $sid -Gate 'architecture'
    $out = Stop-Gate -SessionId $sid -Gate 'architecture' `
        -Response "Rows 4${dash}6 use the client${quote}s token.`n`nAUTODEV-VERDICT: ISSUES"
    $footer = Get-Footer $out
    Assert-Match "4${dash}6" $footer 'the footer must preserve the reviewer text verbatim'
    $log = [IO.File]::ReadAllText((Get-FeedbackPath $sid), [Text.Encoding]::UTF8)
    Assert-Match "4${dash}6" $log 'the feedback log must preserve the reviewer text verbatim'
    Assert-Match "client${quote}s" $log
}

Test-Case 'unrelated tool calls and sub-agents do not create a .autodev directory' {
    # The hooks fire in every session once the plugin is installed. Creating the state directory
    # eagerly would litter an empty '.autodev' into any repo where someone merely used the task
    # tool. It must appear only when a real review gate starts.
    $sid = New-SessionId
    $cwd = Get-SessionCwd $sid
    Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = '{"agent_type":"explore"}' } | Out-Null
    Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' } | Out-Null
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = 'explore' } | Out-Null
    Invoke-Hook 'subagentStop' @{ sessionId = $sid; agentName = 'explore'; response = 'done' } | Out-Null
    Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | Out-Null
    if (Test-Path -LiteralPath (Join-Path $cwd '.autodev')) {
        throw '.autodev was created by a session that never ran a review gate'
    }
    # ...but a real gate does create it.
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $cwd '.autodev'))) {
        throw '.autodev was not created when a review gate started'
    }
}

# ------------------------------------------------------------------------------------------
Write-Host "`nHook wiring (hooks.json is what connects all of the above to the CLI)" -ForegroundColor Cyan
# ------------------------------------------------------------------------------------------

$script:PluginRoot = Split-Path $PSScriptRoot -Parent
$script:Hooks = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'hooks.json') -Raw | ConvertFrom-Json

# The CLI anchors a matcher as ^(?:PATTERN)$ against the full value.
function Test-Matcher {
    param([string]$Pattern, [string]$Value)
    return $Value -match "^(?:$Pattern)$"
}

Test-Case 'hooks.json declares all four hook events' {
    Assert-Equal 1 $script:Hooks.version
    foreach ($evt in @('subagentStart', 'subagentStop', 'agentStop', 'preToolUse')) {
        if (-not $script:Hooks.hooks.PSObject.Properties[$evt]) { throw "missing hook event '$evt'" }
    }
}

Test-Case 'every hook entry supplies both bash and powershell commands' {
    foreach ($prop in $script:Hooks.hooks.PSObject.Properties) {
        foreach ($entry in $prop.Value) {
            if (-not $entry.bash) { throw "$($prop.Name) is missing a bash command" }
            if (-not $entry.powershell) { throw "$($prop.Name) is missing a powershell command" }
        }
    }
}

Test-Case 'every hook entry dispatches its own event name to the right script' {
    foreach ($prop in $script:Hooks.hooks.PSObject.Properties) {
        foreach ($entry in $prop.Value) {
            Assert-Match "autodev-gates\.sh`" $($prop.Name)$" $entry.bash "bad bash wiring for $($prop.Name)"
            Assert-Match "autodev-gates\.ps1`" $($prop.Name)$" $entry.powershell "bad powershell wiring for $($prop.Name)"
            Assert-Match '\$\{PLUGIN_ROOT\}' $entry.bash 'must resolve via ${PLUGIN_ROOT}'
            Assert-Match '\$\{PLUGIN_ROOT\}' $entry.powershell 'must resolve via ${PLUGIN_ROOT}'
        }
    }
}

Test-Case 'hook entries invoke powershell.exe rather than pwsh' {
    # pwsh (PowerShell 7) is a separate install, so relying on it would add a prerequisite the
    # plugin documents as unnecessary.
    foreach ($prop in $script:Hooks.hooks.PSObject.Properties) {
        foreach ($entry in $prop.Value) {
            if ($entry.powershell -match '(^|\s|")pwsh(\s|$|")') { throw "$($prop.Name) uses pwsh" }
        }
    }
}

Test-Case 'every script referenced by hooks.json exists' {
    foreach ($rel in @('hooks/scripts/autodev-gates.ps1', 'hooks/scripts/autodev-gates.sh')) {
        $full = Join-Path $script:PluginRoot $rel
        if (-not (Test-Path -LiteralPath $full)) { throw "hooks.json references a missing file: $rel" }
    }
}

Test-Case 'the subagentStart matcher catches all three reviewer agents' {
    $pattern = $script:Hooks.hooks.subagentStart[0].matcher
    if (-not $pattern) { throw 'subagentStart has no matcher; it would fire for every sub-agent' }
    foreach ($gate in @('architecture', 'security', 'privacy')) {
        # The CLI passes the fully namespaced agent name.
        $name = "autodev-plan:autodev-$gate-review"
        if (-not (Test-Matcher $pattern $name)) { throw "matcher does not match '$name'" }
    }
}

Test-Case 'the subagentStart matcher ignores unrelated sub-agents' {
    $pattern = $script:Hooks.hooks.subagentStart[0].matcher
    foreach ($name in @('explore', 'general-purpose', 'task', 'code-review', 'security-review', 'rubber-duck', 'research')) {
        # Note 'security-review' is a CLI built-in and must not be mistaken for our gate.
        if (Test-Matcher $pattern $name) { throw "matcher wrongly matches the unrelated agent '$name'" }
    }
}

Test-Case 'the preToolUse matcher covers ask_user and task, and nothing else' {
    $pattern = $script:Hooks.hooks.preToolUse[0].matcher
    if (-not $pattern) { throw 'preToolUse has no matcher; it would fire for every tool call' }
    foreach ($tool in @('ask_user', 'task')) {
        # 'task' must reach the hook so budget exhaustion can refuse further reviewer runs.
        if (-not (Test-Matcher $pattern $tool)) { throw "matcher does not match '$tool'" }
    }
    foreach ($tool in @('view', 'edit', 'create', 'bash', 'powershell', 'grep', 'glob', 'web_fetch')) {
        if (Test-Matcher $pattern $tool) { throw "matcher wrongly matches '$tool'" }
    }
}

Test-Case 'subagentStop has no matcher, since the CLI does not support one there' {
    # The script filters on agentName in-process instead; if a matcher were added here the
    # tracker would silently stop seeing verdicts.
    if ($script:Hooks.hooks.subagentStop[0].matcher) {
        throw 'subagentStop declares a matcher, which the CLI does not honor for that event'
    }
}

Test-Case 'every hook entry sets a timeout' {
    # A command hook that times out is fail-open, so an unset timeout risks a hung session.
    foreach ($prop in $script:Hooks.hooks.PSObject.Properties) {
        foreach ($entry in $prop.Value) {
            if (-not $entry.timeoutSec) { throw "$($prop.Name) has no timeoutSec" }
        }
    }
}

# ------------------------------------------------------------------------------------------

Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "$script:Passed passed, $script:Failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "$script:Passed passed, 0 failed" -ForegroundColor Green
exit 0
