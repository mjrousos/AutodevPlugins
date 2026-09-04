<#
.SYNOPSIS
    Hook router for the autodev plugin (Windows / PowerShell).

.DESCRIPTION
    The plugin ships two independent enforcement trackers:

        autodev-gates.ps1   - the planning review-gate state machine (architecture, security,
                              privacy).
        autodev-stages.ps1  - the implementation stage state machine (tasking, milestones,
                              reviews).

    Both are still driven by the same four hook events, but only one of them owns any given
    event. This router is the single command referenced by hooks.json; it decides which tracker
    (if any) the event belongs to and forwards the untouched payload to exactly that tracker,
    passing its JSON result straight back to the CLI. An event that belongs to neither tracker
    returns the standard empty hook result.

    Routing rules:
      subagentStart / subagentStop      by the sub-agent's name: a review-gate agent goes to
                                        gates, an implementation-stage agent goes to stages.
      preToolUse (task)                 by the target agent_type, using the same name-based rule,
                                        so ordering enforcement reaches the tracker that owns the
                                        target.
      preToolUse (ask_user) / agentStop by the router's session-keyed workflow marker, with the
                                        trackers' session-keyed state as a compatibility fallback.

    The router owns cross-workflow discrimination; the two trackers stay focused on their own
    state machines and never learn about each other. It never inspects or rewrites a tracker's
    decision.

    SAFETY: preToolUse command hooks are fail-closed - any crash denies the tool call. This
    router therefore always prints valid JSON and exits 0, degrading to a no-op on any error.
#>
param(
    [string]$EventName = ''
)

$ErrorActionPreference = 'Stop'

function Write-EmptyResult {
    Write-Output '{}'
    exit 0
}

function Read-StandardInput {
    # The payload is always UTF-8; decode it explicitly rather than through the console code page.
    try {
        $stdin = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdin, (New-Object System.Text.UTF8Encoding($false)))
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    catch {
        return [Console]::In.ReadToEnd()
    }
}

function Get-PowerShellPath {
    foreach ($candidate in @('powershell.exe', 'pwsh.exe')) {
        $path = Join-Path $PSHOME $candidate
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return 'powershell.exe'
}

# Bare names are accepted because the CLI is not guaranteed to namespace them, but a different
# namespace must never be captured.
function Get-AgentWorkflow {
    param([string]$AgentName)
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return $null }
    $name = $AgentName.Trim()
    switch -Regex ($name) {
        '^(?:autodev:)?autodev-(architecture|security|privacy)-review$' { return 'gates' }
        '^(?:autodev:)?autodev-(tasking|implementation|code-review|code-fix|code-security-review|code-privacy-review)$' { return 'stages' }
        default { return $null }
    }
}

