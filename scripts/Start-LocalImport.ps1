# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Runs the External ID import operation locally.

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Pre-creates required blob containers using Azure CLI (if available)
    3. Builds and runs the B2C Migration Kit console with the 'import' operation

    Azurite must be started manually from VS Code before running this script:
      Ctrl+Shift+P  →  "Azurite: Start Service"

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.local.json

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalImport.ps1

.EXAMPLE
    .\Start-LocalImport.ps1 -ConfigFile "appsettings.dev.json" -VerboseLogging

.EXAMPLE
    .\Start-LocalImport.ps1 -SkipAzurite
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.local.json",

    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAzurite
)

$ErrorActionPreference = "Stop"

# Shared helpers
. (Join-Path $PSScriptRoot "_Common.ps1")

$rootDir       = Split-Path -Parent $PSScriptRoot
$consoleAppDir = Join-Path $rootDir "src\B2CMigrationKit.Console"
$configPath    = Join-Path $consoleAppDir $ConfigFile

# ─── Header ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Local Import" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Validate config file
if (-not (Test-Path $configPath)) {
    Write-Err "Configuration file not found: $configPath"
    Write-Info "Create it or use -ConfigFile to specify a different path."
    exit 1
}
Write-Success "✓ Configuration: $ConfigFile"

# Detect storage mode
$storage = Get-StorageMode -ConfigPath $configPath
$skipCheck = ($SkipAzurite -or -not $storage.NeedsAzurite)

# Verify Azurite is running (VS Code extension)
Confirm-AzuriteRunning -SkipAzurite $skipCheck

# Pre-create storage resources
if (-not $skipCheck) {
    Initialize-LocalStorage
}

# ─── Run ───────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Starting import to Entra External ID..."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir        $consoleAppDir `
    -Operation     "import" `
    -ConfigFile    $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
switch ($exitCode) {
    0 {
        Write-Success "═══════════════════════════════════════════════════"
        Write-Success "  Import completed successfully!"
        Write-Success "═══════════════════════════════════════════════════"
    }
    2 {
        Write-Warn    "═══════════════════════════════════════════════════"
        Write-Warn    "  Import completed with some failures (exit 2)"
        Write-Warn    "  Check logs for individual user errors."
        Write-Warn    "═══════════════════════════════════════════════════"
    }
    default {
        Write-Err     "═══════════════════════════════════════════════════"
        Write-Err     "  Import failed (exit code $exitCode)"
        Write-Err     "═══════════════════════════════════════════════════"
    }
}
Write-Host ""
exit $exitCode
