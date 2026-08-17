<#
.SYNOPSIS
    Stage tracker for the autodev-implement plugin (Windows / PowerShell).

.DESCRIPTION
    Invoked by hooks.json for four hook events. Reads the hook payload as JSON on stdin and
    writes exactly one JSON object to stdout.

    Responsibilities:
      * subagentStart - record that an implementation stage was invoked; increment its attempt
                        counter; refresh the milestone count from the todo list.
      * subagentStop  - parse the sub-agent's verdict, record it, advance the milestone machine,
                        log the sub-agent's full response, and append a tracker footer to the
                        response the orchestrator receives.
      * agentStop     - block the orchestrator from ending its turn mid-run. The USER-REVIEW
                        checkpoint is deliberately exempt: waiting for the human is the point.
      * preToolUse    - deny ask_user during autonomous phases, deny out-of-order sub-agent
                        invocations, and deny further reviewer invocations once a budget is spent.

    Enforcement state lives at '<COPILOT_HOME>/autodev-implement/stages/<sessionId>.json', outside
    the workspace and keyed by session. That matters for two reasons: concurrent sessions in one
    repository must not clobber each other's attempt counters, and the orchestrator is allowed to
    edit files in the workspace, so state it could rewrite would not be enforcement at all.

    A mirror of that state, the audit trail and the sub-agent feedback log are written into
    '<session cwd>/.autodev/' so a developer can watch a run in progress and read the reviews
    afterwards, next to the plan and todo list. Audit and feedback are records only. The state
    mirror is read only as an exact-session recovery checkpoint when authoritative state is
    missing or corrupt; normal enforcement always prefers the external state.

    Milestone *structure* (how many milestones exist) is read from '.autodev/todos.md', which is
    the only place it can come from. Milestone *progress* is driven entirely by this script's
    out-of-workspace counters, so editing the todo list cannot skip a review.

    SAFETY: preToolUse command hooks are fail-closed - any non-zero exit or crash denies the
    tool call. A bug here would permanently break ask_user for the user, so every path is
    wrapped and this script always emits valid JSON and always exits 0.

    Written for Windows PowerShell 5.1 compatibility (no -AsHashtable, no ternaries, no
    three-argument Join-Path).
#>

param(
    # Deliberately unvalidated and non-mandatory. A [ValidateSet] or [Parameter(Mandatory)] is
    # enforced during parameter binding, which happens *before* the try block below, so an
    # unexpected event name would exit non-zero with no JSON on stdout -- and preToolUse is
    # fail-closed, so that would deny the tool call. A missing argument would be worse still:
    # a mandatory parameter makes PowerShell prompt and the hook would hang. The event name is
    # validated inside the protected main block instead.
    [string]$EventName
)

$ErrorActionPreference = 'Stop'

# Review loops (code review per milestone, security, privacy). Per pass.
$script:MaxReviewAttempts = 10
# Worker retries (tasking, implementation of one milestone). Per pass.
$script:MaxWorkerAttempts = 5
# Kept below the CLI's own 8-block runaway guard so we surrender first.
$script:MaxBlocks = 5
# Absolute ceiling across every stage, as a base plus a per-milestone allowance. It must stay
# above what a legitimate run can spend, or it would fire before the per-stage budgets could and
# would silently become the real limit -- which would strand a large plan half-implemented, and
# leaving work undone is the one outcome this workflow exists to prevent. The per-milestone
# worst case is 1 implementation + MaxReviewAttempts reviews + MaxReviewAttempts fixes = 21, and
# the fixed overhead is tasking plus the security and privacy loops = 41.
$script:TotalInvocationsBase = 120
$script:TotalInvocationsPerMilestone = 30

# Stages that run without human input. ask_user is denied and premature stops are blocked in
# these; every other stage is either interactive, finished, or escalated.
$script:AutonomousStages = @('tasking', 'milestones', 'security', 'privacy')

function Get-StateDirectory {
    # Enforcement state stays outside the workspace, keyed by session id. Two sessions running
    # in the same repository must not share a state file, and the orchestrator must not be able
    # to edit its way past a review.
    #
    # This resolves a path but deliberately does NOT create anything; see Confirm-Directory.
    $home_ = $env:COPILOT_HOME
    if ([string]::IsNullOrWhiteSpace($home_)) {
        $profileDir = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileDir)) { $profileDir = $HOME }
        $home_ = Join-Path $profileDir '.copilot'
    }
    return (Join-Path (Join-Path $home_ 'autodev-implement') 'stages')
}

function Get-ViewDirectory {
    # Where the developer-facing artifacts go: '.autodev' beside the plan and the todo list.
    # Returns an empty string when there is no usable working directory, in which case the
    # caller falls back to the state directory.
    param([string]$Cwd)
    if (-not [string]::IsNullOrWhiteSpace($Cwd) -and (Test-Path -LiteralPath $Cwd -PathType Container)) {
        return (Join-Path $Cwd '.autodev')
    }
    return ''
}

