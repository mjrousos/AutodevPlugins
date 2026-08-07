<#
.SYNOPSIS
    Tests for the autodev-plan gate tracker (autodev-gates.ps1).

.DESCRIPTION
    Runs the hook script as a separate process for every case, exactly as the CLI does, feeding
    the hook payload on stdin and asserting on the single JSON object it writes to stdout.

    Tests run against an isolated COPILOT_HOME, and each test gets its own temporary working
    directory, so real session state is never touched. The tracker writes its developer-facing
    artifacts into '<cwd>/.autodev/', so a per-test cwd is what keeps tests isolated.

    Every assertion costs a process spawn (~1s: PowerShell startup plus the JSON cmdlets), so by
    default the suite shards itself across parallel workers. Use -Sequential for readable,
    grouped output when you are diagnosing a failure.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/gates.tests.ps1
            ... -Sequential          run in one process, grouped by section
            ... -Workers 4           override the worker count
    Exit code is 0 when every test passes, 1 otherwise.
#>

param(
    # Set by the dispatcher on each worker; -1 means "this process is the dispatcher".
    [int]$Shard = -1,
    [int]$ShardCount = 1,
    [int]$Workers = 0,
    [switch]$Sequential
)

$ErrorActionPreference = 'Stop'

$script:GateScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\scripts\autodev-gates.ps1'
$script:Root = Join-Path ([IO.Path]::GetTempPath()) "autodev-gate-tests-$PID"
$script:Passed = 0
$script:Failed = 0
$script:CaseIndex = -1
$script:IsWorker = ($Shard -ge 0)

