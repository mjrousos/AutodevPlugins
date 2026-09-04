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

# The router records its own session-keyed workflow marker before dispatching a lifecycle or task
# event. Tracker state is a compatibility fallback for sessions that began before the marker
# existed. Workspace mirrors remain solely the trackers' recovery mechanism.
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

        $out = $proc.StandardOutput.ReadToEnd()
        $null = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ([string]::IsNullOrWhiteSpace($out)) { Write-EmptyResult }
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