function Get-TaskAgentType {
    param($ToolArgs)
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

# The router records its own session-keyed workflow marker before dispatching a lifecycle event.
# Tracker state is a compatibility fallback for sessions that began before the marker existed.
# Workspace mirrors remain solely the trackers' recovery mechanism.
function Get-RoutingPaths {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $safe = ($SessionId -replace '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrEmpty($safe)) { $safe = 'unknown-session' }
    $root = Join-Path $copilotHome 'autodev'
    return @{
        GateState  = Join-Path (Join-Path $root 'gates') ($safe + '.json')
        StageState = Join-Path (Join-Path $root 'stages') ($safe + '.json')
        RouteDir   = Join-Path $root 'routes'
        RoutePath  = Join-Path (Join-Path $root 'routes') $safe
    }
}

function Set-SessionWorkflow {
    param([string]$SessionId, [string]$Workflow)
    $paths = Get-RoutingPaths $SessionId
    if ($null -eq $paths) { return }
    $temp = $null
    try {
        New-Item -ItemType Directory -Force -Path $paths.RouteDir | Out-Null
        $temp = $paths.RoutePath + '.tmp.' + $PID
        [IO.File]::WriteAllText($temp, $Workflow + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $paths.RoutePath -Force
    }
    catch {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SessionWorkflow {
    param([string]$SessionId)
    $paths = Get-RoutingPaths $SessionId
    if ($null -eq $paths) { return $null }
    if (Test-Path -LiteralPath $paths.RoutePath -PathType Leaf) {
        $remembered = (Get-Content -LiteralPath $paths.RoutePath -TotalCount 1 -ErrorAction SilentlyContinue).Trim()
        if ($remembered -in @('gates', 'stages')) { return $remembered }
    }
    $gateExists = Test-Path -LiteralPath $paths.GateState -PathType Leaf
    $stageExists = Test-Path -LiteralPath $paths.StageState -PathType Leaf
    if ($gateExists -and $stageExists) {
        $gt = (Get-Item -LiteralPath $paths.GateState).LastWriteTimeUtc
        $st = (Get-Item -LiteralPath $paths.StageState).LastWriteTimeUtc
        if ($gt -ge $st) { return 'gates' } else { return 'stages' }
    }
    elseif ($gateExists) { return 'gates' }
    elseif ($stageExists) { return 'stages' }
    return $null
}

function Get-StateNumber {
    param($State, [string]$Name)
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return 0 }
    $number = 0
    if ([int]::TryParse([string]$property.Value, [ref]$number) -and $number -ge 0) {
        return $number
    }
    return 0
}

function Get-StateString {
    param($State, [string]$Name, [string]$Default)
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return [string]$property.Value
}

function Test-StateCounter {
    param($State, [string]$Name)
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return $true }
    $text = [Convert]::ToString($property.Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($text -notmatch '^[0-9]+$') { return $false }
    $number = 0L
    return [long]::TryParse($text, [ref]$number) -and $number -le 2147483647
}

function Test-StateVerdict {
    param($State, [string]$Name, [string[]]$Allowed)
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return $true }
    return $property.Value -is [string] -and [string]$property.Value -in $Allowed
}

function Test-GateStateSemantics {
    param($State)
    foreach ($name in @(
            'blocks', 'totalInvocations', 'architectureAttempts', 'securityAttempts',
            'privacyAttempts'
        )) {
        if (-not (Test-StateCounter $State $name)) { return $false }
    }
    foreach ($name in @('architectureVerdict', 'securityVerdict', 'privacyVerdict')) {
        if (-not (Test-StateVerdict $State $name @('pending', 'running', 'PASS', 'ISSUES'))) {
            return $false
        }
    }
    return $true
}

function Test-StageStateSemantics {
    param($State)
    foreach ($name in @(
            'blocks', 'totalInvocations', 'taskingAttempts', 'milestoneCount',
            'currentMilestone', 'completedMilestones', 'implementAttempts', 'reviewAttempts',
            'fixInvocations', 'userReviewReached', 'securityAttempts', 'privacyAttempts'
        )) {
        if (-not (Test-StateCounter $State $name)) { return $false }
    }
    foreach ($name in @('taskingVerdict', 'implementVerdict')) {
        if (-not (Test-StateVerdict $State $name @('pending', 'running', 'DONE', 'BLOCKED'))) {
            return $false
        }
    }
    foreach ($name in @('reviewVerdict', 'securityVerdict', 'privacyVerdict')) {
        if (-not (Test-StateVerdict $State $name @('pending', 'running', 'PASS', 'ISSUES'))) {
            return $false
        }
    }
    return $true
}

# Missing or malformed state is treated as active because the owning tracker may still recover it
# from its workspace mirror. This guard only releases a cross-workflow starter after the current
# workflow is complete or escalated.
function Test-WorkflowEnforcing {
    param([string]$SessionId, [string]$Workflow)
    $paths = Get-RoutingPaths $SessionId
    if ($null -eq $paths) { return $false }
    $statePath = if ($Workflow -eq 'gates') { $paths.GateState } else { $paths.StageState }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $true }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]', '_')
        if ([string]::IsNullOrEmpty($safe)) { $safe = 'unknown-session' }
        if ([string]$state.sessionId -ne $safe) { return $true }

        if ($Workflow -eq 'gates') {
            if (-not (Test-GateStateSemantics $state)) { return $true }
            $started = (Get-StateNumber $state 'architectureAttempts') -gt 0 -or
                (Get-StateNumber $state 'securityAttempts') -gt 0 -or
                (Get-StateNumber $state 'privacyAttempts') -gt 0
            $complete = (Get-StateString $state 'architectureVerdict' 'pending') -eq 'PASS' -and
                (Get-StateString $state 'securityVerdict' 'pending') -eq 'PASS' -and
                (Get-StateString $state 'privacyVerdict' 'pending') -eq 'PASS'
            $escalated = (Get-StateNumber $state 'totalInvocations') -ge 40 -or
                ((Get-StateString $state 'architectureVerdict' 'pending') -ne 'PASS' -and
                    (Get-StateNumber $state 'architectureAttempts') -ge 10) -or
                ((Get-StateString $state 'securityVerdict' 'pending') -ne 'PASS' -and
                    (Get-StateNumber $state 'securityAttempts') -ge 10) -or
                ((Get-StateString $state 'privacyVerdict' 'pending') -ne 'PASS' -and
                    (Get-StateNumber $state 'privacyAttempts') -ge 10)
            return $started -and -not $complete -and -not $escalated
        }

        if (-not (Test-StageStateSemantics $state)) { return $true }
        $milestoneCount = Get-StateNumber $state 'milestoneCount'
        $completedMilestones = Get-StateNumber $state 'completedMilestones'
        $milestones = if ($milestoneCount -gt 0) {
            $milestoneCount
        }
        elseif ($completedMilestones -gt 0) {
            $completedMilestones
        }
        else {
            1
        }
        $taskingDone = (Get-StateString $state 'taskingVerdict' 'pending') -eq 'DONE'
        $securityPassed = (Get-StateString $state 'securityVerdict' 'pending') -eq 'PASS'
        $privacyPassed = (Get-StateString $state 'privacyVerdict' 'pending') -eq 'PASS'
        if ((Get-StateNumber $state 'taskingAttempts') -eq 0) {
            $stage = 'idle'
        }
        elseif ((Get-StateNumber $state 'totalInvocations') -ge (120 + 30 * $milestones)) {
            $stage = 'escalated'
        }
        elseif (-not $taskingDone) {
            $stage = if ((Get-StateNumber $state 'taskingAttempts') -ge 5) {
                'escalated'
            }
            else {
                'tasking'
            }
        }
        elseif ($completedMilestones -lt $milestones) {
            $stage = if (
                (Get-StateString $state 'implementVerdict' 'pending') -ne 'DONE' -and
                (Get-StateNumber $state 'implementAttempts') -ge 5
            ) {
                'escalated'
            }
            else {
                'milestones'
            }
        }
        elseif (-not $securityPassed) {
            $securityAttempts = Get-StateNumber $state 'securityAttempts'
            if ($securityAttempts -eq 0) {
                $stage = 'user-review'
            }
            elseif ($securityAttempts -ge 10) {
                $stage = 'escalated'
            }
            else {
                $stage = 'security'
            }
        }
        elseif (-not $privacyPassed) {
            $stage = if ((Get-StateNumber $state 'privacyAttempts') -ge 10) {
                'escalated'
            }
            else {
                'privacy'
            }
        }
        else {
            $stage = 'complete'
        }
        return $stage -notin @('idle', 'complete', 'escalated')
    }
    catch {
        return $true
    }
}