if (-not (Test-Path -LiteralPath $script:GateScript)) {
    Write-Host "Cannot find gate script at $script:GateScript" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------------------
# Dispatcher: fan the cases out across worker processes and aggregate.
# ------------------------------------------------------------------------------------------
if (-not $script:IsWorker -and -not $Sequential) {
    if ($Workers -le 0) { $Workers = [Math]::Min(8, [Environment]::ProcessorCount) }
    if ($Workers -lt 1) { $Workers = 1 }

    $outDir = Join-Path ([IO.Path]::GetTempPath()) "autodev-gate-shards-$PID"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Write-Host ''
    Write-Host "autodev-plan gate tracker tests (PowerShell), $Workers workers" -ForegroundColor Cyan
    Write-Host 'Use -Sequential for output grouped by section.'

    $started = Get-Date
    $running = @()
    for ($i = 0; $i -lt $Workers; $i++) {
        $log = Join-Path $outDir "shard-$i.log"
        $proc = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow -RedirectStandardOutput $log `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
            # Quoted explicitly: -ArgumentList joins on spaces, so an unquoted path containing a
            # space would be split into separate arguments.
            '-File', "`"$PSCommandPath`"",
            '-Shard', $i, '-ShardCount', $Workers)
        $running += [pscustomobject]@{ Proc = $proc; Log = $log }
    }
    foreach ($r in $running) { $r.Proc.WaitForExit() }

    $totalPassed = 0
    $totalFailed = 0
    $missing = @()
    for ($i = 0; $i -lt $running.Count; $i++) {
        $r = $running[$i]
        $sawResult = $false
        foreach ($line in @(Get-Content -LiteralPath $r.Log -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*RESULT\s+(\d+)\s+(\d+)\s*$') {
                $sawResult = $true
                $totalPassed += [int]$Matches[1]
                $totalFailed += [int]$Matches[2]
            }
            elseif ($line -match '^\s*FAIL\s') { Write-Host $line -ForegroundColor Red }
            elseif ($line -match '^\s*PASS\s') { Write-Host $line -ForegroundColor Green }
            else { Write-Host $line }
        }
        # A worker that dies before printing its tally takes its whole share of the cases with
        # it. Without this the run would report only the surviving shards' results and pass.
        if (-not $sawResult) {
            # Start-Process -PassThru does not always surface ExitCode once the process object's
            # handle is gone, so do not let a missing code hide the real message.
            $code = 'unknown'
            try { if ($null -ne $r.Proc.ExitCode) { $code = $r.Proc.ExitCode } } catch { }
            $missing += [pscustomobject]@{ Shard = $i; ExitCode = $code }
        }
    }
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue

    $elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    Write-Host ''
    if ($missing.Count -gt 0) {
        foreach ($m in $missing) {
            Write-Host "  worker shard $($m.Shard) produced no result summary (exit code $($m.ExitCode)); its cases did not run" -ForegroundColor Red
        }
        Write-Host "$totalPassed passed, $totalFailed failed, $($missing.Count) worker(s) did not report  (${elapsed}s)" -ForegroundColor Red
        exit 1
    }
    if ($totalFailed -gt 0) {
        Write-Host "$totalPassed passed, $totalFailed failed  (${elapsed}s)" -ForegroundColor Red
        exit 1
    }
    if ($totalPassed -eq 0) {
        Write-Host "no tests ran - the workers produced no results (${elapsed}s)" -ForegroundColor Red
        exit 1
    }
    Write-Host "$totalPassed passed, 0 failed  (${elapsed}s)" -ForegroundColor Green
    exit 0
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

function Set-GateState {
    # Seeds the enforcement state directly. Used only where reaching a state through real rounds
    # would cost dozens of process spawns and the accumulation itself is not what is under test;
    # the tests that DO cover accumulation (the 9-vs-10 attempt boundary, and two sessions
    # counting independently) still drive every round through the hook.
    param([string]$SessionId, [hashtable]$Values)
    $state = @{
        sessionId            = $SessionId
        createdAt            = (Get-Date).ToUniversalTime().ToString('o')
        updatedAt            = (Get-Date).ToUniversalTime().ToString('o')
        blocks               = 0
        totalInvocations     = 0
        architectureAttempts = 0
        architectureVerdict  = 'pending'
        securityAttempts     = 0
        securityVerdict      = 'pending'
        privacyAttempts      = 0
        privacyVerdict       = 'pending'
    }
    foreach ($key in $Values.Keys) { $state[$key] = $Values[$key] }
    $path = Get-StatePath $SessionId
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $path -Value ($state | ConvertTo-Json -Depth 5) -Encoding UTF8
}

function Set-StuckGate {
    # The common setup: one gate has spent its entire budget without passing.
    param([string]$SessionId, [string]$Gate = 'architecture')
    Set-GateState -SessionId $SessionId -Values @{
        "${Gate}Attempts" = 10
        "${Gate}Verdict"  = 'ISSUES'
        totalInvocations  = 10
    }
}

function New-SessionId {
    # A unique session id per test keeps state files from colliding.
    return "t$([guid]::NewGuid().ToString('N').Substring(0, 12))"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    # Round-robin the cases across workers. Every worker walks the whole file, so this stays a
    # plain linear script and no test needs to know it is being sharded.
    $script:CaseIndex++
    if ($ShardCount -gt 1 -and ($script:CaseIndex % $ShardCount) -ne $Shard) { return }
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

function Write-Section {
    # Section headers only make sense in a single ordered run; across workers they would repeat.
    param([string]$Name)
    if ($ShardCount -le 1) {
        Write-Host ''
        Write-Host $Name -ForegroundColor Cyan
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
Write-Section 'Verdict parsing (must read only the final meaningful line)'
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
Write-Section 'Fail-safes (a hook must never deny a tool call or crash)'
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

Test-Case 'semantically corrupt authoritative state falls back to the valid mirror' {
    $cases = @(
        @{ Name = 'non-numeric counter'; Property = 'blocks'; Value = 'bad' }
        @{ Name = 'negative counter'; Property = 'architectureAttempts'; Value = -1 }
        @{ Name = 'exponent-sized counter'; Property = 'totalInvocations'; Value = 1e30 }
        @{ Name = 'signed numeric string'; Property = 'blocks'; Value = '+5' }
        @{ Name = 'unknown verdict'; Property = 'architectureVerdict'; Value = 'PASSING' }
    )
    foreach ($case in $cases) {
        $sid = New-SessionId
        Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
        $corrupt = Get-Content -LiteralPath (Get-StatePath $sid) -Raw | ConvertFrom-Json
        $corrupt.PSObject.Properties[$case.Property].Value = $case.Value
        Set-Content -LiteralPath (Get-StatePath $sid) -Value ($corrupt | ConvertTo-Json -Depth 5) -Encoding UTF8

        $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
        Assert-Equal 'block' $stop.decision "$($case.Name) prevented mirror recovery"
        Assert-Match 'autodev-plan:autodev-security-review' $stop.reason
        $restored = Get-Content -LiteralPath (Get-StatePath $sid) -Raw | ConvertFrom-Json
        Assert-Equal 'PASS' $restored.architectureVerdict
        Assert-Equal 1 $restored.blocks
    }
}

Test-Case 'partial legacy state receives missing defaults' {
    $sid = New-SessionId
    $path = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $path -Encoding UTF8 -Value (@{
            sessionId = $sid
            architectureAttempts = '1'
            architectureVerdict = 'PASS'
            totalInvocations = '1'
        } | ConvertTo-Json)
    $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $stop.decision
    Assert-Match 'autodev-plan:autodev-security-review' $stop.reason
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
Write-Section 'Enforcement'
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
Write-Section 'Loop bounds'
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
    Set-StuckGate -SessionId $sid -Gate 'architecture'
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
    # Seeded one invocation short of the ceiling, so the next real round must trip it. This pins
    # the boundary exactly, where looping until the message appeared only proved it happened
    # eventually -- and cost forty round trips to do it.
    $sid = New-SessionId
    Set-GateState -SessionId $sid -Values @{
        totalInvocations     = 39
        architectureAttempts = 1; architectureVerdict = 'PASS'
        securityAttempts     = 1; securityVerdict = 'PASS'
        privacyAttempts      = 1; privacyVerdict = 'PASS'
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS')
    Assert-Match 'permitted reviewer invocations' $footer
}

Test-Case 'the session-wide ceiling does not fire one invocation early' {
    $sid = New-SessionId
    Set-GateState -SessionId $sid -Values @{
        totalInvocations     = 38
        architectureAttempts = 1; architectureVerdict = 'PASS'
        securityAttempts     = 1; securityVerdict = 'PASS'
        privacyAttempts      = 1; privacyVerdict = 'PASS'
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS')
    if ($footer -match 'permitted reviewer invocations') { throw 'the ceiling fired at 39 invocations' }
}

Test-Case 'the session-wide ceiling leaves room for every gate to spend its budget' {
    # If the ceiling were at or below (gates * per-gate budget) it would silently become the
    # real limit and the per-gate budget would never be reachable on the last gate.
    $sid = New-SessionId
    Set-GateState -SessionId $sid -Values @{
        totalInvocations     = 22
        architectureAttempts = 11; architectureVerdict = 'PASS'
        securityAttempts     = 11; securityVerdict = 'PASS'
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Gate 'privacy' -Verdict 'ISSUES')
    Assert-Match 'Attempt 1 of 10' $footer
    Assert-Match '9 attempt\(s\) remain' $footer 'the last gate must still get a full budget'
}

# ------------------------------------------------------------------------------------------
Write-Section 'Budget exhaustion actually stops the loop'
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
    Set-StuckGate -SessionId $sid
    $parsed = (Invoke-ReviewerTask -SessionId $sid -Gate 'architecture') | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
    Assert-Match 'out of budget' $parsed.permissionDecisionReason
    Assert-Match 'architecture' $parsed.permissionDecisionReason
}

Test-Case 'a reviewer is still permitted one attempt short of the cap' {
    # Guards the boundary from the other side: the deny must not start a round early.
    $sid = New-SessionId
    Set-GateState -SessionId $sid -Values @{ architectureAttempts = 9; architectureVerdict = 'ISSUES'; totalInvocations = 9 }
    Assert-Equal '{}' (Invoke-ReviewerTask -SessionId $sid -Gate 'architecture')
}

Test-Case 'a stuck gate also blocks moving on to a different reviewer' {
    # Skipping ahead to the next gate would produce a plan that never cleared architecture.
    $sid = New-SessionId
    Set-StuckGate -SessionId $sid
    $parsed = (Invoke-ReviewerTask -SessionId $sid -Gate 'security') | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
}

Test-Case 'the refusal does not spill over onto non-reviewer sub-agents' {
    # The orchestrator may still need explore or general-purpose agents to write up the
    # escalation, so only reviewer invocations are refused.
    $sid = New-SessionId
    Set-StuckGate -SessionId $sid
    foreach ($agent in @('explore', 'general-purpose', 'code-review', 'security-review')) {
        $args_ = "{`"agent_type`":`"$agent`",`"prompt`":`"go`"}"
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $args_ }) "'$agent' must still be allowed"
    }
}

Test-Case 'malformed task arguments never deny the tool call' {
    $sid = New-SessionId
    Set-StuckGate -SessionId $sid
    foreach ($bad in @('', 'not json at all', '{"no_agent_type":1}', '[]')) {
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $bad }) "toolArgs '$bad' must fail open"
    }
}

Test-Case 'reviewers are refused once the session-wide ceiling is reached' {
    $sid = New-SessionId
    Set-GateState -SessionId $sid -Values @{
        totalInvocations     = 40
        architectureAttempts = 1; architectureVerdict = 'PASS'
        securityAttempts     = 1; securityVerdict = 'PASS'
        privacyAttempts      = 1; privacyVerdict = 'ISSUES'
    }
    $parsed = (Invoke-ReviewerTask -SessionId $sid -Gate 'privacy') | ConvertFrom-Json
    Assert-Equal 'deny' $parsed.permissionDecision
    Assert-Match 'permitted reviewer invocations' $parsed.permissionDecisionReason
}

# ------------------------------------------------------------------------------------------
Write-Section 'Re-gate invalidation'
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
Write-Section 'Audit trail'
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
Write-Section 'Developer-visible artifacts under .autodev/'
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
    # not the normal enforcement source. Only the view/recovery checkpoint belongs in .autodev.
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

Test-Case 'losing authoritative state between reviewers recovers from the mirror' {
    # Regression: deleting COPILOT_HOME/autodev-plan mid-session made the next reviewer look like
    # the first gate. subagentStart then erased both logs and demanded architecture again.
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $auditBefore = Get-Content -LiteralPath (Get-AuditPath $sid) -Raw
    $feedbackBefore = Get-Content -LiteralPath (Get-FeedbackPath $sid) -Raw

    # Delete the whole tracker tree, matching the real incident -- not just the JSON file.
    Remove-Item -LiteralPath (Join-Path $script:Root 'autodev-plan') -Recurse -Force
    $ask = Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' } | ConvertFrom-Json
    Assert-Equal 'deny' $ask.permissionDecision 'gating must remain active during recovery'
    Start-Gate -SessionId $sid -Gate 'security'

    $recovered = Get-Content -LiteralPath (Get-StatePath $sid) -Raw | ConvertFrom-Json
    Assert-Equal 'PASS' $recovered.architectureVerdict 'the prior gate must survive recovery'
    Assert-Equal 1 $recovered.architectureAttempts
    Assert-Equal 'running' $recovered.securityVerdict 'the workflow must advance to security'
    Assert-Equal 1 $recovered.securityAttempts
    Assert-Equal 2 $recovered.totalInvocations

    $auditAfter = Get-Content -LiteralPath (Get-AuditPath $sid) -Raw
    $feedbackAfter = Get-Content -LiteralPath (Get-FeedbackPath $sid) -Raw
    Assert-Match 'architecture \| 1 \| completed \| PASS' $auditAfter
    Assert-Match 'security \| 1 \| invoked \| -' $auditAfter
    if (-not $auditAfter.Contains($auditBefore.TrimEnd())) {
        throw 'the prior audit rows were erased instead of preserved'
    }
    Assert-Equal $feedbackBefore $feedbackAfter 'starting security must preserve architecture feedback'
}

Test-Case 'agentStop recovers a missing authoritative state before enforcing' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    Remove-Item -LiteralPath (Join-Path $script:Root 'autodev-plan') -Recurse -Force

    $decisions = 1..6 | ForEach-Object {
        $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
        if ($stop.decision -eq 'block') {
            Assert-Match 'autodev-plan:autodev-security-review' $stop.reason
            '1'
        }
        else { '0' }
    }
    Assert-Equal '111110' ($decisions -join '') 'recovery must preserve the five-block surrender guard'
    if (-not (Test-Path -LiteralPath (Get-StatePath $sid))) {
        throw 'agentStop did not restore authoritative state from the mirror'
    }
}

Test-Case 'agentStop does not depend on the workspace audit directory' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $viewDir = Split-Path (Get-MirrorPath $sid) -Parent
    Remove-Item -LiteralPath $viewDir -Recurse -Force
    # Make recreation impossible: .autodev is a file, not a directory.
    Set-Content -LiteralPath $viewDir -Value 'occupied'

    $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $stop.decision 'an unavailable audit log must not swallow enforcement'
    Assert-Match 'autodev-plan:autodev-security-review' $stop.reason
}

Test-Case 'agentStop persists its counter to the mirror when external state cannot be recreated' {
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $stateRoot = Join-Path $script:Root 'autodev-plan'
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
    Set-Content -LiteralPath $stateRoot -Value 'occupied'

    $decisions = 1..6 | ForEach-Object {
        $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
        if ($stop.decision -eq 'block') { '1' } else { '0' }
    }
    Remove-Item -LiteralPath $stateRoot -Force
    Assert-Equal '111110' ($decisions -join '') 'the mirror must carry the block counter when external writes fail'
    $mirror = Get-Content -LiteralPath (Get-MirrorPath $sid) -Raw | ConvertFrom-Json
    Assert-Equal 5 $mirror.blocks
}

Test-Case 'a mirror from another session is never used for recovery' {
    $shared = Get-SessionCwd (New-SessionId)
    $first = New-SessionId
    Invoke-Hook 'subagentStart' @{ sessionId = $first; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
    Invoke-Hook 'subagentStop' @{ sessionId = $first; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "ok`n`nAUTODEV-VERDICT: PASS" } | Out-Null

    $second = New-SessionId
    Invoke-Hook 'subagentStart' @{ sessionId = $second; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
    $state = Get-Content -LiteralPath (Get-StatePath $second) -Raw | ConvertFrom-Json
    Assert-Equal 'running' $state.architectureVerdict
    Assert-Equal 1 $state.architectureAttempts 'a new session must start from attempt 1'
    Assert-Equal 1 $state.totalInvocations 'a new session must not inherit the old invocation count'
}

Test-Case 'two sessions in one directory keep independent attempt counters' {
    # This is what makes the caps real. If sessions shared one state file they would reset each
    # other and no gate would ever reach its limit. Every round here goes through the hook,
    # because real interleaved accumulation is exactly what is under test.
    $shared = Get-SessionCwd (New-SessionId)
    $a = New-SessionId
    $b = New-SessionId
    foreach ($i in 1..3) {
        foreach ($sid in @($a, $b)) {
            Invoke-Hook 'subagentStart' @{ sessionId = $sid; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
            Invoke-Hook 'subagentStop' @{ sessionId = $sid; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "finding`n`nAUTODEV-VERDICT: ISSUES" } | Out-Null
        }
    }
    foreach ($sid in @($a, $b)) {
        $state = Get-Content -LiteralPath (Get-StatePath $sid) -Raw | ConvertFrom-Json
        Assert-Equal 3 $state.architectureAttempts "session $sid lost attempts to the other session"
    }
    # Take one session to its cap; the other must keep its own budget.
    Set-GateState -SessionId $a -Values @{ architectureAttempts = 9; architectureVerdict = 'ISSUES'; totalInvocations = 9 }
    Invoke-Hook 'subagentStart' @{ sessionId = $a; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
    Invoke-Hook 'subagentStop' @{ sessionId = $a; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "finding`n`nAUTODEV-VERDICT: ISSUES" } | Out-Null

    $args2 = '{"agent_type":"autodev-plan:autodev-architecture-review"}'
    $denied = Invoke-Hook 'preToolUse' @{ sessionId = $a; cwd = $shared; toolName = 'task'; toolArgs = $args2 } | ConvertFrom-Json
    Assert-Equal 'deny' $denied.permissionDecision 'the session at its cap must be refused'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $b; cwd = $shared; toolName = 'task'; toolArgs = $args2 }) 'the other session must keep its own budget'
}

Test-Case 'the audit and feedback logs accumulate every invocation in a session' {
    $sid = New-SessionId
    1..3 | ForEach-Object { Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null }
    $rows = @((Get-Content -LiteralPath (Get-AuditPath $sid)) | Where-Object { $_ -match '^\|\s+\d{4}-' })
    Assert-Equal 6 $rows.Count 'three rounds must leave six rows, not one'
    $entries = @((Get-Content -LiteralPath (Get-FeedbackPath $sid)) | Where-Object { $_ -match '^# \w+ - attempt ' })
    Assert-Equal 3 $entries.Count 'three rounds must leave three feedback entries'
}

Test-Case 'zero-byte Markdown logs self-heal without disabling tracking' {
    $sid = New-SessionId
    $audit = Get-AuditPath $sid
    $feedback = Get-FeedbackPath $sid
    New-Item -ItemType Directory -Path (Split-Path $audit -Parent) -Force | Out-Null
    [IO.File]::WriteAllBytes($audit, [byte[]]@())
    [IO.File]::WriteAllBytes($feedback, [byte[]]@())

    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'ISSUES' | Out-Null

    $auditText = Get-Content -LiteralPath $audit -Raw
    $feedbackText = Get-Content -LiteralPath $feedback -Raw
    Assert-Match ([regex]::Escape("Session: ``$sid``")) $auditText
    Assert-Match 'architecture \| 1 \| invoked \| -' $auditText
    Assert-Match 'architecture \| 1 \| completed \| ISSUES' $auditText
    Assert-Match ([regex]::Escape("Session: ``$sid``")) $feedbackText
    Assert-Match '(?m)^# architecture - attempt 1 - ISSUES\r?$' $feedbackText
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

Test-Case 'a new session gets fresh state but preserves previous Markdown logs' {
    # State is per session, but human-readable history is append-only across sessions.
    $shared = Get-SessionCwd (New-SessionId)
    $first = New-SessionId
    foreach ($gate in @('architecture', 'security', 'privacy')) {
        Invoke-Hook 'subagentStart' @{ sessionId = $first; cwd = $shared; agentName = "autodev-plan:autodev-$gate-review" } | Out-Null
        Invoke-Hook 'subagentStop' @{ sessionId = $first; cwd = $shared; agentName = "autodev-plan:autodev-$gate-review"; response = "ok`n`nAUTODEV-VERDICT: PASS" } | Out-Null
    }
    $auditBefore = Get-Content -LiteralPath (Join-Path (Join-Path $shared '.autodev') 'gate-audit.md') -Raw
    $feedbackBefore = Get-Content -LiteralPath (Join-Path (Join-Path $shared '.autodev') 'feedback-log.md') -Raw

    $second = New-SessionId
    # Before the new session runs anything, its gates must read as untouched.
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $second; cwd = $shared; stopReason = 'end_turn' }) 'an idle session must not be blocked'

    Invoke-Hook 'subagentStart' @{ sessionId = $second; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null
    Invoke-Hook 'subagentStop' @{ sessionId = $second; cwd = $shared; agentName = 'autodev-plan:autodev-architecture-review'; response = "ok`n`nAUTODEV-VERDICT: PASS" } | Out-Null

    $audit = Join-Path (Join-Path $shared '.autodev') 'gate-audit.md'
    $feedback = Join-Path (Join-Path $shared '.autodev') 'feedback-log.md'
    $auditAfter = Get-Content -LiteralPath $audit -Raw
    $feedbackAfter = Get-Content -LiteralPath $feedback -Raw
    $rows = @(($auditAfter -split "`r?`n") | Where-Object { $_ -match '^\|\s+\d{4}-' })
    Assert-Equal 8 $rows.Count 'six prior lifecycle rows and two new rows must all remain'
    $entries = @(($feedbackAfter -split "`r?`n") | Where-Object { $_ -match '^# \w+ - attempt ' })
    Assert-Equal 4 $entries.Count 'all reviewer responses from both sessions must remain'
    if (-not $auditAfter.Contains($auditBefore.TrimEnd())) { throw 'the prior audit session was erased' }
    if (-not $feedbackAfter.Contains($feedbackBefore.TrimEnd())) { throw 'the prior feedback session was erased' }
    Assert-Match ([regex]::Escape("Session: ``$first``")) $auditAfter
    Assert-Match ([regex]::Escape("Session: ``$second``")) $auditAfter
    Assert-Match ([regex]::Escape("Session: ``$first``")) $feedbackAfter
    Assert-Match ([regex]::Escape("Session: ``$second``")) $feedbackAfter

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
Write-Section 'Hook wiring (hooks.json is what connects all of the above to the CLI)'
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

if ($script:IsWorker) {
    # Machine-readable tally for the dispatcher; it prints the human summary.
    Write-Output "RESULT $script:Passed $script:Failed"
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "$script:Passed passed, $script:Failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "$script:Passed passed, 0 failed" -ForegroundColor Green
exit 0
