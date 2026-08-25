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

# ------------------------------------------------------------------------------------------
Write-Section 'Fast path (the cheap "nothing to enforce" answer must match the parsed one)'
# ------------------------------------------------------------------------------------------
#
# agentStop fires at the end of every turn and preToolUse on every ask_user or task call, in
# every session in every repository the plugin is installed in, so both answer "no workflow is
# running" without paying for ConvertFrom-Json, Join-Path or Test-Path. These cases pin that
# shortcut to the behaviour of the fully parsed path it stands in for.

Test-Case 'a stray mirror in the shared state directory does not mask a live session' {
    # The state-directory mirror is the fallback for sessions with no usable cwd, so it is NOT
    # keyed by session: one left behind by any earlier run is visible to every later one. The
    # fast path must therefore consult the same single location Get-ViewDirectory would choose.
    # An earlier revision tested both candidates "to be safe" and this file switched enforcement
    # onto the slow path for the whole machine, permanently.
    $stray = Join-Path (Join-Path $script:Root 'autodev-plan\gates') 'gate-status.json'
    New-Item -ItemType Directory -Path (Split-Path $stray -Parent) -Force | Out-Null
    Set-Content -LiteralPath $stray -Value '{"sessionId":"someone-else","architectureVerdict":"PASS"}'
    try {
        $sid = New-SessionId
        Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
        $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; stopReason = 'end_turn' } | ConvertFrom-Json
        Assert-Equal 'block' $stop.decision 'a stray mirror must not weaken a real session'
        Assert-Match 'autodev-plan:autodev-security-review' $stop.reason
    }
    finally { Remove-Item -LiteralPath $stray -Force -ErrorAction SilentlyContinue }
}

Test-Case 'a stray mirror in the state directory still lets an unrelated session stop' {
    # Same file, seen by a session that never started a gate and sends no cwd, so the state
    # directory IS its view directory. The shortcut declines to answer and the parsed path must
    # reject the stray mirror on its session id, as it always has.
    $stray = Join-Path (Join-Path $script:Root 'autodev-plan\gates') 'gate-status.json'
    New-Item -ItemType Directory -Path (Split-Path $stray -Parent) -Force | Out-Null
    Set-Content -LiteralPath $stray -Value '{"sessionId":"someone-else","architectureVerdict":"PASS"}'
    try {
        $json = @{ sessionId = New-SessionId; stopReason = 'end_turn' } | ConvertTo-Json -Compress
        $out = $json | powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript agentStop
        Assert-Equal '{}' (($out | Out-String).Trim())
    }
    finally { Remove-Item -LiteralPath $stray -Force -ErrorAction SilentlyContinue }
}

Test-Case 'a workspace path needing JSON unescaping still resolves to the same answer' {
    # cwd reaches the hook as JSON, so every Windows separator arrives as '\\'. Decoding that
    # by hand is the price of skipping ConvertFrom-Json; getting it wrong would look at the
    # wrong directory for the mirror.
    $sid = New-SessionId
    $cwd = Join-Path $script:Root "fast path $sid"
    New-Item -ItemType Directory -Path $cwd -Force | Out-Null
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid; cwd = $cwd; stopReason = 'end_turn' })

    Invoke-Hook 'subagentStart' @{ sessionId = $sid; cwd = $cwd; agentName = 'autodev-plan:autodev-architecture-review' } | Out-Null

    # Drop the authoritative state so the mirror under the escaped path is the only enforcement
    # state left. Without this the shortcut answers on the state file and never reads 'cwd' at
    # all, and a broken decoder would still pass.
    Remove-Item -LiteralPath (Get-StatePath $sid) -Force
    $stop = Invoke-Hook 'agentStop' @{ sessionId = $sid; cwd = $cwd; stopReason = 'end_turn' } | ConvertFrom-Json
    Assert-Equal 'block' $stop.decision 'the mirror under an escaped path must still be found'
}

Test-Case 'a session id that is not a plain JSON string still reaches the parsed path' {
    # ConvertFrom-Json stringifies a number; the shortcut deliberately refuses to guess how,
    # because checking the wrong file would walk straight past a live gate.
    $sid = New-SessionId
    Invoke-Round -SessionId $sid -Gate 'architecture' -Verdict 'PASS' | Out-Null
    $cwd = Get-SessionCwd $sid
    $json = '{"sessionId":' + $sid + ',"cwd":' + ($cwd | ConvertTo-Json) + ',"stopReason":"end_turn"}'
    $out = ($json | powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript agentStop | Out-String).Trim()
    # A numeric id names no state file, so the answer is '{}' either way. What is under test is
    # that it is reached without crashing and without the shortcut inventing a file name.
    Assert-Equal '{}' $out
}

Test-Case 'a nested sessionId cannot be mistaken for the real one' {
    # toolArgs is an arbitrary object, so a tool call can carry its own "sessionId" key. Reading
    # that one would name a state file belonging to nobody, find it missing, and conclude there
    # was nothing to enforce -- while a real gate was outstanding.
    $sid = New-SessionId
    Start-Gate -SessionId $sid -Gate 'architecture'
    $cwd = Get-SessionCwd $sid
    $json = '{"toolArgs":{"sessionId":"not-a-real-session","prompt":"x"},"sessionId":' +
    ($sid | ConvertTo-Json) + ',"cwd":' + ($cwd | ConvertTo-Json) + ',"toolName":"ask_user"}'
    $out = ($json | powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript preToolUse | Out-String).Trim()
    Assert-Match '"permissionDecision":"deny"' $out 'a nested key must not disable enforcement'
}

