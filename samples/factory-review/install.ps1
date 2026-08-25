<#
.SYNOPSIS
    Installs the factory-review sample extension where the Copilot CLI will actually find it.

.DESCRIPTION
    Copilot CLI discovers extensions in exactly two places: '<git root>\.github\extensions\' and the
    user's Copilot home ('~\.copilot\extensions\'). Whether an installed plugin can contribute one
    depends on the CLI version, so this script exists to make the outcome certain either way: it
    copies the extension into one of the two directories the CLI is guaranteed to scan.

    After installing, run /extensions in the CLI (or restart it) and the 'sample-review' factory
    becomes available to run_factory.

.PARAMETER Scope
    'User' (default) installs to the Copilot home. 'Project' installs into the current repository's
    .github\extensions directory.

.PARAMETER Uninstall
    Removes a previous install from the selected scope.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File samples\factory-review\install.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File samples\factory-review\install.ps1 -Scope Project
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'Project')]
    [string] $Scope = 'User',

    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$sourceDir = Join-Path $PSScriptRoot 'extensions\factory-review'
$required = @('extension.mjs')

foreach ($file in $required) {
    $path = Join-Path $sourceDir $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "FAIL $path is missing."
        exit 1
    }
}

if ($Scope -eq 'Project') {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
        Write-Error 'FAIL -Scope Project requires the working directory to be inside a git repository.'
        exit 1
    }
    $targetDir = Join-Path ($repoRoot.Trim() -replace '/', '\') '.github\extensions\factory-review'
}
else {
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $targetDir = Join-Path $copilotHome 'extensions\factory-review'
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

Write-Host "installed factory-review extension -> $targetDir"
Write-Host "run /extensions in Copilot CLI (or restart it), then invoke the 'sample-review' factory."
