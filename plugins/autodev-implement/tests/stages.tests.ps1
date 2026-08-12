<#
.SYNOPSIS
    Tests for the autodev-implement stage tracker (autodev-stages.ps1).

.DESCRIPTION
    Runs the hook script as a separate process for every case, exactly as the CLI does, feeding
    the hook payload on stdin and asserting on the single JSON object it writes to stdout.

    Tests run against an isolated COPILOT_HOME, and each test gets its own temporary working
    directory, so real session state is never touched. The tracker writes its developer-facing
    artifacts into '<cwd>/.autodev/', so a per-test cwd is what keeps tests isolated.

    Every assertion costs a process spawn (~1s: PowerShell startup plus the JSON cmdlets), so by
    default the suite shards itself across parallel workers. Use -Sequential for readable,
    grouped output when you are diagnosing a failure.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/stages.tests.ps1
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

$script:StageScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\scripts\autodev-stages.ps1'
$script:Root = Join-Path ([IO.Path]::GetTempPath()) "autodev-stage-tests-$PID"
$script:Passed = 0
$script:Failed = 0
$script:CaseIndex = -1
$script:IsWorker = ($Shard -ge 0)

# Must match the constants in autodev-stages.ps1.
$script:MaxReviewAttempts = 10
$script:MaxWorkerAttempts = 5
$script:MaxBlocks = 5
$script:TotalInvocationsBase = 120
$script:TotalInvocationsPerMilestone = 30

function Get-MaxTotal {
    # The session ceiling scales with the milestone count, so a large plan cannot be stranded
    # half-implemented by a fixed limit.
    param([int]$Milestones = 1)
    if ($Milestones -lt 1) { $Milestones = 1 }
    return ($script:TotalInvocationsBase + ($script:TotalInvocationsPerMilestone * $Milestones))
}