Test-Case 'the fast path never creates anything in the workspace' {
    # Confirm-Directory is only supposed to run once a real gate has been identified. The
    # shortcut runs before that and must not litter '.autodev' into an unrelated repository.
    $sid = New-SessionId
    $cwd = Get-SessionCwd $sid
    Invoke-Hook 'agentStop' @{ sessionId = $sid; cwd = $cwd; stopReason = 'end_turn' } | Out-Null
    Invoke-Hook 'preToolUse' @{ sessionId = $sid; cwd = $cwd; toolName = 'ask_user' } | Out-Null
    if (Test-Path -LiteralPath (Join-Path $cwd '.autodev')) {
        throw 'the fast path created .autodev in a workspace with no run in progress'
    }
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
Write-Section 'OpenTelemetry span emission'
# ------------------------------------------------------------------------------------------

function Get-TelemetryDir {
    param([string]$SessionId)
    $dir = Join-Path $script:Root "otel-$SessionId"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Invoke-HookWithEnv {
    # Runs the hook with extra environment variables set only for that invocation, so telemetry
    # configuration cannot leak between cases running in the same worker.
    param([string]$EventName, [hashtable]$Payload, [hashtable]$EnvVars)
    $saved = @{}
    foreach ($key in $EnvVars.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $EnvVars[$key])
    }
    try {
        return Invoke-Hook $EventName $Payload
    }
    finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
}

function Invoke-TelemetryRound {
    <#
        Drives one full subagentStart/subagentStop round with the debug sink enabled and returns
        the hook output plus every span document that was written.
    #>
    param(
        [string]$SessionId,
        [string]$Gate = 'architecture',
        [string]$Verdict = 'ISSUES',
        [hashtable]$ExtraEnv = @{},
        [string]$AgentId = 'agent-1',
        [string]$Enabler = 'COPILOT_OTEL_ENABLED',
        [switch]$SkipStart
    )
    $dir = Get-TelemetryDir $SessionId
    $sink = Join-Path $dir 'spans.jsonl'
    # Note: PowerShell variable names are case insensitive, so this must not be called '$env'
    # or it would alias the $ExtraEnv parameter.
    $vars = @{ AUTODEV_OTEL_DEBUG_FILE = $sink }
    $vars[$Enabler] = 'true'
    foreach ($key in $ExtraEnv.Keys) { $vars[$key] = $ExtraEnv[$key] }

    $agentName = "autodev-plan:autodev-$Gate-review"
    if (-not $SkipStart) {
        Invoke-HookWithEnv 'subagentStart' @{ sessionId = $SessionId; agentName = $agentName } $vars | Out-Null
    }
    $output = Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $SessionId
        agentName = $agentName
        agentId   = $AgentId
        response  = "Body text.`n`nAUTODEV-VERDICT: $Verdict"
    } $vars

    $spans = @()
    if (Test-Path -LiteralPath $sink) {
        foreach ($line in @(Get-Content -LiteralPath $sink)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $spans += ($line | ConvertFrom-Json) }
        }
    }
    return [pscustomobject]@{ Output = $output; Spans = $spans; SinkPath = $sink }
}

function Get-SpanAttribute {
    param($Document, [string]$Key)
    $span = $Document.resourceSpans[0].scopeSpans[0].spans[0]
    foreach ($attr in $span.attributes) {
        if ($attr.key -eq $Key) {
            if ($null -ne $attr.value.stringValue) { return [string]$attr.value.stringValue }
            return [string]$attr.value.intValue
        }
    }
    return $null
}

Test-Case 'telemetry is off by default and writes nothing' {
    $session = New-SessionId
    $dir = Get-TelemetryDir $session
    $sink = Join-Path $dir 'spans.jsonl'
    # No enabling variable at all: the overwhelmingly common case. AUTODEV_OTEL_DEBUG_FILE is the
    # debug sink, not a switch, so on its own it must not turn telemetry on.
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = 'autodev-plan:autodev-architecture-review' } @{ AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
    $out = Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session
        agentName = 'autodev-plan:autodev-architecture-review'
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } @{ AUTODEV_OTEL_DEBUG_FILE = $sink }
    if (Test-Path -LiteralPath $sink) { throw 'a span was emitted while telemetry was disabled' }
    Assert-Match 'gate tracker' (Get-Footer $out) 'the footer must be unaffected'
}

Test-Case 'AUTODEV_OTEL_ENABLED alone turns telemetry on' {
    <#
        THE production path, and the one that shipped broken. Copilot CLI removes every variable
        whose name begins with 'OTEL_' or 'COPILOT_OTEL_' from a command hook's environment, so a
        hook keyed off COPILOT_OTEL_ENABLED could never fire under the CLI however the user had
        configured Copilot's own exporter. This case pins the behaviour with Copilot's variables
        absent, exactly as a real hook sees them.
    #>
    $result = Invoke-TelemetryRound -SessionId (New-SessionId) -Enabler 'AUTODEV_OTEL_ENABLED'
    Assert-Equal 1 $result.Spans.Count 'AUTODEV_OTEL_ENABLED must emit a span on its own'
    Assert-Equal 'ISSUES' (Get-SpanAttribute $result.Spans[0] 'autodev.verdict')
}

