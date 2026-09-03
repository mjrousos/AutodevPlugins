<#
.SYNOPSIS
    Tests for the autodev hook router (autodev-router.ps1).

.DESCRIPTION
    The router is the single command hooks.json wires every event to. Its only job is to decide
    which enforcement tracker (the planning gate tracker or the implementation stage tracker) owns
    an event, forward the payload to exactly that one, and pass an unrelated event through as the
    empty result. These tests exercise that decision in isolation: the real trackers are replaced
    with stubs that simply announce which one was invoked, so the routing logic is verified without
    depending on either tracker's behaviour.

    Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests/router.tests.ps1
#>
$ErrorActionPreference = 'Stop'

$script:Router = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\scripts\autodev-router.ps1'
if (-not (Test-Path -LiteralPath $script:Router)) {
    Write-Host "Cannot find router at $script:Router" -ForegroundColor Red
    exit 1
}

$script:Passed = 0
$script:Failed = 0

# An isolated Copilot home so the router's per-session state lookups see only what each test sets
# up, and never a real workflow running on the machine.
$script:CopilotHome = Join-Path ([IO.Path]::GetTempPath()) "autodev-router-tests-$PID"
$script:GatesDir = Join-Path (Join-Path $script:CopilotHome 'autodev') 'gates'
$script:StagesDir = Join-Path (Join-Path $script:CopilotHome 'autodev') 'stages'
$env:COPILOT_HOME = $script:CopilotHome

# A sandbox holding a copy of the router beside stub trackers. The router resolves its trackers
# relative to its own location, so a copy next to the stubs makes it call them instead of the real
# ones. Each stub prints a marker naming itself and echoing the event it received.
$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) "autodev-router-sandbox-$PID"
New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
Copy-Item -LiteralPath $script:Router -Destination (Join-Path $script:Sandbox 'autodev-router.ps1') -Force
Set-Content -LiteralPath (Join-Path $script:Sandbox 'autodev-gates.ps1') -Encoding UTF8 -Value @'
param([string]$EventName)
Write-Output ('{"routed":"gates","event":"' + $EventName + '"}')
'@
Set-Content -LiteralPath (Join-Path $script:Sandbox 'autodev-stages.ps1') -Encoding UTF8 -Value @'
param([string]$EventName)
Write-Output ('{"routed":"stages","event":"' + $EventName + '"}')
'@
$script:StubRouter = Join-Path $script:Sandbox 'autodev-router.ps1'