if (-not (Test-Path -LiteralPath $script:StageScript)) {
    Write-Host "Cannot find stage script at $script:StageScript" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------------------
# Dispatcher: fan the cases out across worker processes and aggregate.
# ------------------------------------------------------------------------------------------
if (-not $script:IsWorker -and -not $Sequential) {
    if ($Workers -le 0) { $Workers = [Math]::Min(8, [Environment]::ProcessorCount) }
    if ($Workers -lt 1) { $Workers = 1 }

    $outDir = Join-Path ([IO.Path]::GetTempPath()) "autodev-stage-shards-$PID"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Write-Host ''
    Write-Host "autodev-implement stage tracker tests (PowerShell), $Workers workers" -ForegroundColor Cyan
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

# ------------------------------------------------------------------------------------------
# Harness
# ------------------------------------------------------------------------------------------

function Get-SessionCwd {
    param([string]$SessionId)
    $dir = Join-Path $script:Root $SessionId
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-StatePath {
    param([string]$SessionId)
    # Enforcement state is keyed by session and lives outside the workspace.
    return (Join-Path (Join-Path $script:Root 'autodev-implement\stages') "$SessionId.json")
}

function Get-ViewPath {
    param([string]$SessionId, [string]$Leaf)
    return (Join-Path (Join-Path (Get-SessionCwd $SessionId) '.autodev') $Leaf)
}

function Set-TodoList {
    # Writes a todo list in the documented format. The tracker parses milestone headings from it
    # to learn how many milestones exist.
    param([string]$SessionId, [int]$Milestones, [string]$Status = 'complete')
    $dir = Join-Path (Get-SessionCwd $SessionId) '.autodev'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $lines = @('# Implementation todos', '')
    for ($i = 1; $i -le $Milestones; $i++) {
        $lines += "## Milestone $i - milestone $i"
        $lines += "**Status:** $Status"
        $lines += ''
    }
    Set-Content -LiteralPath (Join-Path $dir 'todos.md') -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
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
    $out = $json | powershell -NoProfile -ExecutionPolicy Bypass -File $script:StageScript $EventName
    return ($out | Out-String).Trim()
}

function Start-Agent {
    param([string]$SessionId, [string]$Agent)
    Invoke-Hook 'subagentStart' @{ sessionId = $SessionId; agentName = "autodev-implement:autodev-$Agent" } | Out-Null
}

function Stop-Agent {
    param([string]$SessionId, [string]$Agent, [string]$Response)
    return Invoke-Hook 'subagentStop' @{ sessionId = $SessionId; agentName = "autodev-implement:autodev-$Agent"; response = $Response }
}

function Invoke-Round {
    param([string]$SessionId, [string]$Agent, [string]$Verdict)
    Start-Agent -SessionId $SessionId -Agent $Agent
    return Stop-Agent -SessionId $SessionId -Agent $Agent -Response "Body text.`n`nAUTODEV-VERDICT: $Verdict"
}

function Invoke-TaskCheck {
    # preToolUse for a `task` call targeting one of this plugin's sub-agents.
    param([string]$SessionId, [string]$Agent)
    $taskArgs = @{ agent_type = "autodev-implement:autodev-$Agent" } | ConvertTo-Json -Compress
    return Invoke-Hook 'preToolUse' @{ sessionId = $SessionId; toolName = 'task'; toolArgs = $taskArgs }
}

function Get-Footer {
    param([string]$HookOutput)
    return ($HookOutput | ConvertFrom-Json).modifiedResponse
}

function Set-ImplState {
    # Seeds the enforcement state directly. Used only where reaching a state through real rounds
    # would cost dozens of process spawns and the accumulation itself is not what is under test;
    # the tests that DO cover accumulation (the review attempt boundary, and two sessions
    # counting independently) still drive every round through the hook.
    param([string]$SessionId, [hashtable]$Values)
    $state = @{
        sessionId           = $SessionId
        createdAt           = (Get-Date).ToUniversalTime().ToString('o')
        updatedAt           = (Get-Date).ToUniversalTime().ToString('o')
        blocks              = 0
        totalInvocations    = 0
        taskingAttempts     = 0
        taskingVerdict      = 'pending'
        milestoneCount      = 0
        currentMilestone    = 0
        completedMilestones = 0
        implementAttempts   = 0
        implementVerdict    = 'pending'
        reviewAttempts      = 0
        reviewVerdict       = 'pending'
        fixInvocations      = 0
        userReviewReached   = 0
        securityAttempts    = 0
        securityVerdict     = 'pending'
        privacyAttempts     = 0
        privacyVerdict      = 'pending'
        cappedMilestones    = ''
    }
    foreach ($key in $Values.Keys) { $state[$key] = $Values[$key] }
    $path = Get-StatePath $SessionId
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $path -Value ($state | ConvertTo-Json -Depth 5) -Encoding UTF8
}

function Set-StageState {
    # Convenience wrapper producing a state parked in a named stage, with one milestone that has
    # already closed unless the caller says otherwise.
    param([string]$SessionId, [string]$Stage, [hashtable]$Extra = @{})
    $values = @{
        taskingAttempts  = 1
        taskingVerdict   = 'DONE'
        milestoneCount   = 1
        currentMilestone = 1
        totalInvocations = 1
    }
    switch ($Stage) {
        'tasking' {
            $values['taskingVerdict'] = 'BLOCKED'
        }
        'milestones' {
            # Implementation is done, review has not passed yet.
            $values['implementAttempts'] = 1
            $values['implementVerdict'] = 'DONE'
        }
        'user-review' {
            $values['completedMilestones'] = 1
            $values['currentMilestone'] = 2
        }
        'security' {
            $values['completedMilestones'] = 1
            $values['currentMilestone'] = 2
            # The user checkpoint has been satisfied; without this the stage would resolve back
            # to 'user-review' and every assertion below it would be testing the wrong stage.
            $values['userReviewReached'] = 1
            $values['securityAttempts'] = 1
            $values['securityVerdict'] = 'ISSUES'
        }
        'privacy' {
            $values['completedMilestones'] = 1
            $values['currentMilestone'] = 2
            $values['userReviewReached'] = 1
            $values['securityAttempts'] = 1
            $values['securityVerdict'] = 'PASS'
            $values['privacyAttempts'] = 1
            $values['privacyVerdict'] = 'ISSUES'
        }
        'complete' {
            $values['completedMilestones'] = 1
            $values['currentMilestone'] = 2
            $values['userReviewReached'] = 1
            $values['securityAttempts'] = 1
            $values['securityVerdict'] = 'PASS'
            $values['privacyAttempts'] = 1
            $values['privacyVerdict'] = 'PASS'
        }
        'escalated' {
            $values['completedMilestones'] = 1
            $values['currentMilestone'] = 2
            $values['userReviewReached'] = 1
            $values['securityAttempts'] = $script:MaxReviewAttempts
            $values['securityVerdict'] = 'ISSUES'
        }
    }
    foreach ($key in $Extra.Keys) { $values[$key] = $Extra[$key] }
    Set-ImplState -SessionId $SessionId -Values $values
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

function Assert-NoMatch {
    param([string]$Pattern, [string]$Actual, [string]$Because = '')
    if ($Actual -match $Pattern) { throw "expected NO match for '$Pattern' but got '$Actual'. $Because" }
}

$env:COPILOT_HOME = $script:Root
# The CLI writes the hook payload as UTF-8, so the harness must too, or a non-ASCII test case
# would be mangled before it ever reached the script.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force }
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

Write-Host ''
Write-Host 'autodev-implement stage tracker tests (PowerShell)' -ForegroundColor Cyan
Write-Host "script: $script:StageScript"

# ------------------------------------------------------------------------------------------
Write-Section 'Verdict parsing (must read only the final meaningful line)'
# ------------------------------------------------------------------------------------------

$fence = '```'
$reviewVerdictCases = @(
    @{ Name = 'clean PASS'; Body = "Summary.`n`nAUTODEV-VERDICT: PASS"; Expect = 'PASS' }
    @{ Name = 'clean ISSUES'; Body = "Findings.`n`nAUTODEV-VERDICT: ISSUES"; Expect = 'ISSUES' }
    @{ Name = 'trailing blank lines'; Body = "AUTODEV-VERDICT: PASS`n`n`n"; Expect = 'PASS' }
    @{ Name = 'wrapped in a code fence'; Body = "text`n$fence`nAUTODEV-VERDICT: PASS`n$fence"; Expect = 'PASS' }
    @{ Name = 'bold markdown'; Body = "text`n`n**AUTODEV-VERDICT: PASS**"; Expect = 'PASS' }
    @{ Name = 'trailing period'; Body = "text`n`nAUTODEV-VERDICT: PASS."; Expect = 'PASS' }
    @{ Name = 'indented verdict line'; Body = "text`n`n    AUTODEV-VERDICT: PASS"; Expect = 'PASS' }
    # A reviewer that reaches for the worker vocabulary means something unambiguous, so it is
    # translated rather than charged an attempt for a wording mistake.
    @{ Name = 'reviewer saying DONE is read as PASS'; Body = "text`n`nAUTODEV-VERDICT: DONE"; Expect = 'PASS' }
    @{ Name = 'reviewer saying BLOCKED is read as ISSUES'; Body = "text`n`nAUTODEV-VERDICT: BLOCKED"; Expect = 'ISSUES' }
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

foreach ($case in $reviewVerdictCases) {
    $c = $case
    Test-Case "review verdict: $($c.Name)" {
        $sid = New-SessionId
        Set-TodoList -SessionId $sid -Milestones 2
        Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
        Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
        Start-Agent -SessionId $sid -Agent 'code-review'
        $footer = Get-Footer (Stop-Agent -SessionId $sid -Agent 'code-review' -Response $c.Body)
        Assert-Match "Recorded verdict: $($c.Expect)" $footer
    }.GetNewClosure()
}

$workerVerdictCases = @(
    @{ Name = 'clean DONE'; Body = "Summary.`n`nAUTODEV-VERDICT: DONE"; Expect = 'DONE' }
    @{ Name = 'clean BLOCKED'; Body = "Summary.`n`nAUTODEV-VERDICT: BLOCKED"; Expect = 'BLOCKED' }
    @{ Name = 'worker saying PASS is read as DONE'; Body = "text`n`nAUTODEV-VERDICT: PASS"; Expect = 'DONE' }
    @{ Name = 'worker saying ISSUES is read as BLOCKED'; Body = "text`n`nAUTODEV-VERDICT: ISSUES"; Expect = 'BLOCKED' }
    @{ Name = 'no verdict is not DONE'; Body = 'I wrote the file, honestly.'; Expect = 'BLOCKED' }
    @{ Name = 'empty response is not DONE'; Body = ''; Expect = 'BLOCKED' }
    @{ Name = 'commentary after the verdict'; Body = "AUTODEV-VERDICT: DONE`nActually there is more to do."; Expect = 'BLOCKED' }
)

foreach ($case in $workerVerdictCases) {
    $c = $case
    Test-Case "worker verdict: $($c.Name)" {
        $sid = New-SessionId
        Set-TodoList -SessionId $sid -Milestones 1
        Start-Agent -SessionId $sid -Agent 'tasking'
        $footer = Get-Footer (Stop-Agent -SessionId $sid -Agent 'tasking' -Response $c.Body)
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

Test-Case 'task with no state is permitted' {
    Assert-Equal '{}' (Invoke-TaskCheck -SessionId (New-SessionId) -Agent 'code-security-review')
}

foreach ($agent in @('explore', 'general-purpose', 'security-review', 'code-review', 'task', 'autodev-implement:autodev-implement')) {
    $a = $agent
    Test-Case "untracked sub-agent '$a' is ignored" {
        Assert-Equal '{}' (Invoke-Hook 'subagentStart' @{ sessionId = New-SessionId; agentName = $a })
    }.GetNewClosure()
}

# Both plugins can be installed at once and both watch subagentStart. Neither tracker may
# capture the other's reviewers, or a planning run would spend an implementation budget.
foreach ($agent in @('autodev-plan:autodev-architecture-review', 'autodev-plan:autodev-security-review', 'autodev-plan:autodev-privacy-review')) {
    $a = $agent
    Test-Case "autodev-plan reviewer '$a' is not captured" {
        $sid = New-SessionId
        Assert-Equal '{}' (Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = $a })
        Assert-Equal $false (Test-Path -LiteralPath (Get-StatePath $sid))
    }.GetNewClosure()
}

Test-Case 'code-review does not swallow code-security-review' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'security'
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-security-review' -Verdict 'PASS')
    Assert-Match 'Stage: code-security-review' $footer
    Assert-Match 'security=PASS' $footer
}

# Plugin agents are namespaced, so a suffix match would also capture another installed plugin's
# identically named agent and let it mutate this run's counters.
foreach ($agent in @('other-plugin:autodev-code-review', 'other:autodev-tasking', 'somewhere:autodev-code-security-review')) {
    $a = $agent
    Test-Case "an agent from another namespace ('$a') is not captured" {
        $sid = New-SessionId
        Assert-Equal '{}' (Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = $a })
        Assert-Equal $false (Test-Path -LiteralPath (Get-StatePath $sid))
    }.GetNewClosure()
}

Test-Case 'a task call to a same-named agent in another namespace is never refused' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    $taskArgs = @{ agent_type = 'other-plugin:autodev-code-security-review' } | ConvertTo-Json -Compress
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $taskArgs })
}

Test-Case 'an unnamespaced sub-agent name is still tracked' {
    # Only a *different* namespace is rejected; a bare name keeps working.
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = 'autodev-tasking' } | Out-Null
    Assert-Equal $true (Test-Path -LiteralPath (Get-StatePath $sid))
}