Test-Case 'an AUTODEV endpoint alone turns telemetry on' {
    # Configuring an endpoint for this emitter is itself an opt-in. Demanding a second variable
    # alongside it would fail silently, which is the failure mode this whole area is guarding.
    foreach ($name in @('AUTODEV_OTEL_ENDPOINT', 'AUTODEV_OTEL_TRACES_ENDPOINT')) {
        $session = New-SessionId
        $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
        $vars = @{ AUTODEV_OTEL_DEBUG_FILE = $sink }
        $vars[$name] = 'http://127.0.0.1:4318/v1/traces'
        $agentName = 'autodev-plan:autodev-architecture-review'
        Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
        Invoke-HookWithEnv 'subagentStop' @{
            sessionId = $session; agentName = $agentName
            response  = "x`n`nAUTODEV-VERDICT: ISSUES"
        } $vars | Out-Null
        if (-not (Test-Path -LiteralPath $sink)) { throw "$name alone must enable telemetry" }
    }
}

Test-Case 'an AUTODEV endpoint outranks a more specific legacy one' {
    <#
        On a host that does NOT scrub Copilot's variables both namespaces can be set at once. The
        AUTODEV_OTEL_* value has to win even against the more specific legacy name, or an
        inherited OTEL_EXPORTER_OTLP_TRACES_ENDPOINT would silently redirect spans away from the
        endpoint configured for this emitter -- and carry the AUTODEV_OTEL_HEADERS credentials
        with it.

        Observed with a loopback socket rather than a stub, because the PowerShell emitter posts
        in-process with Invoke-RestMethod and there is no external command to intercept.
    #>
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $session = New-SessionId
        $agentName = 'autodev-plan:autodev-architecture-review'
        $vars = @{
            AUTODEV_OTEL_ENABLED               = 'true'
            AUTODEV_OTEL_ENDPOINT              = "http://127.0.0.1:$port"
            # Deliberately more specific than the AUTODEV base endpoint. If precedence were wrong
            # the request would go here instead and nothing would reach the listener.
            OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = 'http://127.0.0.1:9/v1/traces'
            OTEL_EXPORTER_OTLP_ENDPOINT        = 'http://127.0.0.1:9'
        }
        Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
        # Nothing accepts the connection while the hook runs, and nothing needs to: the listen
        # backlog completes the TCP handshake and buffers the request, so the emitter's POST is
        # still readable afterwards. It sits out its own 2s timeout waiting for a reply that never
        # comes, which it swallows -- exactly the "collector is unreachable" path.
        $out = Invoke-HookWithEnv 'subagentStop' @{
            sessionId = $session; agentName = $agentName; agentId = 'a1'
            response  = "x`n`nAUTODEV-VERDICT: ISSUES"
        } $vars
        Assert-Match 'gate tracker' (Get-Footer $out) 'an unanswered collector must not disturb the footer'

        if (-not $listener.Pending()) {
            throw 'nothing connected to the AUTODEV endpoint, so a legacy OTEL_* endpoint outranked it'
        }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $buffer = New-Object byte[] 4096
            $read = $stream.Read($buffer, 0, $buffer.Length)
            $request = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            Assert-Match 'POST /v1/traces' $request 'the traces path must be appended to the base endpoint'
        }
        finally { $client.Close() }
    }
    finally { $listener.Stop() }
}

Test-Case 'a padded, mixed-case enabling value still emits' {
    <#
        The hook's own gate and the emitter's gate are separate implementations of one decision,
        and they must agree on awkward values: a gate stricter than the emitter drops the span
        without ever spawning it, while a looser one spawns a process that only exits again.
        Whitespace and casing are where they most easily drift apart.
    #>
    $result = Invoke-TelemetryRound -SessionId (New-SessionId) -Enabler 'AUTODEV_OTEL_ENABLED' `
        -ExtraEnv @{ AUTODEV_OTEL_ENABLED = "  TrUe`t" }
    Assert-Equal 1 $result.Spans.Count 'a padded, mixed-case value must enable telemetry'
}

