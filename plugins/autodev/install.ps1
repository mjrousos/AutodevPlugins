<#
.SYNOPSIS
    Installs the autodev factory extension where the Copilot CLI will actually find it.

.DESCRIPTION
    Copilot CLI discovers extensions in exactly two places: '<git root>\.github\extensions\' and the
    user's Copilot home ('~\.copilot\extensions\'). Whether an installed plugin can contribute one
    depends on the CLI version, so this script exists to make the outcome certain either way: it
    copies the extension into one of the two directories the CLI is guaranteed to scan.

    After installing, run /extensions in the CLI (or restart it) and the 'autodev' factory becomes
    available to run_factory.

.PARAMETER Scope
    'User' (default) installs to the Copilot home. 'Project' installs into the current repository's
    .github\extensions directory.

.PARAMETER Uninstall
    Removes a previous install from the selected scope.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev\install.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File plugins\autodev\install.ps1 -Scope Project
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Project')]
    [string] $Scope = 'User',

    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$sourceDir = Join-Path $PSScriptRoot 'extensions\autodev'
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
    $targetDir = Join-Path ($repoRoot.Trim() -replace '/', '\') '.github\extensions\autodev'
}
else {
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $targetDir = Join-Path $copilotHome 'extensions\autodev'
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $targetDir) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force
        Write-Host "removed $targetDir"
    }
    else {
        Write-Host "nothing to remove at $targetDir"
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

# Copied file by file rather than as a directory so a stale file left by an older version is
# overwritten without silently inheriting anything else that happens to be sitting in the target.
foreach ($file in $required) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $file) -Destination (Join-Path $targetDir $file) -Force
}

Write-Host "installed autodev extension -> $targetDir"
Write-Host "run /extensions in Copilot CLI (or restart it), then invoke the 'autodev' factory."