Test-Case 'garbage stdin returns empty JSON and exits 0' {
    $out = 'not json at all' | powershell -NoProfile -ExecutionPolicy Bypass -File $script:StageScript 'preToolUse'
    Assert-Equal '{}' (($out | Out-String).Trim())
    Assert-Equal 0 $LASTEXITCODE
}

Test-Case 'empty stdin returns empty JSON and exits 0' {
    $out = '' | powershell -NoProfile -ExecutionPolicy Bypass -File $script:StageScript 'preToolUse'
    Assert-Equal '{}' (($out | Out-String).Trim())
    Assert-Equal 0 $LASTEXITCODE
}

Test-Case 'an unknown event name fails open instead of denying the tool call' {
    # preToolUse is fail-closed on a non-zero exit, so a parameter-binding failure here would
    # deny the tool call outright.
    $out = '{"sessionId":"x"}' | powershell -NoProfile -ExecutionPolicy Bypass -File $script:StageScript 'bogusEvent' 2>&1
    Assert-Equal '{}' (($out | Out-String).Trim())
    Assert-Equal 0 $LASTEXITCODE
}

Test-Case 'a missing event name fails open instead of prompting' {
    # A mandatory parameter would make PowerShell prompt for input and hang the hook.
    $out = '{"sessionId":"x"}' | powershell -NoProfile -ExecutionPolicy Bypass -File $script:StageScript 2>&1
    Assert-Equal '{}' (($out | Out-String).Trim())
    Assert-Equal 0 $LASTEXITCODE
}

Test-Case 'corrupt state file does not deny ask_user or block stopping' {
    $sid = New-SessionId
    $statePath = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $statePath -Value '{ this is not json' -Encoding UTF8
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid })
}

Test-Case 'a state file with no owner is never adopted' {
    $sid = New-SessionId
    $statePath = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $statePath -Value '{"taskingAttempts":1,"taskingVerdict":"running"}' -Encoding UTF8
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
}