Test-Case 'AUTODEV_OTEL_SERVICE_NAME sets and outranks the service name' {
    <#
        AUTODEV_OTEL_SERVICE_NAME is the only one of the pair a hook can actually see: Copilot CLI
        scrubs OTEL_SERVICE_NAME along with every other OTEL_ prefixed name. Covered in both
        suites because the bash emitter read only the scrubbed name, leaving every span stamped
        'github-copilot' however the user configured it.
    #>
    $cases = @(
        @{ Env = @{ AUTODEV_OTEL_SERVICE_NAME = 'my-service' }; Expected = 'my-service'; Why = 'AUTODEV_OTEL_SERVICE_NAME must set the resource service.name' },
        @{ Env = @{ AUTODEV_OTEL_SERVICE_NAME = 'autodev-wins'; OTEL_SERVICE_NAME = 'legacy-loses' }; Expected = 'autodev-wins'; Why = 'AUTODEV_OTEL_SERVICE_NAME must outrank OTEL_SERVICE_NAME' },
        @{ Env = @{ OTEL_SERVICE_NAME = 'legacy-only' }; Expected = 'legacy-only'; Why = 'OTEL_SERVICE_NAME must still work as a fallback' },
        @{ Env = @{}; Expected = 'github-copilot'; Why = 'the default service name must survive' }
    )
    foreach ($case in $cases) {
        $result = Invoke-TelemetryRound -SessionId (New-SessionId) -Enabler 'AUTODEV_OTEL_ENABLED' `
            -ExtraEnv $case.Env
        Assert-Equal 1 $result.Spans.Count 'the round must emit a span'
        $resource = $result.Spans[0].resourceSpans[0].resource
        $actual = $null
        foreach ($attr in $resource.attributes) {
            if ($attr.key -eq 'service.name') { $actual = [string]$attr.value.stringValue }
        }
        Assert-Equal $case.Expected $actual $case.Why
    }
}

Test-Case 'a whitespace-only enabling value falls through rather than forcing off' {
    <#
        Pins the boundary of the tri-state. An empty or whitespace-only AUTODEV_OTEL_ENABLED counts
        as NOT SET, so the remaining signals still decide; only a falsy value is an explicit off.

        Not an arbitrary choice: Windows does not carry an empty variable across a process
        boundary, so the hook and the emitter -- both child processes -- receive
        AUTODEV_OTEL_ENABLED= as unset however the parent shell set it. Treating it as an off
        switch would work in bash and quietly do nothing in PowerShell, which is the exact
        platform divergence this emitter exists to avoid. Whitespace is treated as absent for
        every other variable here as well, endpoints included.
    #>
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{
        AUTODEV_OTEL_ENABLED    = '   '
        AUTODEV_OTEL_ENDPOINT   = 'http://127.0.0.1:4318'
        AUTODEV_OTEL_DEBUG_FILE = $sink
    }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } $vars | Out-Null
    if (-not (Test-Path -LiteralPath $sink)) {
        throw 'a whitespace-only value must fall through to the endpoint signal, not force telemetry off'
    }
}

Test-Case 'autodev.issues counts the reported findings' {
    <#
        The attribute is a COUNT of findings, not a flag: "did this gate come back dirty" is
        already answered by autodev.verdict = ISSUES, so a flag here would be redundant and the
        name would be actively misleading. Counted from the '### [severity] title' heading every
        reviewer agent is required to emit.
    #>
    $response = @(
        '## Findings',
        '',
        '### [major] First problem',
        '**Problem:** one',
        '',
        '### [major] Second problem',
        '**Problem:** two',
        '',
        '### [minor] Third problem',
        '**Problem:** three',
        '',
        'AUTODEV-VERDICT: ISSUES'
    ) -join "`n"
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{ AUTODEV_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName; agentId = 'a1'; response = $response
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal '3' (Get-SpanAttribute $doc 'autodev.issues') 'every reported finding must be counted'
    Assert-Equal 'ISSUES' (Get-SpanAttribute $doc 'autodev.verdict')
}

Test-Case 'an ISSUES verdict never reports zero findings' {
    <#
        The count is parsed from a format the reviewer is instructed to use but could deviate from.
        If it does, the gate must not look clean in a dashboard: a formatting slip would otherwise
        become a silently missing finding, which is the failure mode this attribute exists to
        surface. Clamped to 1 instead.
    #>
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{ AUTODEV_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName; agentId = 'a1'
        response  = "I found problems but did not use the heading format.`n`nAUTODEV-VERDICT: ISSUES"
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.issues') 'an unparseable ISSUES verdict must still count 1'
}

Test-Case 'a clean PASS reports zero findings' {
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{ AUTODEV_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName; agentId = 'a1'
        response  = "No problems found.`n`nAUTODEV-VERDICT: PASS"
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal '0' (Get-SpanAttribute $doc 'autodev.issues') 'a clean pass must count no findings'
    Assert-Equal 'PASS' (Get-SpanAttribute $doc 'autodev.verdict')
}

Test-Case 'prose and template echoes do not inflate the finding count' {
    <#
        Two ways a naive count would over-report: a reviewer discussing "[minor]" in a sentence,
        and one echoing the literal '### [blocker|major|minor|nit]' template line from its own
        instructions. A deeper '####' heading is not a finding either.
    #>
    $response = @(
        'This is a [minor] concern worth mentioning inline.',
        '### [blocker|major|minor|nit] <short finding title>',
        '#### [major] a sub-heading, not a finding',
        '',
        '### [nit] The only real finding',
        '',
        'AUTODEV-VERDICT: ISSUES'
    ) -join "`n"
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{ AUTODEV_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName; agentId = 'a1'; response = $response
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.issues') 'only the real heading counts'
}

Test-Case 'a falsy AUTODEV_OTEL_ENABLED overrides every other signal' {
    <#
        Tri-state on purpose: an explicit OFF has to outrank both a configured endpoint and
        Copilot's own switch, so hook telemetry can be silenced without disturbing Copilot's
        exporter or unsetting an endpoint.
    #>
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{
        AUTODEV_OTEL_ENABLED  = 'false'
        AUTODEV_OTEL_ENDPOINT = 'http://127.0.0.1:4318'
        COPILOT_OTEL_ENABLED  = 'true'
        AUTODEV_OTEL_DEBUG_FILE = $sink
    }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    $out = Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } $vars
    if (Test-Path -LiteralPath $sink) { throw 'an explicit AUTODEV_OTEL_ENABLED=false must win' }
    Assert-Match 'gate tracker' (Get-Footer $out) 'the footer must be unaffected'
}

Test-Case 'an enabled round emits exactly one well-formed span document' {
    $result = Invoke-TelemetryRound -SessionId (New-SessionId)
    Assert-Equal 1 $result.Spans.Count 'exactly one span per subagentStop'
    $span = $result.Spans[0].resourceSpans[0].scopeSpans[0].spans[0]
    Assert-Match '^[0-9a-f]{32}$' $span.traceId 'traceId must be 16 lowercase hex bytes'
    Assert-Match '^[0-9a-f]{16}$' $span.spanId 'spanId must be 8 lowercase hex bytes'
    if ($span.traceId -match '^0+$') { throw 'an all-zero trace id is invalid' }
    if ($span.spanId -match '^0+$') { throw 'an all-zero span id is invalid' }
    # OTLP/JSON encodes every int64 as a decimal string; a JSON number would lose precision.
    if ($span.startTimeUnixNano -isnot [string]) { throw 'startTimeUnixNano must be a JSON string' }
    if ($span.endTimeUnixNano -isnot [string]) { throw 'endTimeUnixNano must be a JSON string' }
    if ([long]$span.startTimeUnixNano -gt [long]$span.endTimeUnixNano) {
        throw 'span starts after it ends'
    }
    Assert-Equal 'autodev.gate architecture' $span.name
    Assert-Equal 'github-copilot' $result.Spans[0].resourceSpans[0].resource.attributes[0].value.stringValue
}

Test-Case 'autodev.blocked is present and zero for a gate' {
    <#
        The response used here carries no finding headings, so autodev.issues exercises the clamp
        that keeps an ISSUES verdict from ever reporting zero. The finding COUNT itself is covered
        by the dedicated cases above.
    #>
    $issues = Invoke-TelemetryRound -SessionId (New-SessionId) -Verdict 'ISSUES'
    Assert-Equal '1' (Get-SpanAttribute $issues.Spans[0] 'autodev.issues')
    Assert-Equal 'ISSUES' (Get-SpanAttribute $issues.Spans[0] 'autodev.verdict')
    # A gate never reports BLOCKED, but the attribute must still be present and zero so a query
    # summing it does not have to special-case this plugin.
    Assert-Equal '0' (Get-SpanAttribute $issues.Spans[0] 'autodev.blocked')

    $pass = Invoke-TelemetryRound -SessionId (New-SessionId) -Verdict 'PASS'
    Assert-Equal '0' (Get-SpanAttribute $pass.Spans[0] 'autodev.issues')
    Assert-Equal 'PASS' (Get-SpanAttribute $pass.Spans[0] 'autodev.verdict')
}

Test-Case 'the span carries the identifiers a backend needs to correlate' {
    $result = Invoke-TelemetryRound -SessionId (New-SessionId) -Gate 'security' -AgentId 'agent-xyz'
    $doc = $result.Spans[0]
    Assert-Equal 'autodev-plan' (Get-SpanAttribute $doc 'autodev.plugin')
    Assert-Equal 'security' (Get-SpanAttribute $doc 'autodev.gate')
    Assert-Equal 'agent-xyz' (Get-SpanAttribute $doc 'github.copilot.agent.id')
    Assert-Equal 'autodev-plan:autodev-security-review' (Get-SpanAttribute $doc 'github.copilot.agent.name')
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.attempt')
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.total_invocations')
}

Test-Case 'the exported session id is the raw one, not the filename-safe one' {
    # Copilot puts the session id on its own spans as gen_ai.conversation.id. Exporting the
    # sanitized form used for filenames would silently break that join for any session id
    # containing a character the sanitizer rewrites.
    $rawSession = 'sess:with/unsafe chars'
    $dir = Join-Path $script:Root ('otel-raw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $sink = Join-Path $dir 'spans.jsonl'
    $vars = @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $rawSession; cwd = $dir; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $rawSession; cwd = $dir; agentName = $agentName; agentId = 'a1'
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal $rawSession (Get-SpanAttribute $doc 'gen_ai.conversation.id')
    Assert-Equal $rawSession (Get-SpanAttribute $doc 'github.copilot.session.id')
}

Test-Case 'a stop without its start still counts as an invocation' {
    # A stop with no matching start is already recovered as attempt 1. The session total must be
    # recovered too, or the span would export a total of zero for an invocation that
    # demonstrably completed.
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    # Deliberately no Start-Gate.
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = 'autodev-plan:autodev-architecture-review'; agentId = 'a1'
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.attempt')
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.total_invocations') `
        'a completed invocation must never export a session total of zero'
    $state = Get-Content -LiteralPath (Get-StatePath $session) -Raw | ConvertFrom-Json
    Assert-Equal 1 ([int]$state.totalInvocations) `
        'the recovered invocation must also be counted against the session ceiling'
}

Test-Case 'a traceparent parents the span under Copilot''s trace' {
    # The payload carries no trace context today, but the emitter already consumes it, so the day
    # the CLI starts supplying one these spans join Copilot's trace with no code change.
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId   = $session; agentName = $agentName; agentId = 'a1'
        traceparent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
        tracestate  = 'vendor=abc'
        response    = "x`n`nAUTODEV-VERDICT: ISSUES"
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    $span = $doc.resourceSpans[0].scopeSpans[0].spans[0]
    Assert-Equal '4bf92f3577b34da6a3ce929d0e0e4736' $span.traceId 'the span must join the trace id from traceparent'
    Assert-Equal '00f067aa0ba902b7' $span.parentSpanId 'the span must hang off the parent span id'
    Assert-Equal 'vendor=abc' $span.traceState
    Assert-Match '^[0-9a-f]{16}$' $span.spanId
    if ($span.spanId -eq '00f067aa0ba902b7') { throw 'the span reused the parent id as its own' }
}

Test-Case 'no traceparent still emits a correlatable root span' {
    # Today's behaviour: no context, so the span is its own root and correlates by session id.
    $result = Invoke-TelemetryRound -SessionId (New-SessionId)
    $span = $result.Spans[0].resourceSpans[0].scopeSpans[0].spans[0]
    Assert-Match '^[0-9a-f]{32}$' $span.traceId
    if ($null -ne $span.parentSpanId) { throw 'a span with no trace context must not claim a parent' }
}

Test-Case 'a malformed traceparent falls back to a root span' {
    # A malformed or reserved header must not produce an invalid parent reference.
    $session = New-SessionId
    $bad = @(
        'garbage',
        'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
        '00-00000000000000000000000000000000-00f067aa0ba902b7-01',
        '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01',
        '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01',
        # trace-flags is required, not optional.
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7',
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-zz',
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0',
        # Version 00 permits no extension fields.
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra',
        '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-'
    )
    foreach ($tp in $bad) {
        $sink = Join-Path (Get-TelemetryDir $session) 'bad.jsonl'
        Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
        Invoke-HookWithEnv 'subagentStop' @{
            sessionId   = $session; agentName = 'autodev-plan:autodev-architecture-review'
            agentId     = 'a1'; traceparent = $tp
            response    = "x`n`nAUTODEV-VERDICT: ISSUES"
        } @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
        $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
        $span = $doc.resourceSpans[0].scopeSpans[0].spans[0]
        if ($null -ne $span.parentSpanId) { throw "traceparent '$tp' must be rejected rather than used" }
        Assert-Equal 'ISSUES' (Get-SpanAttribute $doc 'autodev.verdict') "the verdict must still be exported for '$tp'"
    }
}

Test-Case 'the span marks the instant the verdict was recorded' {
    <#
        The span is deliberately zero length: it marks when the verdict was recorded, and the
        sub-agent's duration belongs to Copilot's own span, which measures it in-process. A
        sentinel timestamp proves the value comes from the PAYLOAD -- without one, the emitter's
        current-clock fallback also yields plausible digits, so a regression that ignored payload
        timestamps entirely would go undetected.
    #>
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'instant.jsonl'
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = 'autodev-plan:autodev-architecture-review'
        agentId   = 'a1'; timestamp = 1700000000123
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    $span = $doc.resourceSpans[0].scopeSpans[0].spans[0]
    Assert-Equal '1700000000123000000' $span.startTimeUnixNano 'the span must use the payload timestamp'
    Assert-Equal '1700000000123000000' $span.endTimeUnixNano 'the span marks an instant, not a duration'
}

Test-Case 'a sampled parent''s decision is carried onto the span' {
    # OTLP carries the W3C trace flags in the low 8 bits of span.flags, and an omitted field reads
    # as 0. Without this, a child of a sampled '01' parent would export as unsampled and a tail
    # sampler would drop exactly the spans worth keeping. Bits 8-9 (768) mark is_remote
    # valid + true, which it is: the parent span belongs to the CLI process.
    $session = New-SessionId
    $tp = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-'
    foreach ($case in @(@{ Flags = '01'; Expect = 769 }, @{ Flags = '00'; Expect = 768 })) {
        $sink = Join-Path (Get-TelemetryDir $session) "flags-$($case.Flags).jsonl"
        Invoke-HookWithEnv 'subagentStop' @{
            sessionId   = $session; agentName = 'autodev-plan:autodev-architecture-review'
            agentId     = 'a1'; traceparent = ($tp + $case.Flags)
            response    = "x`n`nAUTODEV-VERDICT: ISSUES"
        } @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
        $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
        $span = $doc.resourceSpans[0].scopeSpans[0].spans[0]
        Assert-Equal $case.Expect $span.flags "traceparent flags '$($case.Flags)' must be carried through"
    }

    # A root span has no inherited context, so it reports no flags at all.
    $sink = Join-Path (Get-TelemetryDir $session) 'flags-root.jsonl'
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = 'autodev-plan:autodev-architecture-review'
        agentId   = 'a1'; response = "x`n`nAUTODEV-VERDICT: ISSUES"
    } @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    if ($null -ne $doc.resourceSpans[0].scopeSpans[0].spans[0].flags) {
        throw 'a root span must not claim inherited flags'
    }
}

Test-Case 'a later traceparent version with extension fields is still honoured' {
    # The spec tells future-unaware parsers to read the first four fields and ignore the rest, so
    # a version above 00 must keep working rather than silently losing parentage.
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId   = $session; agentName = 'autodev-plan:autodev-architecture-review'
        agentId     = 'a1'
        traceparent = '01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-future'
        response    = "x`n`nAUTODEV-VERDICT: ISSUES"
    } @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink } | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    $span = $doc.resourceSpans[0].scopeSpans[0].spans[0]
    Assert-Equal '4bf92f3577b34da6a3ce929d0e0e4736' $span.traceId
    Assert-Equal '00f067aa0ba902b7' $span.parentSpanId
}

Test-Case 'a malformed timestamp cannot break the hook' {
    <#
        The request hashtable is built by the tracker before Send-OtelSpan is entered, so it sits
        outside that function's try/catch. Casting the payload timestamp there would throw under
        $ErrorActionPreference = 'Stop' on a non-numeric value, and the outer catch would emit
        '{}' instead of the tracker footer -- destroying enforcement output over telemetry.
        Checked with telemetry both off and on, because the hashtable is built either way.
    #>
    foreach ($enabled in @($null, 'true')) {
        $session = New-SessionId
        $vars = @{ COPILOT_OTEL_ENABLED = $enabled }
        if ($enabled) {
            $vars['AUTODEV_OTEL_DEBUG_FILE'] = (Join-Path (Get-TelemetryDir $session) 'spans.jsonl')
        }
        $out = Invoke-HookWithEnv 'subagentStop' @{
            sessionId = $session
            agentName = 'autodev-plan:autodev-architecture-review'
            agentId   = 'a1'
            timestamp = 'not-a-number'
            response  = "Body text.`n`nAUTODEV-VERDICT: ISSUES"
        } $vars
        $footer = Get-Footer $out
        Assert-Match 'gate tracker' $footer "the footer must survive a malformed timestamp (enabled=$enabled)"
        Assert-Match 'Recorded verdict: ISSUES' $footer
    }
}

Test-Case 'an empty agentId does not shift the other span attributes' {
    <#
        The bash emitter reads all its fields from one jq call. Splitting that on newline as IFS
        collapsed an empty field and shifted every later value left, so an absent agentId put the
        attempt count in autodev.verdict and reported autodev.issues=0 for an ISSUES verdict.
        Both emitters are covered so the two implementations cannot diverge here.
    #>
    $session = New-SessionId
    $sink = Join-Path (Get-TelemetryDir $session) 'spans.jsonl'
    $vars = @{ COPILOT_OTEL_ENABLED = 'true'; AUTODEV_OTEL_DEBUG_FILE = $sink }
    $agentName = 'autodev-plan:autodev-architecture-review'
    Invoke-HookWithEnv 'subagentStart' @{ sessionId = $session; agentName = $agentName } $vars | Out-Null
    # No agentId at all, which is what the tracker forwards when the payload omits it.
    Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session; agentName = $agentName
        response  = "x`n`nAUTODEV-VERDICT: ISSUES"
    } $vars | Out-Null
    $doc = (Get-Content -LiteralPath $sink | Select-Object -First 1) | ConvertFrom-Json
    Assert-Equal 'ISSUES' (Get-SpanAttribute $doc 'autodev.verdict') 'verdict must survive an empty agentId'
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.issues') 'the issue count must survive an empty agentId'
    Assert-Equal 'autodev-plan' (Get-SpanAttribute $doc 'autodev.plugin')
    Assert-Equal 'architecture' (Get-SpanAttribute $doc 'autodev.gate')
    Assert-Equal '1' (Get-SpanAttribute $doc 'autodev.attempt')
}

Test-Case 'a grpc-configured exporter emits nothing' {
    # We cannot speak gRPC from a script, and posting JSON at a gRPC port would be meaningless
    # traffic rather than a dropped span.
    $result = Invoke-TelemetryRound -SessionId (New-SessionId) -ExtraEnv @{ OTEL_EXPORTER_OTLP_PROTOCOL = 'grpc' }
    Assert-Equal 0 $result.Spans.Count 'grpc must suppress export entirely'
    Assert-Match 'gate tracker' (Get-Footer $result.Output) 'the footer must be unaffected'
}

Test-Case 'telemetry never alters the hook output or exit code' {
    <#
        The safety property the whole design exists for. A telemetry child that writes to stdout
        and stderr and exits non-zero must leave the hook byte-for-byte identical to a run with
        telemetry off. This is what would catch an emitter being sourced in-process, or its
        output leaking into the single JSON document the CLI parses.
    #>
    $session = New-SessionId
    $baseline = Invoke-Hook 'subagentStop' @{
        sessionId = $session
        agentName = 'autodev-plan:autodev-architecture-review'
        agentId   = 'a1'
        response  = "Body text.`n`nAUTODEV-VERDICT: ISSUES"
    }

    # Replace the emitter with one that misbehaves as badly as it can, in a private copy of the
    # scripts directory so the real emitter is untouched.
    $sandbox = Join-Path $script:Root ('otel-hostile-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Copy-Item -LiteralPath $script:GateScript -Destination (Join-Path $sandbox 'autodev-gates.ps1')
    Set-Content -LiteralPath (Join-Path $sandbox 'autodev-otel.ps1') -Encoding UTF8 -Value @'
param([string]$PayloadPath)
Write-Output '{"permissionDecision":"deny"}'
Write-Output 'stray text that would break JSON parsing'
[Console]::Error.WriteLine('exploding')
exit 3
'@

    $session2 = New-SessionId
    $payload = @{
        sessionId = $session2
        cwd       = (Get-SessionCwd $session2)
        agentName = 'autodev-plan:autodev-architecture-review'
        agentId   = 'a1'
        response  = "Body text.`n`nAUTODEV-VERDICT: ISSUES"
    } | ConvertTo-Json -Compress
    $previous = [Environment]::GetEnvironmentVariable('COPILOT_OTEL_ENABLED')
    [Environment]::SetEnvironmentVariable('COPILOT_OTEL_ENABLED', 'true')
    try {
        $raw = $payload | powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $sandbox 'autodev-gates.ps1') subagentStop
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Environment]::SetEnvironmentVariable('COPILOT_OTEL_ENABLED', $previous)
    }
    $hostile = ($raw | Out-String).Trim()

    Assert-Equal 0 $exitCode 'a failing telemetry child must not change the exit code'
    # Exactly one JSON document, and it must still be the tracker footer rather than the stray
    # decision object the hostile emitter tried to inject.
    $parsed = $hostile | ConvertFrom-Json
    if ($null -ne $parsed.permissionDecision) { throw 'the telemetry child leaked a decision into hook output' }
    Assert-Match 'gate tracker' $parsed.modifiedResponse 'the footer must survive'
    # Session ids differ between the two runs, so compare the shape rather than the bytes.
    Assert-Equal ((Get-Footer $baseline) -replace $session, 'S') ($parsed.modifiedResponse -replace $session2, 'S') `
        'telemetry must not change the hook output at all'
}

Test-Case 'an unreachable collector leaves the hook output intact' {
    # No debug sink, so the emitter takes the real network path against a closed port.
    $session = New-SessionId
    $vars = @{
        COPILOT_OTEL_ENABLED        = 'true'
        OTEL_EXPORTER_OTLP_ENDPOINT = 'http://127.0.0.1:9'
        AUTODEV_OTEL_TIMEOUT_SEC    = '1'
    }
    $out = Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session
        agentName = 'autodev-plan:autodev-architecture-review'
        agentId   = 'a1'
        response  = "Body text.`n`nAUTODEV-VERDICT: ISSUES"
    } $vars
    Assert-Match 'gate tracker' (Get-Footer $out) 'the footer must survive a failed export'
    Assert-Match 'Recorded verdict: ISSUES' (Get-Footer $out)
}

Test-Case 'a malformed endpoint is rejected rather than used' {
    $session = New-SessionId
    $vars = @{ COPILOT_OTEL_ENABLED = 'true'; OTEL_EXPORTER_OTLP_ENDPOINT = 'file:///tmp/nope' }
    $out = Invoke-HookWithEnv 'subagentStop' @{
        sessionId = $session
        agentName = 'autodev-plan:autodev-architecture-review'
        agentId   = 'a1'
        response  = "Body text.`n`nAUTODEV-VERDICT: PASS"
    } $vars
    Assert-Match 'gate tracker' (Get-Footer $out) 'a non-http scheme must be ignored, not attempted'
}

Test-Case 'enforcement still works with telemetry enabled' {
    # Proves the emitter is strictly additive: the attempt budget, verdict recording and
    # escalation all behave exactly as they do without it.
    $session = New-SessionId
    $result = Invoke-TelemetryRound -SessionId $session -Verdict 'PASS'
    Assert-Match 'Recorded verdict: PASS' (Get-Footer $result.Output)
    Assert-Match 'autodev-security-review' (Get-Footer $result.Output) 'the next gate must still be named'
    $state = Get-Content -LiteralPath (Get-StatePath $session) -Raw | ConvertFrom-Json
    Assert-Equal 'PASS' $state.architectureVerdict
    Assert-Equal 1 $state.architectureAttempts
    Assert-Equal 1 $state.architectureAttempts 'the attempt must still be recorded'
}

Test-Case 'the emitter ships beside the gate script' {
    # hooks.json invokes the gate script by path and the gate script finds the emitter next to
    # itself, so a missing copy would silently disable telemetry for the whole plugin.
    $emitterPs = Join-Path (Split-Path $script:GateScript -Parent) 'autodev-otel.ps1'
    $emitterSh = Join-Path (Split-Path $script:GateScript -Parent) 'autodev-otel.sh'
    if (-not (Test-Path -LiteralPath $emitterPs)) { throw "missing $emitterPs" }
    if (-not (Test-Path -LiteralPath $emitterSh)) { throw "missing $emitterSh" }
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
