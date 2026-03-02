# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Worker/Consumer phase – dequeues user-ID batches and exports full profiles
    to Blob Storage using the Graph $batch API.

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Builds and runs the B2C Migration Kit console with the 'worker-export' operation

    Azurite must be started manually from VS Code before running this script:
      Ctrl+Shift+P  →  "Azurite: Start Service"

    Run this AFTER Start-LocalHarvest.ps1 has populated the queue.
    You can open multiple terminals and run this script simultaneously,
    each pointing to a different App Registration config, to multiply throughput:

      Terminal 1:  .\Start-LocalWorkerExport.ps1
      Terminal 2:  .\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.worker2.json
      Terminal 3:  .\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.worker3.json

    Each worker independently dequeues messages, calls Graph $batch for up to 20
    users per HTTP request, uploads results to Blob Storage, and deletes the message.
    If a worker crashes, that message reappears after the visibility timeout (5 min).

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.worker1.json
    For multi-worker runs use per-worker configs: appsettings.worker2.json, etc.

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalWorkerExport.ps1

.EXAMPLE
    .\Start-LocalWorkerExport.ps1 -ConfigFile "appsettings.worker2.json" -VerboseLogging

.EXAMPLE
    .\Start-LocalWorkerExport.ps1 -SkipAzurite
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.worker1.json",

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

# ─── Header ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Worker Export (Consumer phase)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Validate config file
if (-not (Test-Path $configPath)) {
    Write-Err "Configuration file not found: $configPath"
    Write-Info "Create it or use -ConfigFile to specify a different path."
    exit 1
}
Write-Success "✓ Configuration: $ConfigFile"

# Detect storage mode
$storage   = Get-StorageMode -ConfigPath $configPath
$skipCheck = ($SkipAzurite -or -not $storage.NeedsAzurite)

# Verify Azurite is running (VS Code extension)
Confirm-AzuriteRunning -SkipAzurite $skipCheck

# ─── Run ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Starting worker export: dequeue → Graph `$batch → Blob Storage..."
Write-Info "Worker will stop automatically when the queue is empty."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir         $consoleAppDir `
    -Operation      "worker-export" `
    -ConfigFile     $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Worker export completed successfully!"
    Write-Success "═══════════════════════════════════════════════════════"
} else {
    Write-Err "═══════════════════════════════════════════════════════"
    Write-Err "  Worker export finished with errors (exit code $exitCode)"
    Write-Err "  Some messages may still be in the queue for retry."
    Write-Err "  Re-run this script to process remaining messages."
    Write-Err "═══════════════════════════════════════════════════════"
}
Write-Host ""
exit $exitCode