Test-Case 'state belonging to another session is never adopted' {
    $sid = New-SessionId
    $other = New-SessionId
    Set-ImplState -SessionId $other -Values @{ taskingAttempts = 1; taskingVerdict = 'running' }
    # Physically move the other session's file into this session's slot.
    Move-Item -LiteralPath (Get-StatePath $other) -Destination (Get-StatePath $sid) -Force
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
}

Test-Case 'a negative counter is rejected as corrupt' {
    $sid = New-SessionId
    $statePath = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $statePath -Value "{`"sessionId`":`"$sid`",`"taskingAttempts`":-4,`"taskingVerdict`":`"running`"}" -Encoding UTF8
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
}

Test-Case 'a corrupt authoritative file falls back to the valid mirror' {
    $sid = New-SessionId
    # A real run first, so a valid mirror exists in the workspace.
    Set-TodoList -SessionId $sid -Milestones 1
    Start-Agent -SessionId $sid -Agent 'tasking'
    # Now corrupt only the authoritative copy.
    Set-Content -LiteralPath (Get-StatePath $sid) -Value '{ not json' -Encoding UTF8
    $out = Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' }
    Assert-Match '"permissionDecision":"deny"' $out 'the mirror should have restored the in-progress run'
}

Test-Case 'partial legacy state receives missing defaults' {
    $sid = New-SessionId
    $statePath = Get-StatePath $sid
    New-Item -ItemType Directory -Path (Split-Path $statePath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $statePath -Value "{`"sessionId`":`"$sid`",`"taskingAttempts`":1,`"taskingVerdict`":`"running`"}" -Encoding UTF8
    $out = Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' }
    Assert-Match 'autonomous phase \(tasking\)' $out
}

Test-Case 'a hostile session id cannot escape the state directory' {
    $sid = '../../escaped'
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; cwd = (Get-SessionCwd 'hostile'); agentName = 'autodev-implement:autodev-tasking' } | Out-Null
    $escaped = Join-Path (Split-Path $script:Root -Parent) 'escaped.json'
    Assert-Equal $false (Test-Path -LiteralPath $escaped) 'state escaped the sandbox'
    Assert-Equal $true (Test-Path -LiteralPath (Get-StatePath '.._.._escaped'))
}

# ------------------------------------------------------------------------------------------
Write-Section 'The stage machine'
# ------------------------------------------------------------------------------------------

Test-Case 'a fresh session starts in tasking and names the tasking agent' {
    $sid = New-SessionId
    Start-Agent -SessionId $sid -Agent 'tasking'
    $out = Invoke-Hook 'agentStop' @{ sessionId = $sid }
    Assert-Match '"decision":"block"' $out
    Assert-Match 'autodev-tasking' $out
}

Test-Case 'tasking DONE moves to the first milestone and reports the parsed count' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 3
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE')
    Assert-Match 'Todo list parsed: 3 milestone\(s\)' $footer
    Assert-Match 'milestones=0/3 done' $footer
    Assert-Match 'autodev-implementation for milestone 1' $footer
}

Test-Case 'a todo list with no milestone headings is recorded as BLOCKED, not DONE' {
    # A DONE the tracker cannot act on would send the run into the milestone phase against an
    # unusable artifact, and would contradict its own warning by naming implementation next.
    $sid = New-SessionId
    $dir = Join-Path (Get-SessionCwd $sid) '.autodev'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'todos.md') -Value "# Todos`n`nJust some prose." -Encoding UTF8
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE')
    Assert-Match 'Recorded verdict: BLOCKED' $footer
    Assert-Match "does not contain '## Milestone <n>' headings" $footer
    Assert-Match "tasking=BLOCKED\(1/$script:MaxWorkerAttempts\)" $footer
    Assert-Match 'Re-invoke autodev-implement:autodev-tasking' $footer
    Assert-NoMatch 'autodev-implementation for milestone' $footer 'implementation must not be the next action'
}

Test-Case 'an unusable todo list still escalates at the tasking retry cap' {
    # The downgrade must charge the tasking budget, or a malformed todo list could be retried
    # forever without ever reaching escalation.
    $sid = New-SessionId
    $dir = Join-Path (Get-SessionCwd $sid) '.autodev'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'todos.md') -Value "# Todos`n`nNo milestones here." -Encoding UTF8
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts  = ($script:MaxWorkerAttempts - 1); taskingVerdict = 'BLOCKED'
        totalInvocations = 4
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE')
    Assert-Match 'escalate to the user' $footer
    Assert-Match "tasking stage used all $script:MaxWorkerAttempts permitted attempts" $footer
}

Test-Case 'a gap in the milestone numbering is rejected rather than miscounted' {
    # Milestones 1 and 3 counted naively would look like two milestones, and the run would go
    # hunting for a milestone 2 that does not exist while never building milestone 3.
    $sid = New-SessionId
    $dir = Join-Path (Get-SessionCwd $sid) '.autodev'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'todos.md') `
        -Value "## Milestone 1 - a`n**Status:** not-started`n`n## Milestone 3 - c`n**Status:** not-started`n" -Encoding UTF8
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE')
    Assert-Match 'numbered consecutively from 1' $footer
    Assert-Match 'Recorded verdict: BLOCKED' $footer
}

Test-Case 'a duplicated milestone number is rejected' {
    $sid = New-SessionId
    $dir = Join-Path (Get-SessionCwd $sid) '.autodev'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'todos.md') `
        -Value "## Milestone 1 - a`n**Status:** not-started`n`n## Milestone 1 - b`n**Status:** not-started`n" -Encoding UTF8
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE')
    Assert-Match 'Recorded verdict: BLOCKED' $footer
}