function Write-CrossWorkflowDenial {
    param([string]$Current, [string]$Target)
    @{
        permissionDecision       = 'deny'
        permissionDecisionReason = "The autodev $Current workflow is still active. Finish or escalate it before starting the $Target workflow."
    } | ConvertTo-Json -Compress
    exit 0
}

function Test-StrictJsonObject {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }

    # PowerShell 5.1's ConvertFrom-Json accepts JavaScript extensions such as NaN, Infinity,
    # unquoted keys, and malformed numbers. Parse the JSON grammar directly without converting
    # numbers to floating point, so valid large exponents remain valid.
    $state = @{ Text = $Json; Index = 0; Depth = 0 }
    $skipWhitespace = {
        while ($state.Index -lt $state.Text.Length) {
            $character = $state.Text[$state.Index]
            if ($character -ne ' ' -and $character -ne "`t" -and
                $character -ne "`r" -and $character -ne "`n") {
                break
            }
            $state.Index += 1
        }
    }
    $parseString = {
        if ($state.Index -ge $state.Text.Length -or $state.Text[$state.Index] -ne '"') {
            return $false
        }
        $state.Index += 1
        while ($state.Index -lt $state.Text.Length) {
            $character = $state.Text[$state.Index]
            if ($character -eq '"') {
                $state.Index += 1
                return $true
            }
            if ([int][char]$character -lt 32) { return $false }
            if ($character -eq '\') {
                $state.Index += 1
                if ($state.Index -ge $state.Text.Length) { return $false }
                $escape = $state.Text[$state.Index]
                if ($escape -eq 'u') {
                    for ($digit = 0; $digit -lt 4; $digit++) {
                        $state.Index += 1
                        if ($state.Index -ge $state.Text.Length -or
                            $state.Text[$state.Index] -notmatch '^[0-9A-Fa-f]$') {
                            return $false
                        }
                    }
                }
                elseif ('"\/bfnrt'.IndexOf($escape) -lt 0) {
                    return $false
                }
            }
            $state.Index += 1
        }
        return $false
    }
    $parseNumber = {
        $remaining = $state.Text.Substring($state.Index)
        $match = [regex]::Match(
            $remaining,
            '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
        )
        if (-not $match.Success) { return $false }
        $state.Index += $match.Length
        return $true
    }
    $parseLiteral = {
        param([string]$Literal)
        if ($state.Index + $Literal.Length -gt $state.Text.Length -or
            $state.Text.Substring($state.Index, $Literal.Length) -ne $Literal) {
            return $false
        }
        $state.Index += $Literal.Length
        return $true
    }
    $parseValue = $null
    $parseArray = {
        $state.Index += 1
        & $skipWhitespace
        if ($state.Index -lt $state.Text.Length -and $state.Text[$state.Index] -eq ']') {
            $state.Index += 1
            return $true
        }
        while ($true) {
            if (-not (& $parseValue)) { return $false }
            & $skipWhitespace
            if ($state.Index -ge $state.Text.Length) { return $false }
            if ($state.Text[$state.Index] -eq ']') {
                $state.Index += 1
                return $true
            }
            if ($state.Text[$state.Index] -ne ',') { return $false }
            $state.Index += 1
            & $skipWhitespace
        }
    }
    $parseObject = {
        $state.Index += 1
        & $skipWhitespace
        if ($state.Index -lt $state.Text.Length -and $state.Text[$state.Index] -eq '}') {
            $state.Index += 1
            return $true
        }
        while ($true) {
            if (-not (& $parseString)) { return $false }
            & $skipWhitespace
            if ($state.Index -ge $state.Text.Length -or $state.Text[$state.Index] -ne ':') {
                return $false
            }
            $state.Index += 1
            if (-not (& $parseValue)) { return $false }
            & $skipWhitespace
            if ($state.Index -ge $state.Text.Length) { return $false }
            if ($state.Text[$state.Index] -eq '}') {
                $state.Index += 1
                return $true
            }
            if ($state.Text[$state.Index] -ne ',') { return $false }
            $state.Index += 1
            & $skipWhitespace
        }
    }
    $parseValue = {
        & $skipWhitespace
        if ($state.Index -ge $state.Text.Length) { return $false }
        $character = $state.Text[$state.Index]
        if ($character -eq '{' -or $character -eq '[') {
            $state.Depth += 1
            if ($state.Depth -gt 64) { return $false }
            $parsed = if ($character -eq '{') { & $parseObject } else { & $parseArray }
            $state.Depth -= 1
            return $parsed
        }
        if ($character -eq '"') { return & $parseString }
        if ($character -eq 't') { return & $parseLiteral 'true' }
        if ($character -eq 'f') { return & $parseLiteral 'false' }
        if ($character -eq 'n') { return & $parseLiteral 'null' }
        return & $parseNumber
    }

    & $skipWhitespace
    if ($state.Index -ge $state.Text.Length -or $state.Text[$state.Index] -ne '{') {
        return $false
    }
    if (-not (& $parseValue)) { return $false }
    & $skipWhitespace
    return $state.Index -eq $state.Text.Length
}