function Reset-State {
    $root = Join-Path $script:CopilotHome 'autodev'
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

function New-StateFile {
    param([string]$Dir, [string]$SessionId)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Set-Content -LiteralPath (Join-Path $Dir "$SessionId.json") -Value '{}' -Encoding UTF8
}

# Runs the stubbed router for one event and returns its stdout, feeding the payload over stdin the
# same way the CLI would.
function Invoke-Router {
    param([string]$EventName, [string]$Payload)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:StubRouter + '" ' + $EventName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return $out.Trim()
}

function Assert-Routed {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Actual -match "`"routed`":`"$Expected`"") {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host "  FAIL  $Name : expected routing to '$Expected' but got: $Actual" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-Empty {
    param([string]$Name, [string]$Actual)
    if (($Actual -replace '\s', '') -eq '{}') {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host "  FAIL  $Name : expected the empty result {} but got: $Actual" -ForegroundColor Red
        $script:Failed++
    }
}

try {
    # --- lifecycle events route by the sub-agent's name ---------------------------------------

    Reset-State
    Assert-Routed "a plan review agent's subagentStart routes to the gate tracker" 'gates' `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-architecture-review"}')

    Reset-State
    Assert-Routed "a plan review agent's subagentStop routes to the gate tracker" 'gates' `
        (Invoke-Router 'subagentStop' '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-security-review"}')

    Reset-State
    Assert-Routed "an implementation agent's subagentStart routes to the stage tracker" 'stages' `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-tasking"}')

    Reset-State
    Assert-Routed "an implementation agent's subagentStop routes to the stage tracker" 'stages' `
        (Invoke-Router 'subagentStop' '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-code-review"}')

    Reset-State
    Assert-Routed "a bare agent name still routes to the right tracker" 'stages' `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"autodev-implementation"}')

    Reset-State
    Assert-Routed "code-security-review routes to stages, not gates" 'stages' `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-code-security-review"}')

    Reset-State
    Assert-Empty "a foreign namespace cannot capture a plan agent name" `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"other-plugin:autodev-security-review"}')

    Reset-State
    Assert-Empty "a foreign namespace cannot capture an implementation agent name" `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"other-plugin:autodev-code-review"}')

    # --- task pre-tool-use routes by the target agent -----------------------------------------

    Reset-State
    Assert-Routed "a task targeting a review gate routes to the gate tracker" 'gates' `
        (Invoke-Router 'preToolUse' '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"autodev:autodev-privacy-review\"}"}')

    Reset-State
    Assert-Routed "a task targeting an implementation stage routes to the stage tracker" 'stages' `
        (Invoke-Router 'preToolUse' '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"autodev:autodev-code-fix\"}"}')

    Reset-State
    Assert-Empty "a task targeting an unrelated agent is not routed" `
        (Invoke-Router 'preToolUse' '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"explore\"}"}')

    Reset-State
    Assert-Empty "a task targeting a foreign autodev-like agent is not routed" `
        (Invoke-Router 'preToolUse' '{"sessionId":"s","cwd":"","toolName":"task","toolArgs":"{\"agent_type\":\"other-plugin:autodev-code-fix\"}"}')

    # --- agentStop and ask_user route by the active session's workflow -------------------------

    Reset-State
    New-StateFile $script:GatesDir 'gonly'
    Assert-Routed "agentStop with only gate state routes to the gate tracker" 'gates' `
        (Invoke-Router 'agentStop' '{"sessionId":"gonly","cwd":""}')

    Reset-State
    New-StateFile $script:StagesDir 'sonly'
    Assert-Routed "agentStop with only stage state routes to the stage tracker" 'stages' `
        (Invoke-Router 'agentStop' '{"sessionId":"sonly","cwd":""}')

    Reset-State
    New-StateFile $script:GatesDir 'ionly'
    Assert-Routed "ask_user with only gate state routes to the gate tracker" 'gates' `
        (Invoke-Router 'preToolUse' '{"sessionId":"ionly","cwd":"","toolName":"ask_user"}')

    Reset-State
    New-StateFile $script:StagesDir 'aonly'
    Assert-Routed "ask_user with only stage state routes to the stage tracker" 'stages' `
        (Invoke-Router 'preToolUse' '{"sessionId":"aonly","cwd":"","toolName":"ask_user"}')

    # When both workflows have state, the most recently written one is the live workflow.
    Reset-State
    New-StateFile $script:StagesDir 'both'
    Start-Sleep -Seconds 1
    New-StateFile $script:GatesDir 'both'
    Assert-Routed "agentStop routes to the more recently active workflow (gate newer)" 'gates' `
        (Invoke-Router 'agentStop' '{"sessionId":"both","cwd":""}')

    Reset-State
    New-StateFile $script:GatesDir 'both'
    Start-Sleep -Seconds 1
    New-StateFile $script:StagesDir 'both'
    Assert-Routed "agentStop routes to the more recently active workflow (stage newer)" 'stages' `
        (Invoke-Router 'agentStop' '{"sessionId":"both","cwd":""}')

    Reset-State
    New-StateFile $script:GatesDir 'tied'
    New-StateFile $script:StagesDir 'tied'
    $tiedTime = [DateTime]::UtcNow.AddMinutes(-1)
    (Get-Item -LiteralPath (Join-Path $script:GatesDir 'tied.json')).LastWriteTimeUtc = $tiedTime
    (Get-Item -LiteralPath (Join-Path $script:StagesDir 'tied.json')).LastWriteTimeUtc = $tiedTime
    Assert-Routed "equal tracker timestamps deterministically route to gates" 'gates' `
        (Invoke-Router 'agentStop' '{"sessionId":"tied","cwd":""}')

    Reset-State
    $null = Invoke-Router 'subagentStart' `
        '{"sessionId":"remembered","cwd":"","agentName":"autodev:autodev-security-review"}'
    Remove-Item -LiteralPath $script:GatesDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:StagesDir -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Routed "the session route survives missing tracker state for mirror recovery" 'gates' `
        (Invoke-Router 'agentStop' '{"sessionId":"remembered","cwd":""}')

    Reset-State
    $null = Invoke-Router 'subagentStart' `
        '{"sessionId":"plan-session","cwd":"","agentName":"autodev:autodev-security-review"}'
    $null = Invoke-Router 'subagentStart' `
        '{"sessionId":"implementation-session","cwd":"","agentName":"autodev:autodev-code-review"}'
    Assert-Routed "session-keyed routes do not interfere with each other" 'gates' `
        (Invoke-Router 'agentStop' '{"sessionId":"plan-session","cwd":""}')

    # --- events that belong to neither tracker return the empty result ------------------------

    Reset-State
    Assert-Empty "an unrelated sub-agent is ignored" `
        (Invoke-Router 'subagentStart' '{"sessionId":"s","cwd":"","agentName":"explore"}')

    Reset-State
    Assert-Empty "an unrelated tool is ignored" `
        (Invoke-Router 'preToolUse' '{"sessionId":"s","cwd":"","toolName":"glob"}')

    Reset-State
    Assert-Empty "agentStop with no active workflow is ignored" `
        (Invoke-Router 'agentStop' '{"sessionId":"nostate","cwd":""}')

    Reset-State
    Assert-Empty "ask_user with no active workflow is ignored" `
        (Invoke-Router 'preToolUse' '{"sessionId":"nostate","cwd":"","toolName":"ask_user"}')

    # --- fail-safe: malformed input never produces anything but the empty result --------------

    Reset-State
    Assert-Empty "invalid JSON is a no-op" (Invoke-Router 'preToolUse' 'this is not json')
    Assert-Empty "empty input is a no-op" (Invoke-Router 'agentStop' '')
    Assert-Empty "an unknown event is a no-op" `
        (Invoke-Router 'somethingElse' '{"sessionId":"s","cwd":"","agentName":"autodev:autodev-tasking"}')
}
finally {
    if (Test-Path -LiteralPath $script:CopilotHome) { Remove-Item -LiteralPath $script:CopilotHome -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $script:Sandbox) { Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