Test-Case 'a tasking DONE is trusted when there is no workspace to check it against' {
    # The tracker cannot read a todo list it has no directory for, so it must not fail the
    # agent for that -- it would lock an otherwise healthy run out of the milestone phase.
    $sid = New-SessionId
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; cwd = ''; agentName = 'autodev-implement:autodev-tasking' } | Out-Null
    $out = Invoke-Hook 'subagentStop' @{ sessionId = $sid; cwd = ''; agentName = 'autodev-implement:autodev-tasking'; response = "body`n`nAUTODEV-VERDICT: DONE" }
    $footer = Get-Footer $out
    Assert-Match 'Recorded verdict: DONE' $footer
    Assert-Match 'no workspace directory to read the todo list from' $footer
}

Test-Case 'a shrinking todo list cannot retire milestones that were never built' {
    # The todo list is in a directory the orchestrator may write to, so it must not be able to
    # end the run early by deleting the milestones it has not done yet.
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 3
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Set-TodoList -SessionId $sid -Milestones 1
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE')
    Assert-Match 'milestones=0/3 done' $footer
}

Test-Case 'a milestone closes only when its code review passes' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 2
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    $issues = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES')
    Assert-Match 'milestones=0/2 done' $issues
    Assert-Match 'autodev-code-fix' $issues
    $pass = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'PASS')
    Assert-Match 'milestones=1/2 done' $pass
    Assert-Match 'autodev-implementation for milestone 2' $pass
}

Test-Case 'the last milestone closing moves to the user review checkpoint' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'PASS')
    Assert-Match 'hand the code back for review' $footer
    Assert-Match 'Audit trail:' $footer
}

Test-Case 'security passing moves to privacy, privacy passing completes the run' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'user-review' -Extra @{ userReviewReached = 1 }
    $sec = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-security-review' -Verdict 'PASS')
    Assert-Match 'autodev-code-privacy-review' $sec
    $priv = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-privacy-review' -Verdict 'PASS')
    Assert-Match 'Proceed to WRAPUP' $priv
}

# ------------------------------------------------------------------------------------------
Write-Section 'The USER-REVIEW checkpoint is actually enforced'
# ------------------------------------------------------------------------------------------

Test-Case 'the security review is refused until the code has been handed to the user' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'user-review'
    $out = Invoke-TaskCheck -SessionId $sid -Agent 'code-security-review'
    Assert-Match '"permissionDecision":"deny"' $out
    Assert-Match 'has not been given the code to review yet' $out
}

Test-Case 'ending the turn at the checkpoint records the handoff and unlocks security' {
    # Closing the last milestone and starting the security review in the same turn would skip
    # the user entirely, so the stop itself is what satisfies the checkpoint.
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'user-review'
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid })
    Assert-Equal '{}' (Invoke-TaskCheck -SessionId $sid -Agent 'code-security-review')
}

Test-Case 'asking the user at the checkpoint also records the handoff' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'user-review'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
    Assert-Equal '{}' (Invoke-TaskCheck -SessionId $sid -Agent 'code-security-review')
}

Test-Case 'the handoff is recorded in the audit trail' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'user-review'
    Invoke-Hook 'agentStop' @{ sessionId = $sid } | Out-Null
    $audit = Get-Content -LiteralPath (Get-ViewPath $sid 'implement-gate-audit.md') -Raw
    Assert-Match 'handed to user' $audit
}

Test-Case 'fixing user-reported issues sends the run back to the checkpoint' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'user-review'
    Invoke-Hook 'agentStop' @{ sessionId = $sid } | Out-Null
    Invoke-Round -SessionId $sid -Agent 'code-fix' -Verdict 'DONE' | Out-Null
    $out = Invoke-TaskCheck -SessionId $sid -Agent 'code-security-review'
    Assert-Match '"permissionDecision":"deny"' $out 'the user must approve the fixed code too'
}

Test-Case 'a fix after the final reviews passed resequences back to security' {
    # The fix changed code that both reviews already judged, so their verdicts are stale.
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'complete'
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-fix' -Verdict 'DONE')
    Assert-Match 'security=pending' $footer
    Assert-Match 'privacy=pending' $footer
    Assert-Match 'autodev-code-security-review' $footer
    Assert-NoMatch 'hand the code back for review' $footer 'the user already approved this code'
}

Test-Case 'a fix during the privacy loop restarts security without refunding privacy rounds' {
    # Security must re-run because the code changed, but the privacy loop keeps its spent
    # budget: refunding it would make the loop unbounded.
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'privacy' -Extra @{ privacyAttempts = 4 }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-fix' -Verdict 'DONE')
    Assert-Match 'security=pending\(0/' $footer
    Assert-Match "privacy=ISSUES\(4/$script:MaxReviewAttempts\)" $footer
    Assert-Match 'autodev-code-security-review' $footer
}

Test-Case 'a fix during the security loop does not refund its rounds' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'security' -Extra @{ securityAttempts = 6 }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-fix' -Verdict 'DONE')
    Assert-Match "security=ISSUES\(6/$script:MaxReviewAttempts\)" $footer
}

Test-Case 'a security re-review invalidates a privacy verdict for the older code' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'complete'
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-security-review' -Verdict 'PASS')
    Assert-Match 'privacy=pending' $footer
    Assert-Match 'autodev-code-privacy-review' $footer
}

Test-Case 'an implementation DONE against an unfinished milestone status warns' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1 -Status 'in-progress'
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE')
    Assert-Match "still reads '\*\*Status:\*\* in-progress'" $footer
}

Test-Case 'a fix agent invocation does not consume a review attempt' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-fix' -Verdict 'DONE')
    Assert-Match "review=ISSUES\(1/$script:MaxReviewAttempts\)" $footer
}

Test-Case 'a review recorded before implementation cannot close the milestone' {
    # Ordering denies this call, but the tracker must not depend on that alone: a PASS about
    # code that did not exist yet would otherwise close the milestone the instant the
    # implementation agent finished, and the delivered code would never be reviewed.
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'PASS' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE')
    Assert-Match 'milestones=0/1 done' $footer
    Assert-Match 'review=pending\(0/' $footer
    Assert-Match 'autodev-code-review for milestone 1' $footer
}

