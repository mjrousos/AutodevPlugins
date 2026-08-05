<#
.SYNOPSIS
    Tests for the autodev-plan gate tracker (autodev-gates.ps1).

.DESCRIPTION
    Runs the hook script as a separate process for every case, exactly as the CLI does, feeding
    the hook payload on stdin and asserting on the single JSON object it writes to stdout.

    Tests run against an isolated COPILOT_HOME so real session state is never touched.

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

function Invoke-Hook {
    param([string]$EventName, [hashtable]$Payload)
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
    @{ Name = 'bold markdown'; Body = "text`n`n**AUTODEV-VERDICT: PASS**"; Expect = 'PASS' }
    @{ Name = 'trailing period'; Body = "text`n`nAUTODEV-VERDICT: PASS."; Expect = 'PASS' }
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
    $dir = Join-Path $script:Root 'autodev-plan\gates'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir "$sid.json") -Value '{{{ not json'
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

Test-Case 'a hostile session id cannot escape the gates directory' {
    Invoke-Hook 'subagentStart' @{ sessionId = '../../evil'; agentName = 'autodev-plan:autodev-security-review' } | Out-Null
    if (Test-Path -LiteralPath (Join-Path $script:Root 'evil.json')) {
        throw 'state file was written outside the gates directory'
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

Test-Case 'a gate escalates after 5 failed attempts and unlocks the human' {
    $sid = New-SessionId
    1..5 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' }) 'escalation must release the stop block'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' }) 'escalation must re-permit ask_user'
}

Test-Case 'escalation names the gate that is actually stuck' {
    $sid = New-SessionId
    1..5 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    # A different gate reports next; the footer must still point at architecture.
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'security' -Verdict 'ISSUES')
    Assert-Match 'architecture gate' $footer
}

Test-Case 're-gating a passed gate starts a fresh attempt budget' {
    $sid = New-SessionId
    1..3 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES')
    Assert-Match 'Attempt 1 of 5' $footer 'a re-gate must not inherit the previous pass count'
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
    foreach ($i in 1..10) {
        foreach ($gate in @('architecture', 'security', 'privacy')) {
            $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate $gate -Verdict 'PASS')
            if ($footer -match 'permitted reviewer invocations') { $escalated = $true; break }
        }
        if ($escalated) { break }
    }
    if (-not $escalated) { throw 'cascade never hit the 20-invocation ceiling' }
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
    $audit = Join-Path $script:Root "autodev-plan\gates\$sid.md"
    if (-not (Test-Path -LiteralPath $audit)) { throw "no audit trail at $audit" }
    $rows = @((Get-Content -LiteralPath $audit) | Where-Object { $_ -match '^\|\s+\d{4}-' })
    Assert-Equal 4 $rows.Count 'expected two invoked rows and two completed rows'
    Assert-Match 'completed \| ISSUES' ($rows -join "`n")
    Assert-Match 'completed \| PASS' ($rows -join "`n")
}

Test-Case 'state writes leave no orphaned temp files' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $stray = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'autodev-plan\gates') -Filter '*.tmp' -ErrorAction SilentlyContinue)
    Assert-Equal 0 $stray.Count 'temp files must be renamed away or cleaned up'
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