# Forward the untouched payload to the chosen tracker over an isolated child process and pass its
# result back verbatim. Running the tracker as a child keeps this router's stdout clean and lets
# the tracker read the payload from its own stdin exactly as it would when invoked directly.
function Invoke-Tracker {
    param([string]$ScriptPath, [string]$RawInput)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { Write-EmptyResult }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-PowerShellPath
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" ' + $EventName
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Write UTF-8 bytes directly so the child sees the exact payload regardless of the parent's
        # console encoding.
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($RawInput)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()

        $stdoutRead = $proc.StandardOutput.ReadToEndAsync()
        $stderrRead = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $out = $stdoutRead.Result
        $null = $stderrRead.Result

        if ($proc.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
            Write-EmptyResult
        }
        if (-not (Test-StrictJsonObject $out)) {
            Write-EmptyResult
        }
        Write-Output ($out.TrimEnd("`r", "`n"))
        exit 0
    }
    catch {
        Write-EmptyResult
    }
}

try {
    $raw = Read-StandardInput
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-EmptyResult }

    try { $payload = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-EmptyResult }

    $workflow = $null
    $rememberWorkflow = $false
    switch ($EventName) {
        { $_ -in @('subagentStart', 'subagentStop') } {
            $workflow = Get-AgentWorkflow ([string]$payload.agentName)
            $rememberWorkflow = $true
        }
        'preToolUse' {
            $toolName = ([string]$payload.toolName).ToLowerInvariant()
            if ($toolName -eq 'task') {
                $workflow = Get-AgentWorkflow (Get-TaskAgentType $payload.toolArgs)
                $currentWorkflow = Get-SessionWorkflow ([string]$payload.sessionId)
                if ($currentWorkflow -and $workflow -and $currentWorkflow -ne $workflow -and
                    (Test-WorkflowEnforcing ([string]$payload.sessionId) $currentWorkflow)) {
                    Write-CrossWorkflowDenial $currentWorkflow $workflow
                }
            }
            elseif ($toolName -eq 'ask_user' -or $toolName -eq 'askuserquestion') {
                $workflow = Get-SessionWorkflow ([string]$payload.sessionId)
            }
        }
        'agentStop' {
            $workflow = Get-SessionWorkflow ([string]$payload.sessionId)
        }
    }

    switch ($workflow) {
        'gates' {
            if ($rememberWorkflow) {
                Set-SessionWorkflow ([string]$payload.sessionId) 'gates'
            }
            Invoke-Tracker (Join-Path $PSScriptRoot 'autodev-gates.ps1') $raw
        }
        'stages' {
            if ($rememberWorkflow) {
                Set-SessionWorkflow ([string]$payload.sessionId) 'stages'
            }
            Invoke-Tracker (Join-Path $PSScriptRoot 'autodev-stages.ps1') $raw
        }
        default { Write-EmptyResult }
    }
}
catch {
    Write-EmptyResult
}

Write-EmptyResult