Test-Case 'reviewing a milestone before it is implemented is refused' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones' -Extra @{ implementVerdict = 'pending'; implementAttempts = 0 }
    $out = Invoke-TaskCheck -SessionId $sid -Agent 'code-review'
    Assert-Match '"permissionDecision":"deny"' $out
    Assert-Match 'has not been implemented yet' $out
}

Test-Case 'implementing new code invalidates an earlier security and privacy pass' {
    # Those reviews judge the whole implementation, so a verdict predating new code is stale.
    # A stale PASS would let the run skip the USER-REVIEW checkpoint and the final reviews.
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 2
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts     = 1; taskingVerdict = 'DONE'
        milestoneCount      = 2; currentMilestone = 2; completedMilestones = 1
        securityAttempts    = 1; securityVerdict = 'PASS'
        privacyAttempts     = 1; privacyVerdict = 'PASS'
        totalInvocations    = 5
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE')
    Assert-Match 'security=pending' $footer
    Assert-Match 'privacy=pending' $footer
}

Test-Case 'a security pass recorded before tasking cannot skip the user review checkpoint' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'code-security-review' -Verdict 'PASS' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'PASS')
    Assert-Match 'security=pending' $footer
    Assert-Match 'hand the code back for review' $footer
}

# ------------------------------------------------------------------------------------------
Write-Section 'Blocking a premature stop'
# ------------------------------------------------------------------------------------------

foreach ($stage in @('tasking', 'milestones', 'security', 'privacy')) {
    $s = $stage
    Test-Case "agentStop is blocked during the autonomous '$s' stage" {
        $sid = New-SessionId
        Set-StageState -SessionId $sid -Stage $s
        Assert-Match '"decision":"block"' (Invoke-Hook 'agentStop' @{ sessionId = $sid })
    }.GetNewClosure()
}

foreach ($stage in @('user-review', 'complete', 'escalated')) {
    $s = $stage
    Test-Case "agentStop is permitted at '$s'" {
        $sid = New-SessionId
        Set-StageState -SessionId $sid -Stage $s
        Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid })
    }.GetNewClosure()
}

Test-Case 'the block reason names the exact next sub-agent' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    $out = Invoke-Hook 'agentStop' @{ sessionId = $sid }
    Assert-Match 'autodev-implement:autodev-code-review for milestone 1' $out
}

Test-Case 'the tracker surrenders after the block ceiling' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones' -Extra @{ blocks = $script:MaxBlocks }
    Assert-Equal '{}' (Invoke-Hook 'agentStop' @{ sessionId = $sid })
}

Test-Case 'real progress forgives earlier blocked stops' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones' -Extra @{ blocks = ($script:MaxBlocks - 1) }
    Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES' | Out-Null
    Assert-Match '"decision":"block"' (Invoke-Hook 'agentStop' @{ sessionId = $sid })
}

# ------------------------------------------------------------------------------------------
Write-Section 'ask_user is denied only while the run is autonomous'
# ------------------------------------------------------------------------------------------

foreach ($stage in @('tasking', 'milestones', 'security', 'privacy')) {
    $s = $stage
    Test-Case "ask_user is denied during '$s'" {
        $sid = New-SessionId
        Set-StageState -SessionId $sid -Stage $s
        Assert-Match '"permissionDecision":"deny"' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
    }.GetNewClosure()
}

foreach ($stage in @('user-review', 'complete', 'escalated')) {
    $s = $stage
    Test-Case "ask_user is permitted at '$s'" {
        $sid = New-SessionId
        Set-StageState -SessionId $sid -Stage $s
        Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'ask_user' })
    }.GetNewClosure()
}

Test-Case 'AskUserQuestion is denied the same way as ask_user' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    Assert-Match '"permissionDecision":"deny"' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'AskUserQuestion' })
}

Test-Case 'an unrelated tool is never denied while the run is autonomous' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'edit' })
}

# ------------------------------------------------------------------------------------------
Write-Section 'Out-of-order sub-agent invocations are refused'
# ------------------------------------------------------------------------------------------

$orderCases = @(
    @{ Stage = 'tasking'; Agent = 'implementation'; Expect = 'deny' }
    @{ Stage = 'tasking'; Agent = 'code-security-review'; Expect = 'deny' }
    @{ Stage = 'tasking'; Agent = 'tasking'; Expect = 'allow' }
    @{ Stage = 'tasking'; Agent = 'code-fix'; Expect = 'allow' }
    @{ Stage = 'milestones'; Agent = 'code-security-review'; Expect = 'deny' }
    @{ Stage = 'milestones'; Agent = 'code-privacy-review'; Expect = 'deny' }
    @{ Stage = 'milestones'; Agent = 'code-review'; Expect = 'allow' }
    @{ Stage = 'milestones'; Agent = 'code-fix'; Expect = 'allow' }
    @{ Stage = 'milestones'; Agent = 'implementation'; Expect = 'allow' }
    @{ Stage = 'user-review'; Agent = 'code-security-review'; Expect = 'deny' }
    @{ Stage = 'user-review'; Agent = 'code-fix'; Expect = 'allow' }
    @{ Stage = 'user-review'; Agent = 'code-privacy-review'; Expect = 'deny' }
    @{ Stage = 'user-review'; Agent = 'code-review'; Expect = 'deny' }
    @{ Stage = 'user-review'; Agent = 'implementation'; Expect = 'deny' }
    @{ Stage = 'security'; Agent = 'code-security-review'; Expect = 'allow' }
    @{ Stage = 'security'; Agent = 'code-fix'; Expect = 'allow' }
    @{ Stage = 'security'; Agent = 'code-privacy-review'; Expect = 'deny' }
    @{ Stage = 'privacy'; Agent = 'code-privacy-review'; Expect = 'allow' }
    @{ Stage = 'privacy'; Agent = 'code-fix'; Expect = 'allow' }
    @{ Stage = 'privacy'; Agent = 'code-security-review'; Expect = 'deny' }
    @{ Stage = 'complete'; Agent = 'code-fix'; Expect = 'allow' }
    @{ Stage = 'complete'; Agent = 'code-security-review'; Expect = 'allow' }
)