function Confirm-Directory {
    # Called only once a real autodev-implement sub-agent has been identified, so directories
    # appear exactly when the workflow starts using them. Creating them on every hook event
    # would litter an empty '.autodev' into any repository where an unrelated session called the
    # task tool.
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

# Numeric and string state keys, declared once so reading, validating and defaulting stay in
# step. Adding a counter here is all that is needed for it to be persisted and validated.
$script:NumericKeys = @(
    'blocks', 'totalInvocations',
    'taskingAttempts',
    'milestoneCount', 'currentMilestone', 'completedMilestones',
    'implementAttempts', 'reviewAttempts', 'fixInvocations',
    'userReviewReached',
    'securityAttempts', 'privacyAttempts'
)
# Verdict keys and the vocabulary each one accepts. 'pending' and 'running' are shared.
$script:WorkerVerdictKeys = @('taskingVerdict', 'implementVerdict')
$script:ReviewVerdictKeys = @('reviewVerdict', 'securityVerdict', 'privacyVerdict')

function New-DefaultState {
    param([string]$SessionId)
    $state = @{
        sessionId        = $SessionId
        createdAt        = (Get-Date).ToUniversalTime().ToString('o')
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        cappedMilestones = ''
    }
    foreach ($key in $script:NumericKeys) { $state[$key] = 0 }
    foreach ($key in $script:WorkerVerdictKeys) { $state[$key] = 'pending' }
    foreach ($key in $script:ReviewVerdictKeys) { $state[$key] = 'pending' }
    return $state
}

function Read-State {
    param([string]$Path, [string]$RecoveryPath, [string]$SessionId)
    # The out-of-workspace file is authoritative. The workspace copy is also a recovery
    # checkpoint: if the authoritative directory is deleted mid-run, the next sub-agent must
    # restore the same session rather than look like a new session and erase the audit trail.
    # An exact session-id match prevents a previous run in this workspace from being adopted.
    $candidates = @($Path)
    if (-not [string]::IsNullOrWhiteSpace($RecoveryPath) -and $RecoveryPath -ne $Path) {
        $candidates += $RecoveryPath
    }
    foreach ($candidate in $candidates) {
        # Start clean for every candidate. A corrupt authoritative file must not partially
        # mutate defaults that are then reused while processing the recovery checkpoint.
        $state = New-DefaultState -SessionId $SessionId
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $raw = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            $ownerProp = $parsed.PSObject.Properties['sessionId']
            if ($null -eq $ownerProp -or [string]$ownerProp.Value -ne $SessionId) { continue }

            foreach ($key in $script:NumericKeys) {
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -eq $prop -or $null -eq $prop.Value) { continue }
                $normalized = 0
                $rendered = [Convert]::ToString(
                    $prop.Value,
                    [Globalization.CultureInfo]::InvariantCulture)
                if ($rendered -notmatch '^[0-9]+$' -or
                    -not [int]::TryParse($rendered, [ref]$normalized) -or
                    $normalized -lt 0) {
                    throw "Invalid state counter '$key'."
                }
                $state[$key] = $normalized
            }

            foreach ($key in $script:WorkerVerdictKeys) {
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -eq $prop -or $null -eq $prop.Value) { continue }
                $verdict = [string]$prop.Value
                if ($verdict -notin @('pending', 'running', 'DONE', 'BLOCKED')) {
                    throw "Invalid state verdict '$key'."
                }
                $state[$key] = $verdict
            }

            foreach ($key in $script:ReviewVerdictKeys) {
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -eq $prop -or $null -eq $prop.Value) { continue }
                $verdict = [string]$prop.Value
                if ($verdict -notin @('pending', 'running', 'PASS', 'ISSUES')) {
                    throw "Invalid state verdict '$key'."
                }
                $state[$key] = $verdict
            }

            foreach ($key in @('createdAt', 'updatedAt', 'cappedMilestones')) {
                $prop = $parsed.PSObject.Properties[$key]
                if ($null -ne $prop -and $null -ne $prop.Value) {
                    $state[$key] = [string]$prop.Value
                }
            }
            return $state
        }
        catch {
            # Syntax, merge and normalization failures corrupt only this candidate. Try the
            # exact-session recovery checkpoint before treating state as absent.
            continue
        }
    }

    return (New-DefaultState -SessionId $SessionId)
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
    catch {
        # Do not let a persistence failure swallow an enforcement decision. The mirror write
        # below may still preserve the updated state, and the hook can still return its block or
        # deny response.
    }
    finally {
        # If the rename failed (for example a transient lock) the temp file would otherwise be
        # orphaned in the stages directory, so clean it up unconditionally.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    # Human-facing copy and recovery checkpoint. Normal enforcement always reads the
    # authoritative path first; this is consulted only when that file is missing or corrupt.
    # It must be atomic too -- a torn checkpoint is indistinguishable from no recovery state.
    if (-not [string]::IsNullOrWhiteSpace($MirrorPath)) {
        $mirrorTmp = "$MirrorPath.$PID.tmp"
        try {
            Set-Content -LiteralPath $mirrorTmp -Value $json -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $mirrorTmp -Destination $MirrorPath -Force -ErrorAction Stop
        }
        catch { }
        finally {
            if (Test-Path -LiteralPath $mirrorTmp) {
                Remove-Item -LiteralPath $mirrorTmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Add-AuditRow {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Stage,
        [string]$Milestone,
        [int]$Attempt,
        [string]$Action,
        [string]$Verdict
    )
    try {
        $sessionMarker = "Session: ``$SessionId``"
        if (-not (Test-Path -LiteralPath $Path)) {
            $header = @(
                '# autodev-implement stage audit',
                '',
                $sessionMarker,
                "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
                '',
                'Every row below was written by a hook observing a real sub-agent lifecycle event.',
                'The orchestrator does not write this file and is instructed not to edit it, but it',
                'lives in your workspace, so treat it as a record rather than as proof.',
                '',
                '| Time (UTC) | Stage | Milestone | Attempt | Event | Verdict |',
                '| --- | --- | --- | --- | --- | --- |'
            )
            Set-Content -LiteralPath $Path -Value ($header -join [Environment]::NewLine) -Encoding UTF8
        }
        else {
            # Windows PowerShell returns $null for a zero-byte file. Coerce it to an empty
            # string so a manually cleared or interrupted file self-heals with a new section.
            $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if ($null -eq $existing) { $existing = '' }
            if (-not $existing.Contains($sessionMarker)) {
                $sessionHeader = @(
                    '',
                    '---',
                    '',
                    $sessionMarker,
                    "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
                    '',
                    '| Time (UTC) | Stage | Milestone | Attempt | Event | Verdict |',
                    '| --- | --- | --- | --- | --- | --- |'
                )
                Add-Content -LiteralPath $Path -Value ($sessionHeader -join [Environment]::NewLine) -Encoding UTF8
            }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $Path -Value "| $ts | $Stage | $Milestone | $Attempt | $Action | $Verdict |" -Encoding UTF8
    }
    catch {
        # Auditability must never control enforcement. A missing/read-only workspace still gets
        # the block or deny response derived from authoritative state.
    }
}

function Add-FeedbackEntry {
    param(
        [string]$Path,
        [string]$SessionId,
        [string]$Stage,
        [string]$Milestone,
        [int]$Attempt,
        [string]$Verdict,
        [string]$Response
    )
    try {
        $sessionMarker = "Session: ``$SessionId``"
        if (-not (Test-Path -LiteralPath $Path)) {
            $header = @(
                '# autodev-implement sub-agent feedback log',
                '',
                $sessionMarker,
                "Started: $((Get-Date).ToUniversalTime().ToString('u'))",
                '',
                'Each entry is a sub-agent''s verbatim response, captured by a hook as the sub-agent',
                'finished. The orchestrator does not write this file and is instructed not to edit it,',
                'so it records what the sub-agents actually said rather than what the orchestrator',
                'chose to relay. It lives in your workspace and is not read back by the stage',
                'tracker, so editing it changes nothing except this record.'
            )
            Set-Content -LiteralPath $Path -Value ($header -join [Environment]::NewLine) -Encoding UTF8
        }
        else {
            $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if ($null -eq $existing) { $existing = '' }
            if (-not $existing.Contains($sessionMarker)) {
                $sessionHeader = @(
                    '',
                    '---',
                    '',
                    $sessionMarker,
                    "Started: $((Get-Date).ToUniversalTime().ToString('u'))"
                )
                Add-Content -LiteralPath $Path -Value ($sessionHeader -join [Environment]::NewLine) -Encoding UTF8
            }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('u')
        if ([string]::IsNullOrWhiteSpace($Response)) { $Response = '_(the sub-agent returned no content)_' }
        $label = $Stage
        if (-not [string]::IsNullOrWhiteSpace($Milestone) -and $Milestone -ne '-') {
            $label = "$Stage (milestone $Milestone)"
        }
        $entry = @(
            '',
            '---',
            '',
            # Level 1: sub-agents use '##' and '###' for their own sections, so an entry header
            # at the same level would be indistinguishable from the content it introduces.
            "# $label - attempt $Attempt - $Verdict",
            '',
            # Braces are required: "$ts_" would be parsed as a variable named 'ts_'.
            "_${ts}_",
            '',
            $Response.TrimEnd()
        )
        Add-Content -LiteralPath $Path -Value ($entry -join [Environment]::NewLine) -Encoding UTF8
    }
    catch {
        # The sub-agent response and verdict must still reach the orchestrator even when the
        # workspace log cannot be written.
    }
}

function Resolve-Agent {
    param([string]$AgentName)
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return $null }
    # agentName arrives namespaced, e.g. "autodev-implement:autodev-code-review". The match is
    # anchored at both ends and pinned to this plugin's namespace, because a suffix match would
    # also capture another installed plugin's "other:autodev-code-review" and let it mutate this
    # run's counters. An unnamespaced name is still accepted so the tracker keeps working if the
    # agents are ever loaded without a namespace; only a *different* namespace is rejected.
    #
    # The trailing anchor is also what keeps 'code-review' from swallowing
    # 'code-security-review', and what keeps this plugin from capturing autodev-plan's
    # 'autodev-security-review'.
    if ($AgentName -match '^\s*(?:autodev-implement:)?autodev-(tasking|implementation|code-review|code-fix|code-security-review|code-privacy-review)\s*$') {
        return $Matches[1]
    }
    return $null
}

function Get-AgentKind {
    # 'review' agents return PASS/ISSUES; 'worker' agents return DONE/BLOCKED.
    param([string]$Agent)
    if ($Agent -in @('code-review', 'code-security-review', 'code-privacy-review')) { return 'review' }
    return 'worker'
}

function Get-AttemptsKey {
    # The state counter each agent charges its attempts against.
    param([string]$Agent)
    switch ($Agent) {
        'tasking' { return 'taskingAttempts' }
        'implementation' { return 'implementAttempts' }
        'code-review' { return 'reviewAttempts' }
        'code-fix' { return 'fixInvocations' }
        'code-security-review' { return 'securityAttempts' }
        'code-privacy-review' { return 'privacyAttempts' }
    }
    return ''
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

function Get-MilestoneCount {
    # Milestone structure can only come from the todo list; there is nowhere else it exists.
    # Progress does not: it is tracked in this script's own counters, so editing the file
    # cannot skip a review. A count of 0 means "unknown" and degrades enforcement gracefully.
    #
    # The headings must number exactly 1..N with no gaps and no duplicates. That is the format
    # the tasking agent is required to produce, and anything else cannot be walked safely: a
    # list holding milestones 1 and 3 would otherwise be counted as two, and the run would go
    # looking for a milestone 2 that does not exist while never implementing milestone 3.
    param([string]$TodoPath)
    if ([string]::IsNullOrWhiteSpace($TodoPath) -or -not (Test-Path -LiteralPath $TodoPath)) { return 0 }
    try {
        $lines = Get-Content -LiteralPath $TodoPath -ErrorAction Stop
        if ($null -eq $lines) { return 0 }
        $seen = @()
        foreach ($line in $lines) {
            if ($line -match '^##\s+Milestone\s+([0-9]+)') { $seen += [int]$Matches[1] }
        }
        if ($seen.Count -eq 0) { return 0 }
        $expected = 1
        foreach ($number in ($seen | Sort-Object)) {
            if ($number -ne $expected) { return 0 }
            $expected++
        }
        return $seen.Count
    }
    catch {
        return 0
    }
}

function Get-MilestoneStatus {
    # Reads the '**Status:**' line belonging to one milestone, used only to warn when an
    # implementation sub-agent finished without marking its milestone complete.
    param([string]$TodoPath, [int]$Milestone)
    if ([string]::IsNullOrWhiteSpace($TodoPath) -or -not (Test-Path -LiteralPath $TodoPath)) { return '' }
    if ($Milestone -lt 1) { return '' }
    try {
        $lines = Get-Content -LiteralPath $TodoPath -ErrorAction Stop
        if ($null -eq $lines) { return '' }
        $inTarget = $false
        foreach ($line in $lines) {
            if ($line -match '^##\s+Milestone\s+([0-9]+)') {
                $inTarget = ([int]$Matches[1] -eq $Milestone)
                continue
            }
            if ($inTarget -and $line -match '^\s*\*\*Status:\*\*\s*(.+?)\s*$') {
                return $Matches[1].ToLowerInvariant()
            }
        }
        return ''
    }
    catch {
        return ''
    }
}

function Get-EffectiveMilestoneCount {
    # When the todo list is missing or unparseable the count is unknown, and the tracker must
    # not deadlock waiting for a milestone it cannot see. Degrade to "at least one, and at least
    # as many as have already closed", which keeps ordering enforcement without inventing work.
    param([hashtable]$State)
    $count = [int]$State['milestoneCount']
    if ($count -gt 0) { return $count }
    $completed = [int]$State['completedMilestones']
    if ($completed -gt 0) { return $completed }
    return 1
}

function Get-MaxTotalInvocations {
    param([hashtable]$State)
    return ($script:TotalInvocationsBase +
        ($script:TotalInvocationsPerMilestone * (Get-EffectiveMilestoneCount -State $State)))
}

function Reset-DownstreamVerdicts {
    # The security and privacy reviews judge the implementation as a whole, so any verdict they
    # hold describes the code as it stood when they ran. Tasking or implementation work makes
    # that verdict stale, and a stale PASS is worse than no verdict at all: it would let the run
    # skip straight past the USER-REVIEW checkpoint and the final reviews.
    param([hashtable]$State)
    $State['securityVerdict'] = 'pending'
    $State['securityAttempts'] = 0
    $State['privacyVerdict'] = 'pending'
    $State['privacyAttempts'] = 0
}

function Reset-FinalVerdictsAfterFix {
    # A fix applied once the milestones are closed changes code that the whole-implementation
    # reviews have already judged, so any PASS they hold is stale and the sequence has to
    # restart at the security review. Only a PASS is cleared: a loop that is still in progress
    # keeps its attempt budget, or a fix mid-loop would hand it an unlimited number of rounds.
    param([hashtable]$State)
    if ([string]$State['securityVerdict'] -eq 'PASS') {
        $State['securityVerdict'] = 'pending'
        $State['securityAttempts'] = 0
    }
    if ([string]$State['privacyVerdict'] -eq 'PASS') {
        $State['privacyVerdict'] = 'pending'
        $State['privacyAttempts'] = 0
    }
}

function Invoke-MilestoneAdvance {
    # Closes the current milestone when its review loop has ended, either because the reviewer
    # passed it or because the loop spent its budget. Code review is the one loop that proceeds
    # on exhaustion instead of escalating - the outstanding findings are recorded and the run
    # moves on - so both outcomes advance.
    #
    # Idempotent: after advancing, implementVerdict is no longer DONE, so a second call is a
    # no-op. That is what makes it safe to call on every hook event.
    param([hashtable]$State)
    if ([string]$State['taskingVerdict'] -ne 'DONE') { return '' }
    if ([string]$State['implementVerdict'] -ne 'DONE') { return '' }

    $reviewVerdict = [string]$State['reviewVerdict']
    $reviewAttempts = [int]$State['reviewAttempts']
    $reason = ''
    if ($reviewVerdict -eq 'PASS') {
        $reason = 'passed'
    }
    elseif ($reviewVerdict -eq 'ISSUES' -and $reviewAttempts -ge $script:MaxReviewAttempts) {
        $reason = 'capped'
    }
    else {
        return ''
    }

    $closed = [int]$State['currentMilestone']
    if ($closed -lt 1) { $closed = 1 }
    if ($reason -eq 'capped') {
        $capped = [string]$State['cappedMilestones']
        if ([string]::IsNullOrWhiteSpace($capped)) { $State['cappedMilestones'] = "$closed" }
        else { $State['cappedMilestones'] = "$capped,$closed" }
    }
    $State['completedMilestones'] = [int]$State['completedMilestones'] + 1
    $State['currentMilestone'] = $closed + 1
    $State['implementAttempts'] = 0
    $State['implementVerdict'] = 'pending'
    $State['reviewAttempts'] = 0
    $State['reviewVerdict'] = 'pending'
    return $reason
}

function Get-Stage {
    # The single source of truth for "where is this run". Derived from the counters rather than
    # stored, so a partially written state file can never leave the machine in a stage its
    # counters do not support.
    param([hashtable]$State)

    if ([int]$State['taskingAttempts'] -eq 0) { return 'idle' }
    if ([int]$State['totalInvocations'] -ge (Get-MaxTotalInvocations -State $State)) { return 'escalated' }

    if ([string]$State['taskingVerdict'] -ne 'DONE') {
        if ([int]$State['taskingAttempts'] -ge $script:MaxWorkerAttempts) { return 'escalated' }
        return 'tasking'
    }

    $total = Get-EffectiveMilestoneCount -State $State
    if ([int]$State['completedMilestones'] -lt $total) {
        if ([string]$State['implementVerdict'] -ne 'DONE' -and
            [int]$State['implementAttempts'] -ge $script:MaxWorkerAttempts) {
            return 'escalated'
        }
        return 'milestones'
    }

    if ([string]$State['securityVerdict'] -ne 'PASS') {
        # Every milestone is closed and no final review has started: this is the interactive
        # checkpoint. The stage covers the whole window in which the user holds the code, so
        # the orchestrator may keep stopping while it waits for them. What actually gates the
        # security review is userReviewReached, checked in preToolUse.
        if ([int]$State['securityAttempts'] -eq 0) { return 'user-review' }
        if ([int]$State['securityAttempts'] -ge $script:MaxReviewAttempts) { return 'escalated' }
        return 'security'
    }

    if ([string]$State['privacyVerdict'] -ne 'PASS') {
        if ([int]$State['privacyAttempts'] -ge $script:MaxReviewAttempts) { return 'escalated' }
        return 'privacy'
    }

    return 'complete'
}

function Get-EscalationReason {
    param([hashtable]$State)
    $ceiling = Get-MaxTotalInvocations -State $State
    if ([int]$State['totalInvocations'] -ge $ceiling) {
        return "this session has used all $ceiling permitted sub-agent invocations"
    }
    if ([string]$State['taskingVerdict'] -ne 'DONE' -and
        [int]$State['taskingAttempts'] -ge $script:MaxWorkerAttempts) {
        return "the tasking stage used all $script:MaxWorkerAttempts permitted attempts without producing a usable todo list"
    }
    if ([string]$State['implementVerdict'] -ne 'DONE' -and
        [int]$State['implementAttempts'] -ge $script:MaxWorkerAttempts) {
        return "milestone $([int]$State['currentMilestone']) used all $script:MaxWorkerAttempts permitted implementation attempts without completing"
    }
    if ([string]$State['securityVerdict'] -ne 'PASS' -and
        [int]$State['securityAttempts'] -ge $script:MaxReviewAttempts) {
        return "the security review used all $script:MaxReviewAttempts permitted rounds without passing"
    }
    if ([string]$State['privacyVerdict'] -ne 'PASS' -and
        [int]$State['privacyAttempts'] -ge $script:MaxReviewAttempts) {
        return "the privacy review used all $script:MaxReviewAttempts permitted rounds without passing"
    }
    return 'a stage exhausted its attempt budget'
}

function Get-StatusLine {
    param([hashtable]$State)
    $total = [int]$State['milestoneCount']
    if ($total -gt 0) { $totalText = "$total" } else { $totalText = 'unknown' }
    $parts = @()
    $parts += "tasking=$([string]$State['taskingVerdict'])($([int]$State['taskingAttempts'])/$script:MaxWorkerAttempts)"
    $parts += "milestones=$([int]$State['completedMilestones'])/$totalText done"
    $parts += "current=milestone $([int]$State['currentMilestone']) implement=$([string]$State['implementVerdict'])($([int]$State['implementAttempts'])/$script:MaxWorkerAttempts) review=$([string]$State['reviewVerdict'])($([int]$State['reviewAttempts'])/$script:MaxReviewAttempts)"
    $parts += "security=$([string]$State['securityVerdict'])($([int]$State['securityAttempts'])/$script:MaxReviewAttempts)"
    $parts += "privacy=$([string]$State['privacyVerdict'])($([int]$State['privacyAttempts'])/$script:MaxReviewAttempts)"
    return ($parts -join ', ')
}

function Get-NextAction {
    # One sentence naming the exact next sub-agent to invoke. Used by both the subagentStop
    # footer and the agentStop block reason, so the orchestrator is told the same thing whether
    # it asked or tried to stop.
    param([hashtable]$State, [string]$Stage)
    switch ($Stage) {
        'idle' { return 'Invoke autodev-implement:autodev-tasking to break the plan into milestones.' }
        'tasking' {
            if ([string]$State['taskingVerdict'] -eq 'BLOCKED') {
                return 'Re-invoke autodev-implement:autodev-tasking with the context it said it was missing.'
            }
            return 'Invoke autodev-implement:autodev-tasking to break the plan into milestones.'
        }
        'milestones' {
            $m = [int]$State['currentMilestone']
            if ($m -lt 1) { $m = 1 }
            if ([string]$State['implementVerdict'] -ne 'DONE') {
                if ([string]$State['implementVerdict'] -eq 'BLOCKED') {
                    return "Re-invoke autodev-implement:autodev-implementation for milestone $m with the context it said it was missing."
                }
                return "Invoke autodev-implement:autodev-implementation for milestone $m."
            }
            if ([string]$State['reviewVerdict'] -eq 'ISSUES') {
                $remaining = $script:MaxReviewAttempts - [int]$State['reviewAttempts']
                return "Invoke autodev-implement:autodev-code-fix with the findings above verbatim, then re-invoke autodev-implement:autodev-code-review for milestone $m. $remaining round(s) remain before the findings are recorded as unresolved and the run moves on."
            }
            return "Invoke autodev-implement:autodev-code-review for milestone $m."
        }
        'user-review' {
            if ([int]$State['userReviewReached'] -eq 0) {
                return 'Every milestone is closed. Report to the user, state what you built, and hand the code back for review - end your turn or ask them directly. The security review stays locked until you do.'
            }
            return 'The user has the code. When they tell you to proceed, invoke autodev-implement:autodev-code-security-review. If they report issues, invoke autodev-implement:autodev-code-fix and hand the result back to them again.'
        }
        'security' {
            if ([string]$State['securityVerdict'] -eq 'ISSUES') {
                $remaining = $script:MaxReviewAttempts - [int]$State['securityAttempts']
                return "Invoke autodev-implement:autodev-code-fix with the findings above verbatim, then re-invoke autodev-implement:autodev-code-security-review. $remaining round(s) remain before escalation."
            }
            return 'Invoke autodev-implement:autodev-code-security-review.'
        }
        'privacy' {
            if ([string]$State['privacyVerdict'] -eq 'ISSUES') {
                $remaining = $script:MaxReviewAttempts - [int]$State['privacyAttempts']
                return "Invoke autodev-implement:autodev-code-fix with the findings above verbatim, then re-invoke autodev-implement:autodev-code-privacy-review. $remaining round(s) remain before escalation."
            }
            return 'Invoke autodev-implement:autodev-code-privacy-review.'
        }
        'complete' {
            return 'The implementation is complete and every review has passed. Proceed to WRAPUP.'
        }
        'escalated' {
            $reason = Get-EscalationReason -State $State
            return "Stop looping and escalate to the user now, per your escalation protocol: $reason. ask_user is permitted again, and further sub-agent invocations are refused. This session can no longer reach a clean state; say so plainly at wrap-up."
        }
    }
    return 'Continue the workflow.'
}

function Read-Verdict {
    param([string]$Response, [string]$Kind)
    # 'review' agents return PASS/ISSUES; 'worker' agents return DONE/BLOCKED. A missing or
    # unreadable verdict is never a pass.
    if ($Kind -eq 'review') { $fallback = 'ISSUES' } else { $fallback = 'BLOCKED' }
    if ([string]::IsNullOrWhiteSpace($Response)) { return $fallback }
    # The contract requires the verdict on the FINAL line. Scanning the whole body would let a
    # sub-agent that merely mentions a verdict mid-sentence ("I would say AUTODEV-VERDICT: PASS
    # if X were fixed") be recorded as a pass. Walk backwards to the last meaningful line and
    # judge only that; anything unexpected falls through to the fallback.
    $lines = $Response -split "`r?`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        # Tolerate a trailing code fence wrapped around the verdict.
        if ($line -match '^`{3,}[A-Za-z0-9]*$') { continue }
        # Tolerate markdown emphasis, blockquote markers and trailing punctuation.
        if ($line -match '^[\s*`>_-]*AUTODEV-VERDICT:\s*(PASS|ISSUES|DONE|BLOCKED)[\s*`.]*$') {
            $raw = $Matches[1].ToUpperInvariant()
            # A sub-agent that reaches for the other vocabulary means something unambiguous, so
            # translate rather than burn an attempt on a wording mistake.
            if ($Kind -eq 'review') {
                if ($raw -eq 'DONE') { return 'PASS' }
                if ($raw -eq 'BLOCKED') { return 'ISSUES' }
                return $raw
            }
            if ($raw -eq 'PASS') { return 'DONE' }
            if ($raw -eq 'ISSUES') { return 'BLOCKED' }
            return $raw
        }
        return $fallback
    }
    return $fallback
}

function Read-StandardInput {
    # [Console]::In decodes using the console's active code page, which mangles any non-ASCII
    # character in a sub-agent's response (an en dash arrives as three Latin-1 characters). The
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

# Hard ceiling on how long the telemetry child process may run before the parent kills it. Sits
# well below the hook's own 20 second timeout so a hung collector can never cost the gate its
# tracker footer, but high enough to absorb PowerShell process startup on a loaded machine --
# at 6s, spans were silently dropped whenever several agents ran concurrently.
$script:OtelParentTimeoutMs = 12000

function Test-TelemetryEnabled {
    # Cheap early-out for the overwhelming majority of users, who never set COPILOT_OTEL_ENABLED.
    # This is the entire cost of the telemetry feature for them: no state is kept for it, so
    # nothing else in the hook does telemetry work either.
    $value = [Environment]::GetEnvironmentVariable('COPILOT_OTEL_ENABLED')
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    return ($value.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on'))
}

function Get-PowerShellPath {
    foreach ($candidate in @('powershell.exe', 'pwsh.exe')) {
        $path = Join-Path $PSHOME $candidate
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return 'powershell.exe'
}

function Send-OtelSpan {
    <#
        Runs the OTLP emitter as an ISOLATED CHILD PROCESS with both output streams redirected
        and discarded. This is a safety requirement, not a style preference: this script's stdout
        is parsed as a single JSON document and it runs under $ErrorActionPreference = 'Stop', so
        an in-process Invoke-RestMethod could put a response body on the success stream or turn a
        transport warning into a terminating error. Neither can happen across a process boundary.

        The parent also enforces a hard wall-clock bound by killing the child, because
        Invoke-RestMethod's -TimeoutSec does not bound DNS resolution on Windows PowerShell 5.1
        and this hook shares a 20 second budget.

        Telemetry failure is never worth a failed hook, so every path returns quietly.
    #>
    param([hashtable]$Request)
    try {
        if (-not (Test-TelemetryEnabled)) { return }
        $emitter = Join-Path $PSScriptRoot 'autodev-otel.ps1'
        if (-not (Test-Path -LiteralPath $emitter)) { return }

        $payloadPath = Join-Path ([IO.Path]::GetTempPath()) ("autodev-otel-$PID-$([guid]::NewGuid().ToString('N')).json")
        Set-Content -LiteralPath $payloadPath -Encoding UTF8 `
            -Value ($Request | ConvertTo-Json -Depth 5 -Compress)
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Get-PowerShellPath
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $emitter +
            '" -PayloadPath "' + $payloadPath + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $proc) { return }
            try {
                $proc.StandardInput.Close()
                # Drain both pipes so a child that unexpectedly wrote a lot could not block on a
                # full buffer and burn the whole timeout.
                $null = $proc.StandardOutput.ReadToEndAsync()
                $null = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($script:OtelParentTimeoutMs)) {
                    try { $proc.Kill() } catch { }
                }
            }
            finally {
                $proc.Dispose()
            }
        }
        finally {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # No telemetry, unchanged hook.
    }
}

# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------

try {
    # Validated here rather than by a parameter attribute: binding failures happen before this
    # try block, and an unhandled one would exit non-zero with no JSON, which denies the tool
    # call on the fail-closed preToolUse hook.
    if ($EventName -notin @('subagentStart', 'subagentStop', 'agentStop', 'preToolUse')) {
        Write-JsonResult @{}
        exit 0
    }

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
    # Whether the todo list is somewhere the tracker can actually read it. Without a workspace
    # it cannot judge the tasking agent's output, and must not fail it for that.
    $hasWorkspace = -not [string]::IsNullOrWhiteSpace($viewDir)
    if (-not $hasWorkspace) { $viewDir = $stateDir }
    $mirrorPath = Join-Path $viewDir 'implement-status.json'
    $auditPath = Join-Path $viewDir 'implement-gate-audit.md'
    $feedbackPath = Join-Path $viewDir 'implement-feedback-log.md'
    $todoPath = Join-Path $viewDir 'todos.md'

    switch ($EventName) {

        'subagentStart' {
            $agent = Resolve-Agent -AgentName ([string]$payload.agentName)
            if ($null -eq $agent) { Write-JsonResult @{}; exit 0 }
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            Invoke-MilestoneAdvance -State $state | Out-Null

            # Learn the milestone structure from the todo list. Only the tasking agent may
            # change a count that is already known: once implementation has begun, letting a
            # later edit shrink the count would retire milestones that were never built, and
            # the todo list lives in a directory the orchestrator is allowed to write to.
            $parsedCount = Get-MilestoneCount -TodoPath $todoPath
            if ($parsedCount -gt 0 -and
                ($agent -eq 'tasking' -or [int]$state['milestoneCount'] -eq 0)) {
                $state['milestoneCount'] = $parsedCount
            }

            $milestoneLabel = '-'
            switch ($agent) {
                'tasking' {
                    if ([string]$state['taskingVerdict'] -eq 'DONE') {
                        # Re-tasking after the todo list was already accepted starts a fresh
                        # budget rather than charging it the previous pass's attempts.
                        $state['taskingAttempts'] = 1
                    }
                    else {
                        $state['taskingAttempts'] = [int]$state['taskingAttempts'] + 1
                    }
                    $state['taskingVerdict'] = 'running'
                    # Any milestone progress on the books describes code written before this
                    # todo list existed -- for example an implementation sub-agent invoked
                    # before the run was opened. Carrying it forward would let the first
                    # milestone go straight to code review without ever being implemented
                    # against the todo list.
                    $state['implementAttempts'] = 0
                    $state['implementVerdict'] = 'pending'
                    $state['reviewAttempts'] = 0
                    $state['reviewVerdict'] = 'pending'
                    # Nothing has been implemented yet against this todo list, so any security
                    # or privacy verdict on the books belongs to a different body of code.
                    Reset-DownstreamVerdicts -State $state
                }
                'implementation' {
                    if ([int]$state['currentMilestone'] -lt 1) { $state['currentMilestone'] = 1 }
                    $state['implementAttempts'] = [int]$state['implementAttempts'] + 1
                    $state['implementVerdict'] = 'running'
                    # Any review verdict for this milestone describes the code as it stood
                    # before this run. Keeping a PASS here would let freshly written code close
                    # the milestone without ever being reviewed.
                    $state['reviewAttempts'] = 0
                    $state['reviewVerdict'] = 'pending'
                    Reset-DownstreamVerdicts -State $state
                    $milestoneLabel = [string][int]$state['currentMilestone']
                }
                'code-review' {
                    if ([int]$state['currentMilestone'] -lt 1) { $state['currentMilestone'] = 1 }
                    $state['reviewAttempts'] = [int]$state['reviewAttempts'] + 1
                    $state['reviewVerdict'] = 'running'
                    $milestoneLabel = [string][int]$state['currentMilestone']
                }
                'code-fix' {
                    $state['fixInvocations'] = [int]$state['fixInvocations'] + 1
                    if ([int]$state['currentMilestone'] -ge 1 -and
                        [int]$state['completedMilestones'] -lt (Get-EffectiveMilestoneCount -State $state)) {
                        $milestoneLabel = [string][int]$state['currentMilestone']
                    }
                    else {
                        # Past the milestone phase, so this fix changes code the security and
                        # privacy reviews have already judged.
                        if ((Get-Stage -State $state) -eq 'user-review') {
                            # The user asked for this change, so they get to look again before
                            # the final reviews run.
                            $state['userReviewReached'] = 0
                        }
                        Reset-FinalVerdictsAfterFix -State $state
                    }
                }
                'code-security-review' {
                    if ([string]$state['securityVerdict'] -eq 'PASS') { $state['securityAttempts'] = 1 }
                    else { $state['securityAttempts'] = [int]$state['securityAttempts'] + 1 }
                    $state['securityVerdict'] = 'running'
                    # A security re-review describes a newer state of the code, so any privacy
                    # verdict recorded against the older code is stale.
                    $state['privacyVerdict'] = 'pending'
                    $state['privacyAttempts'] = 0
                }
                'code-privacy-review' {
                    if ([string]$state['privacyVerdict'] -eq 'PASS') { $state['privacyAttempts'] = 1 }
                    else { $state['privacyAttempts'] = [int]$state['privacyAttempts'] + 1 }
                    $state['privacyVerdict'] = 'running'
                }
            }

            $state['totalInvocations'] = [int]$state['totalInvocations'] + 1
            # Real progress was made, so forgive any earlier blocked stops.
            $state['blocks'] = 0
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            $attempt = 0
            $attemptsKey = Get-AttemptsKey -Agent $agent
            if ($attemptsKey -ne '') { $attempt = [int]$state[$attemptsKey] }
            Add-AuditRow -Path $auditPath -SessionId $sessionId -Stage $agent `
                -Milestone $milestoneLabel -Attempt $attempt -Action 'invoked' -Verdict '-'

            Write-JsonResult @{}
            exit 0
        }

        'subagentStop' {
            # subagentStop does not support a matcher, so filter here.
            $agent = Resolve-Agent -AgentName ([string]$payload.agentName)
            if ($null -eq $agent) { Write-JsonResult @{}; exit 0 }
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $response = [string]$payload.response
            $kind = Get-AgentKind -Agent $agent
            $verdict = Read-Verdict -Response $response -Kind $kind

            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId

            $milestoneLabel = '-'
            $attempt = 0
            $extraNotes = @()

            # Every branch below charges this stop against the agent's own attempt counter and
            # reports that number, so both are done once here rather than six times. A counter
            # still at zero means subagentStart never ran for this sub-agent: recover the attempt
            # and the session total together, or the ceiling would undercount real work and the
            # span would export a total of zero for an invocation that demonstrably completed.
            # Get-AttemptsKey is the single place that knows which counter belongs to which agent,
            # because the names are not mechanically related (code-fix uses 'fixInvocations').
            $attemptsKey = Get-AttemptsKey -Agent $agent
            if ($attemptsKey -ne '') {
                if ([int]$state[$attemptsKey] -lt 1) {
                    $state[$attemptsKey] = 1
                    $state['totalInvocations'] = [int]$state['totalInvocations'] + 1
                }
                $attempt = [int]$state[$attemptsKey]
            }

            switch ($agent) {
                'tasking' {
                    if ($verdict -eq 'DONE') {
                        $parsedCount = Get-MilestoneCount -TodoPath $todoPath
                        if ($parsedCount -gt 0) {
                            $state['milestoneCount'] = $parsedCount
                            if ([int]$state['currentMilestone'] -lt 1) { $state['currentMilestone'] = 1 }
                            $extraNotes += "Todo list parsed: $parsedCount milestone(s)."
                        }
                        elseif ($hasWorkspace) {
                            # A DONE the tracker cannot act on is not a DONE. Recording it as
                            # such would send the run into the milestone phase against an
                            # artifact nobody can walk, and would contradict the warning below
                            # by naming implementation as the next action. Downgrading keeps the
                            # next action on tasking and charges the attempt against the tasking
                            # retry budget, so a persistently malformed todo list escalates
                            # instead of quietly starting implementation.
                            $verdict = 'BLOCKED'
                            $extraNotes += "WARNING: $todoPath does not contain '## Milestone <n>' headings numbered consecutively from 1, so the tracker cannot walk the milestones. This attempt is recorded as BLOCKED rather than DONE. Re-invoke the tasking agent and require the documented todo list format."
                        }
                        else {
                            # No workspace to look in, so the todo list cannot be judged either
                            # way. Take the agent at its word rather than locking the run out.
                            if ([int]$state['currentMilestone'] -lt 1) { $state['currentMilestone'] = 1 }
                            $extraNotes += "WARNING: there is no workspace directory to read the todo list from, so milestone enforcement is degraded for this run."
                        }
                    }
                    $state['taskingVerdict'] = $verdict
                }
                'implementation' {
                    $state['implementVerdict'] = $verdict
                    $milestoneLabel = [string][int]$state['currentMilestone']
                    if ($verdict -eq 'DONE') {
                        $status = Get-MilestoneStatus -TodoPath $todoPath -Milestone ([int]$state['currentMilestone'])
                        if ($status -ne '' -and $status -ne 'complete') {
                            $extraNotes += "WARNING: milestone $([int]$state['currentMilestone']) still reads '**Status:** $status' in the todo list even though the implementation agent reported DONE. Verify the milestone is genuinely finished before reviewing it."
                        }
                    }
                }
                'code-review' {
                    $state['reviewVerdict'] = $verdict
                    $milestoneLabel = [string][int]$state['currentMilestone']
                }
                'code-fix' {
                    if ([int]$state['completedMilestones'] -lt (Get-EffectiveMilestoneCount -State $state)) {
                        $milestoneLabel = [string][int]$state['currentMilestone']
                    }
                    if ($verdict -eq 'BLOCKED') {
                        $extraNotes += 'The fix agent reported BLOCKED. Resolve what it says it needs and re-invoke it; the outstanding findings still stand.'
                    }
                }
                'code-security-review' {
                    $state['securityVerdict'] = $verdict
                }
                'code-privacy-review' {
                    $state['privacyVerdict'] = $verdict
                }
            }

            $closedMilestone = [int]$state['currentMilestone']
            $advanced = Invoke-MilestoneAdvance -State $state
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            Add-AuditRow -Path $auditPath -SessionId $sessionId -Stage $agent `
                -Milestone $milestoneLabel -Attempt $attempt -Action 'completed' -Verdict $verdict
            if ($advanced -ne '') {
                Add-AuditRow -Path $auditPath -SessionId $sessionId -Stage 'milestone' `
                    -Milestone ([string]$closedMilestone) -Attempt $attempt `
                    -Action "milestone-closed ($advanced)" -Verdict $verdict
                if ($advanced -eq 'capped') {
                    $extraNotes += "Milestone $closedMilestone used all $script:MaxReviewAttempts code review rounds without passing. Record the outstanding findings verbatim in that milestone's 'Review notes' section in the todo list, then continue. Report them to the user at wrap-up."
                }
            }
            # Capture the response itself, not just that it happened, so the findings survive the
            # session and a developer can see what each stage actually said.
            Add-FeedbackEntry -Path $feedbackPath -SessionId $sessionId -Stage $agent `
                -Milestone $milestoneLabel -Attempt $attempt -Verdict $verdict -Response $response

            $stage = Get-Stage -State $state
            $statusLine = Get-StatusLine -State $state

            $footerLines = @(
                '',
                '---',
                '[autodev-implement stage tracker]',
                "Stage: $agent | Attempt $attempt | Recorded verdict: $verdict",
                "Run status: $statusLine"
            )
            foreach ($note in $extraNotes) { $footerLines += $note }
            $footerLines += "Next required action: $(Get-NextAction -State $state -Stage $stage)"
            if ($stage -eq 'complete' -or $stage -eq 'escalated' -or $stage -eq 'user-review') {
                $footerLines += "Audit trail: $auditPath"
                $footerLines += "Feedback log: $feedbackPath"
            }

            $footer = $footerLines -join [Environment]::NewLine
            # Telemetry last, after every piece of enforcement state is durable. The raw session
            # id is used deliberately: the sanitized form exists only to build a safe filename,
            # and exporting it would break the join against Copilot's own spans for any session
            # id containing a character the sanitizer rewrites.
            Send-OtelSpan -Request @{
                spanName         = "autodev.stage $agent"
                sessionId        = [string]$payload.sessionId
                agentName        = [string]$payload.agentName
                agentId          = [string]$payload.agentId
                plugin           = 'autodev-implement'
                unitKey          = 'autodev.stage'
                unitValue        = $agent
                verdict          = $verdict
                attempt          = $attempt
                totalInvocations = [int]$state['totalInvocations']
                # Passed through raw, NOT cast to [long] here. This hashtable is built before
                # Send-OtelSpan is entered, so it is outside its protective try/catch: a
                # non-numeric timestamp would throw under $ErrorActionPreference = 'Stop' and the
                # outer catch would emit '{}' instead of the tracker footer -- even with
                # telemetry disabled. The emitter validates it safely with Get-LongField.
                timeMs           = $payload.timestamp
                # Absent today, but forwarded so the span parents itself under Copilot's own
                # sub-agent span the moment the CLI starts supplying trace context.
                traceparent      = [string]$payload.traceparent
                tracestate       = [string]$payload.tracestate
            }
            Write-JsonResult @{ modifiedResponse = ($response + [Environment]::NewLine + $footer) }
            exit 0
        }

        'agentStop' {
            if (-not (Test-Path -LiteralPath $statePath) -and
                -not (Test-Path -LiteralPath $mirrorPath)) {
                Write-JsonResult @{}
                exit 0
            }
            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            Invoke-MilestoneAdvance -State $state | Out-Null
            $stage = Get-Stage -State $state
            if ($stage -eq 'user-review') {
                # 'user-review' is deliberately not blocked: stopping to let the human review
                # the code is the whole point of that checkpoint. Record that the pause actually
                # happened -- that record is what unlocks the security review, so the run cannot
                # close its last milestone and start the final reviews in the same turn without
                # ever handing the code back to the user.
                Confirm-Directory -Path $stateDir | Out-Null
                Confirm-Directory -Path $viewDir | Out-Null
                if ([int]$state['userReviewReached'] -eq 0) {
                    $state['userReviewReached'] = 1
                    Write-State -State $state -Path $statePath -MirrorPath $mirrorPath
                    Add-AuditRow -Path $auditPath -SessionId $sessionId -Stage 'user-review' `
                        -Milestone '-' -Attempt 0 -Action 'handed to user' -Verdict '-'
                }
                Write-JsonResult @{}
                exit 0
            }
            if ($stage -notin $script:AutonomousStages) { Write-JsonResult @{}; exit 0 }
            # The authoritative directory may be what was deleted. Recreate it before persisting
            # the recovered block counter; Write-State still fails open if this is impossible.
            Confirm-Directory -Path $stateDir | Out-Null
            Confirm-Directory -Path $viewDir | Out-Null

            $blocks = [int]$state['blocks']
            if ($blocks -ge $script:MaxBlocks) {
                # Give up rather than fight the CLI's own runaway guard.
                Write-JsonResult @{}
                exit 0
            }
            $state['blocks'] = $blocks + 1
            Write-State -State $state -Path $statePath -MirrorPath $mirrorPath

            $statusLine = Get-StatusLine -State $state
            $reason = "You stopped while the autodev-implement run is still in progress. " +
            "Run status: $statusLine. " +
            "Do not end your turn and do not ask the user anything. " +
            "Continue the workflow now. Next required action: " +
            (Get-NextAction -State $state -Stage $stage)

            Add-AuditRow -Path $auditPath -SessionId $sessionId -Stage $stage `
                -Milestone ([string][int]$state['currentMilestone']) -Attempt ([int]$state['blocks']) `
                -Action 'premature-stop-blocked' -Verdict '-'

            Write-JsonResult @{ decision = 'block'; reason = $reason }
            exit 0
        }

        'preToolUse' {
            # hooks.json restricts this hook to ask_user and task via a matcher, but do not rely
            # on that alone: without this check a broadened or missing matcher would deny
            # *every* tool while the run is autonomous, including the tools the orchestrator
            # needs to make progress, deadlocking it against the agentStop block.
            $toolName = [string]$payload.toolName
            if ($toolName -notmatch '^(?:ask_user|AskUserQuestion|task)$') { Write-JsonResult @{}; exit 0 }

            if (-not (Test-Path -LiteralPath $statePath) -and
                -not (Test-Path -LiteralPath $mirrorPath)) {
                # No run has started. ask_user is nobody's business here, but the target still
                # has to be resolved before letting a sub-agent through: the only stage that may
                # open a run is tasking. Starting with implementation would record milestone
                # progress for code that predates any milestone, and once tasking finished the
                # tracker would hand that code straight to code review.
                if ($toolName -eq 'task') {
                    $target = Resolve-Agent -AgentName (Get-TaskAgentType -ToolArgs $payload.toolArgs)
                    if ($null -ne $target -and $target -ne 'tasking') {
                        $reason = "Out of order: invoking $target is not the next step because the " +
                        "autodev-implement run has not started and no milestones exist yet. " +
                        "Next required action: Invoke autodev-implement:autodev-tasking to break " +
                        "the plan into milestones."
                        Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
                        exit 0
                    }
                }
                Write-JsonResult @{}
                exit 0
            }
            $state = Read-State -Path $statePath -RecoveryPath $mirrorPath -SessionId $sessionId
            Invoke-MilestoneAdvance -State $state | Out-Null
            $stage = Get-Stage -State $state

            if ($toolName -eq 'task') {
                $target = Resolve-Agent -AgentName (Get-TaskAgentType -ToolArgs $payload.toolArgs)
                # Anything that is not one of this plugin's sub-agents is none of our business.
                if ($null -eq $target) { Write-JsonResult @{}; exit 0 }

                # Everything else in this plugin only *asks* the orchestrator to stop looping
                # once a budget is spent. This is the part that actually stops it: once the
                # budget is gone, refuse to start another sub-agent. Without it an orchestrator
                # that ignores the escalation instruction can keep looping past the cap, which
                # is exactly what the cap exists to prevent.
                if ($stage -eq 'escalated') {
                    $reason = "The autodev-implement run is out of budget: $(Get-EscalationReason -State $state). " +
                    "Further sub-agent invocations are refused, so invoking $target cannot succeed. " +
                    "Stop looping and escalate to the user now, per your escalation protocol: say which " +
                    "stage is stuck, summarise its outstanding findings, point at the todo list and the " +
                    "feedback log, and state plainly that this session did not reach a clean state. " +
                    "ask_user is available again."
                    Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
                    exit 0
                }

                # Ordering. The fix agent is legal in every stage that has code to fix, so only
                # genuine out-of-order jumps are refused. Over-denying here would deadlock the
                # orchestrator against the agentStop block, so every denial below leaves at
                # least one way forward.
                $denyReason = ''
                if ($stage -eq 'idle') {
                    # State exists but tasking has never run, so there are no milestones and
                    # nothing has been built. Only tasking may open the run.
                    if ($target -ne 'tasking') {
                        $denyReason = "the autodev-implement run has not started and no milestones exist yet, so tasking has to define them before any other stage runs"
                    }
                }
                elseif ($target -ne 'code-fix') {
                    switch ($stage) {
                        'tasking' {
                            if ($target -ne 'tasking') {
                                $denyReason = "the tasking stage has not produced a usable todo list yet"
                            }
                        }
                        'milestones' {
                            if ($target -eq 'code-security-review' -or $target -eq 'code-privacy-review') {
                                $total = Get-EffectiveMilestoneCount -State $state
                                $remaining = $total - [int]$state['completedMilestones']
                                $denyReason = "$remaining milestone(s) are still unimplemented, and the security and privacy reviews run only once the whole implementation is finished"
                            }
                            elseif ($target -eq 'tasking' -and
                                ([int]$state['completedMilestones'] -gt 0 -or
                                [int]$state['implementAttempts'] -gt 0 -or
                                [int]$state['reviewAttempts'] -gt 0)) {
                                # Re-tasking rewrites the milestone list, and a shorter list
                                # would retire milestones that were never built. It is only safe
                                # before any milestone work has started.
                                $denyReason = "milestone work has already started, and re-tasking now would rewrite the milestone list underneath it"
                            }
                            elseif ($target -eq 'code-review' -and
                                [string]$state['implementVerdict'] -ne 'DONE') {
                                # Reviewing before the milestone is built would record a verdict
                                # about code that does not exist yet, and that verdict would
                                # then close the milestone the moment implementation finished.
                                $denyReason = "milestone $([int]$state['currentMilestone']) has not been implemented yet, so there is nothing to review"
                            }
                            elseif ($target -eq 'implementation' -and
                                [int]$state['reviewAttempts'] -gt 0 -and
                                [string]$state['reviewVerdict'] -ne 'PASS') {
                                $denyReason = "milestone $([int]$state['currentMilestone']) has outstanding code review findings, and the next milestone cannot start until its review loop has ended"
                            }
                        }
                        'user-review' {
                            if ($target -eq 'code-security-review') {
                                # The checkpoint is satisfied only once the orchestrator has
                                # actually handed the code back -- by ending its turn or by
                                # asking the user. Without this the final milestone could close
                                # and the security review start in the same turn, and the user
                                # would never get to look at anything.
                                if ([int]$state['userReviewReached'] -eq 0) {
                                    $denyReason = "the user has not been given the code to review yet. End your turn, or ask the user to review, and run the security review once they tell you to proceed"
                                }
                            }
                            elseif ($target -eq 'code-privacy-review') {
                                $denyReason = "the security review runs before the privacy review"
                            }
                            else {
                                $denyReason = "every milestone is closed and the run is waiting for the user to review the code"
                            }
                        }
                        'security' {
                            if ($target -ne 'code-security-review') {
                                $denyReason = "the security review is outstanding and runs before anything else"
                            }
                        }
                        'privacy' {
                            if ($target -ne 'code-privacy-review') {
                                $denyReason = "the privacy review is outstanding and runs before anything else"
                            }
                        }
                    }
                }

                if ($denyReason -ne '') {
                    $reason = "Out of order: invoking $target is not the next step because $denyReason. " +
                    "Next required action: $(Get-NextAction -State $state -Stage $stage)"
                    Write-JsonResult @{ permissionDecision = 'deny'; permissionDecisionReason = $reason }
                    exit 0
                }

                Write-JsonResult @{}
                exit 0
            }

            # ask_user. Permitted at the USER-REVIEW checkpoint, once a stage has escalated,
            # before the run starts, and after it completes. Denied in between.
            if ($stage -eq 'user-review') {
                # Asking the user to review the code is the handoff, so it satisfies the
                # checkpoint just as ending the turn does.
                Confirm-Directory -Path $stateDir | Out-Null
                Confirm-Directory -Path $viewDir | Out-Null
                if ([int]$state['userReviewReached'] -eq 0) {
                    $state['userReviewReached'] = 1
                    Write-State -State $state -Path $statePath -MirrorPath $mirrorPath
                    Add-AuditRow -Path $auditPath -SessionId $sessionId -Stage 'user-review' `
                        -Milestone '-' -Attempt 0 -Action 'handed to user' -Verdict '-'
                }
                Write-JsonResult @{}
                exit 0
            }
            if ($stage -notin $script:AutonomousStages) { Write-JsonResult @{}; exit 0 }

            $reason = "The autodev-implement run is in an autonomous phase ($stage), which proceeds " +
            "without human interaction, so ask_user is unavailable. Resolve the question yourself " +
            "using the plan and your best engineering judgement, and record the decision in the todo " +
            "list. The user is consulted at the USER-REVIEW checkpoint once every milestone is " +
            "closed. If you truly cannot proceed, keep working until the current stage reaches its " +
            "attempt limit, at which point escalation to the user is unlocked automatically. " +
            "Next required action: $(Get-NextAction -State $state -Stage $stage)"

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
