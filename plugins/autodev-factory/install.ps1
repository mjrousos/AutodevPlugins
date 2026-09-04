<#
.SYNOPSIS
    Installs the autodev-factory extension where the Copilot CLI will actually find it.

.DESCRIPTION
    Copilot CLI discovers extensions in exactly two places: '<git root>\.github\extensions\' and the
    user's Copilot home ('~\.copilot\extensions\'). Whether an installed plugin can contribute one
    depends on the CLI version, so this script exists to make the outcome certain either way: it
    copies the extension into one of the two directories the CLI is guaranteed to scan.

    After installing, enable experimental features and run /extensions (or restart with
    'copilot --experimental') so the 'autodev-factory' factory becomes available to run_factory.

.PARAMETER Scope
    'User' (default) installs to the Copilot home. 'Project' installs into the current repository's
    .github\extensions directory.

.PARAMETER Uninstall
    Removes a previous install from the selected scope.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev-factory\install.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev-factory\install.ps1 -Scope Project
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Project')]
    [string] $Scope = 'User',

    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$sourceDir = Join-Path $PSScriptRoot 'extensions\autodev-factory'
$required = @('extension.mjs', 'prompts.generated.mjs')

foreach ($file in $required) {
    $path = Join-Path $sourceDir $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "FAIL $path is missing. Run scripts/sync-autodev-prompts.sh to generate the prompt bundle."
        exit 1
    }
}

if ($Scope -eq 'Project') {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
        Write-Error 'FAIL -Scope Project requires the working directory to be inside a git repository.'
        exit 1
    }
    $targetParent = Join-Path ($repoRoot.Trim() -replace '/', '\') '.github\extensions'
}
else {
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $targetParent = Join-Path $copilotHome 'extensions'
}
$targetDir = Join-Path $targetParent 'autodev-factory'
$legacyDir = Join-Path $targetParent 'autodev'

function Remove-LegacyInstall {
    if (-not (Test-Path -LiteralPath $legacyDir -PathType Container)) { return }
    $legacyExtension = Join-Path $legacyDir 'extension.mjs'
    $legacyPrompts = Join-Path $legacyDir 'prompts.generated.mjs'
    $recognized = (Test-Path -LiteralPath $legacyExtension -PathType Leaf) -and
        (Test-Path -LiteralPath $legacyPrompts -PathType Leaf) -and
        (Select-String -LiteralPath $legacyExtension -SimpleMatch 'name: "autodev"' -Quiet)
    if ($recognized) {
        Remove-Item -LiteralPath $legacyDir -Recurse -Force
        Write-Host "removed legacy autodev factory -> $legacyDir"
    }
    else {
        Write-Warning "$legacyDir exists but is not a recognized legacy autodev factory; leaving it unchanged"
    }
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $targetDir) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force
        Write-Host "removed $targetDir"
    }
    else {
        Write-Host "nothing to remove at $targetDir"
    }
    Remove-LegacyInstall
    exit 0
}

Remove-LegacyInstall
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

# Copied file by file rather than as a directory so a stale file left by an older version is
# overwritten without silently inheriting anything else that happens to be sitting in the target.
foreach ($file in $required) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $file) -Destination (Join-Path $targetDir $file) -Force
}

Write-Host "installed autodev-factory extension -> $targetDir"
Write-Host "enable experimental features, then run /extensions (or restart with 'copilot --experimental') and invoke the 'autodev-factory' factory."