foreach ($case in $orderCases) {
    $c = $case
    Test-Case "ordering: $($c.Agent) during $($c.Stage) is $($c.Expect)ed" {
        $sid = New-SessionId
        Set-StageState -SessionId $sid -Stage $c.Stage
        $out = Invoke-TaskCheck -SessionId $sid -Agent $c.Agent
        if ($c.Expect -eq 'allow') { Assert-Equal '{}' $out }
        else { Assert-Match '"permissionDecision":"deny"' $out }
    }.GetNewClosure()
}

Test-Case 'starting the next milestone is refused while the current review is unresolved' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones' -Extra @{ reviewAttempts = 1; reviewVerdict = 'ISSUES' }
    Assert-Match '"permissionDecision":"deny"' (Invoke-TaskCheck -SessionId $sid -Agent 'implementation')
}

Test-Case 'a task call to an agent from another plugin is never refused' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    $taskArgs = @{ agent_type = 'autodev-plan:autodev-security-review' } | ConvertTo-Json -Compress
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $taskArgs })
}

Test-Case 'a task call to a built-in agent is never refused' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    $taskArgs = @{ agent_type = 'explore' } | ConvertTo-Json -Compress
    Assert-Equal '{}' (Invoke-Hook 'preToolUse' @{ sessionId = $sid; toolName = 'task'; toolArgs = $taskArgs })
}

Test-Case 're-tasking is refused once milestone work has started' {
    # Re-tasking rewrites the milestone list; a shorter one would retire milestones that were
    # never built.
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones'
    $out = Invoke-TaskCheck -SessionId $sid -Agent 'tasking'
    Assert-Match '"permissionDecision":"deny"' $out
    Assert-Match 'milestone work has already started' $out
}

Test-Case 're-tasking is still allowed before any milestone work has started' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'milestones' -Extra @{
        implementVerdict = 'pending'; implementAttempts = 0; reviewAttempts = 0; completedMilestones = 0
    }
    Assert-Equal '{}' (Invoke-TaskCheck -SessionId $sid -Agent 'tasking')
}

# ------------------------------------------------------------------------------------------
Write-Section 'Attempt caps'
# ------------------------------------------------------------------------------------------

Test-Case 'a code review at its cap closes the milestone and moves on' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 2
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts   = 1; taskingVerdict = 'DONE'
        milestoneCount    = 2; currentMilestone = 1
        implementAttempts = 1; implementVerdict = 'DONE'
        reviewAttempts    = ($script:MaxReviewAttempts - 1); reviewVerdict = 'ISSUES'
        totalInvocations  = 12
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES')
    Assert-Match "used all $script:MaxReviewAttempts code review rounds" $footer
    Assert-Match 'milestones=1/2 done' $footer
    Assert-Match 'autodev-implementation for milestone 2' $footer
    Assert-NoMatch 'escalate to the user' $footer 'code review proceeds rather than escalating'
}

Test-Case 'one round below the cap still loops rather than closing the milestone' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 2
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts   = 1; taskingVerdict = 'DONE'
        milestoneCount    = 2; currentMilestone = 1
        implementAttempts = 1; implementVerdict = 'DONE'
        reviewAttempts    = ($script:MaxReviewAttempts - 2); reviewVerdict = 'ISSUES'
        totalInvocations  = 11
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES')
    Assert-Match 'milestones=0/2 done' $footer
    Assert-Match 'autodev-code-fix' $footer
}

Test-Case 'the security review escalates at its cap instead of proceeding' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'security' -Extra @{
        securityAttempts = ($script:MaxReviewAttempts - 1)
        totalInvocations = 15
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-security-review' -Verdict 'ISSUES')
    Assert-Match 'escalate to the user' $footer
    Assert-Match "security review used all $script:MaxReviewAttempts permitted rounds" $footer
}

Test-Case 'the privacy review escalates at its cap' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'privacy' -Extra @{
        privacyAttempts  = ($script:MaxReviewAttempts - 1)
        totalInvocations = 20
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-privacy-review' -Verdict 'ISSUES')
    Assert-Match 'escalate to the user' $footer
    Assert-Match "privacy review used all $script:MaxReviewAttempts permitted rounds" $footer
}

Test-Case 'a tasking agent that keeps failing escalates at the worker cap' {
    $sid = New-SessionId
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts  = ($script:MaxWorkerAttempts - 1); taskingVerdict = 'BLOCKED'
        totalInvocations = 4
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'BLOCKED')
    Assert-Match 'escalate to the user' $footer
    Assert-Match "tasking stage used all $script:MaxWorkerAttempts permitted attempts" $footer
}

Test-Case 'an implementation agent that keeps failing escalates at the worker cap' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts   = 1; taskingVerdict = 'DONE'
        milestoneCount    = 1; currentMilestone = 1
        implementAttempts = ($script:MaxWorkerAttempts - 1); implementVerdict = 'BLOCKED'
        totalInvocations  = 6
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'BLOCKED')
    Assert-Match 'escalate to the user' $footer
    Assert-Match 'permitted implementation attempts' $footer
}

Test-Case 'the session-wide invocation ceiling escalates' {
    $sid = New-SessionId
    $ceiling = Get-MaxTotal 1
    Set-StageState -SessionId $sid -Stage 'milestones' -Extra @{ totalInvocations = ($ceiling - 1) }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES')
    Assert-Match "all $ceiling permitted sub-agent invocations" $footer
}

Test-Case 'the invocation ceiling scales so a large plan is never stranded' {
    # A fixed ceiling would cut a long run off before its milestones could spend their own
    # budgets, leaving the plan half-implemented -- the one outcome this workflow forbids.
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 8
    $worstCase = 1 + (8 * (1 + (2 * $script:MaxReviewAttempts))) + (2 * (2 * $script:MaxReviewAttempts))
    Set-ImplState -SessionId $sid -Values @{
        taskingAttempts   = 1; taskingVerdict = 'DONE'
        milestoneCount    = 8; currentMilestone = 1
        implementAttempts = 1; implementVerdict = 'DONE'
        totalInvocations  = $worstCase
    }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'ISSUES')
    Assert-NoMatch 'permitted sub-agent invocations' $footer 'the ceiling fired inside a legitimate run'
}

Test-Case 'every sub-agent invocation is refused once escalated' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'escalated'
    foreach ($agent in @('tasking', 'implementation', 'code-review', 'code-fix', 'code-security-review', 'code-privacy-review')) {
        Assert-Match '"permissionDecision":"deny"' (Invoke-TaskCheck -SessionId $sid -Agent $agent) "agent $agent"
    }
}

Test-Case 'a re-run security review after a pass starts a fresh budget' {
    $sid = New-SessionId
    Set-StageState -SessionId $sid -Stage 'complete' -Extra @{ securityAttempts = 7 }
    $footer = Get-Footer (Invoke-Round -SessionId $sid -Agent 'code-security-review' -Verdict 'PASS')
    Assert-Match "security=PASS\(1/$script:MaxReviewAttempts\)" $footer
}

Test-Case 'two sessions count their attempts independently' {
    $a = New-SessionId
    $b = New-SessionId
    foreach ($sid in @($a, $b)) {
        Set-TodoList -SessionId $sid -Milestones 1
        Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
        Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    }
    Invoke-Round -SessionId $a -Agent 'code-review' -Verdict 'ISSUES' | Out-Null
    Invoke-Round -SessionId $a -Agent 'code-review' -Verdict 'ISSUES' | Out-Null
    $footerA = Get-Footer (Invoke-Round -SessionId $a -Agent 'code-review' -Verdict 'ISSUES')
    $footerB = Get-Footer (Invoke-Round -SessionId $b -Agent 'code-review' -Verdict 'ISSUES')
    Assert-Match 'Attempt 3' $footerA
    Assert-Match 'Attempt 1' $footerB
}

# ------------------------------------------------------------------------------------------
Write-Section 'Workspace artifacts'
# ------------------------------------------------------------------------------------------

Test-Case 'an unrelated session never creates a .autodev directory' {
    $sid = New-SessionId
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; agentName = 'explore' } | Out-Null
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path (Get-SessionCwd $sid) '.autodev'))
}

Test-Case 'the audit trail records both lifecycle events with the milestone' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    $audit = Get-Content -LiteralPath (Get-ViewPath $sid 'implement-gate-audit.md') -Raw
    Assert-Match '\| tasking \| - \| 1 \| invoked \| - \|' $audit
    Assert-Match '\| implementation \| 1 \| 1 \| completed \| DONE \|' $audit
}

Test-Case 'closing a milestone is recorded in the audit trail' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'implementation' -Verdict 'DONE' | Out-Null
    Invoke-Round -SessionId $sid -Agent 'code-review' -Verdict 'PASS' | Out-Null
    $audit = Get-Content -LiteralPath (Get-ViewPath $sid 'implement-gate-audit.md') -Raw
    Assert-Match 'milestone-closed \(passed\)' $audit
}

Test-Case 'the feedback log captures the response verbatim' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Start-Agent -SessionId $sid -Agent 'tasking'
    Stop-Agent -SessionId $sid -Agent 'tasking' -Response "A distinctive finding about caching.`n`nAUTODEV-VERDICT: DONE" | Out-Null
    $log = Get-Content -LiteralPath (Get-ViewPath $sid 'implement-feedback-log.md') -Raw
    Assert-Match 'A distinctive finding about caching' $log
}

Test-Case 'a non-ASCII response survives the round trip' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Start-Agent -SessionId $sid -Agent 'tasking'
    $footer = Get-Footer (Stop-Agent -SessionId $sid -Agent 'tasking' -Response "Use an en dash - and a curly quote here.`n`nAUTODEV-VERDICT: DONE")
    Assert-Match 'en dash - and a curly quote here' $footer
}

Test-Case 'the state mirror is written next to the todo list' {
    $sid = New-SessionId
    Set-TodoList -SessionId $sid -Milestones 1
    Invoke-Round -SessionId $sid -Agent 'tasking' -Verdict 'DONE' | Out-Null
    $mirror = Get-Content -LiteralPath (Get-ViewPath $sid 'implement-status.json') -Raw | ConvertFrom-Json
    Assert-Equal $sid $mirror.sessionId
    Assert-Equal 'DONE' $mirror.taskingVerdict
}

Test-Case 'the tracker still enforces when there is no workspace to write to' {
    $sid = New-SessionId
    # No cwd at all: the view directory falls back to the state directory, and enforcement must
    # still work.
    Invoke-Hook 'subagentStart' @{ sessionId = $sid; cwd = ''; agentName = 'autodev-implement:autodev-tasking' } | Out-Null
    Assert-Match '"decision":"block"' (Invoke-Hook 'agentStop' @{ sessionId = $sid; cwd = '' })
}

# ------------------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------------------

Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:IsWorker) {
    # The dispatcher parses this line; it must be the only RESULT line a worker prints.
    Write-Host "RESULT $script:Passed $script:Failed"
    exit 0
}
if ($script:Failed -gt 0) {
    Write-Host "$script:Passed passed, $script:Failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "$script:Passed passed, 0 failed" -ForegroundColor Green
exit 0
