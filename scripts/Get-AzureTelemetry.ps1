<#
.SYNOPSIS
    Downloads telemetry JSONL files from all Azure VMs and optionally analyzes them.

.DESCRIPTION
    Uses Bastion SSH tunnels to SCP telemetry files from each VM's ~/app/ directory.
    Files are saved to a local timestamped folder. Optionally runs Analyze-Telemetry.ps1.

.PARAMETER ResourceGroup
    Azure resource group. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion name. Default: bas-b2c-migration

.PARAMETER VmCount
    Number of worker VMs. Default: 2

.PARAMETER OutputDir
    Base output directory. Default: ./telemetry

.PARAMETER SshKeyPath
    SSH private key path. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.PARAMETER Analyze
    Run Analyze-Telemetry.ps1 on downloaded files after download.

.EXAMPLE
    .\scripts\Get-AzureTelemetry.ps1
    .\scripts\Get-AzureTelemetry.ps1 -Analyze
    .\scripts\Get-AzureTelemetry.ps1 -VmCount 4 -OutputDir C:\telemetry -Analyze
#>
param(
    [string]$ResourceGroup = 'rg-b2c-migration',
    [string]$BastionName   = 'bas-b2c-migration',
    [int]   $VmCount       = 2,
    [string]$OutputDir     = './telemetry',
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key",
    [switch]$Analyze
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_Common.ps1")

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Download Azure Telemetry"         -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Create timestamped output folder
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$destDir   = Join-Path $OutputDir $timestamp
New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Write-Info "Output directory: $destDir"
Write-Host ""

if (-not (Test-Path $SshKeyPath)) {
    Write-Err "SSH key not found at '$SshKeyPath'."
    exit 1
}

$downloadedFiles = 0
$failedVms       = 0

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName = "vm-b2c-worker${i}"
    Write-Info "Downloading telemetry from $vmName..."

    # Resolve VM resource ID
    $vmId = az vm show -g $ResourceGroup -n $vmName --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "  ✗ Could not resolve VM '$vmName'"
        $failedVms++
        continue
    }

    $localPort = 2200 + $i

    # Open Bastion tunnel in background
    $tunnelProcess = Start-Process -FilePath 'az' -ArgumentList @(
        'network', 'bastion', 'tunnel',
        '--name', $BastionName,
        '--resource-group', $ResourceGroup,
        '--target-resource-id', $vmId,
        '--resource-port', '22',
        '--port', $localPort
    ) -PassThru -WindowStyle Hidden

    Start-Sleep -Seconds 10

    try {
        # List telemetry files on the VM
        $fileList = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
            -p $localPort -i $SshKeyPath `
            "azureuser@127.0.0.1" "ls ~/app/*-telemetry.jsonl 2>/dev/null || echo 'NO_FILES'"

        if ($fileList -match 'NO_FILES') {
            Write-Warn "  ⚠ $vmName — no telemetry files found"
            continue
        }

        # SCP all telemetry files
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
            -P $localPort -i $SshKeyPath `
            "azureuser@127.0.0.1:~/app/*-telemetry.jsonl" "$destDir/"

        if ($LASTEXITCODE -eq 0) {
            Write-Success "  ✓ $vmName — files downloaded"
            $downloadedFiles++
        }
        else {
            Write-Warn "  ⚠ $vmName — SCP returned exit code $LASTEXITCODE"
            $failedVms++
        }
    }
    catch {
        Write-Err "  ✗ $vmName — error: $_"
        $failedVms++
    }
    finally {
        try { Stop-Process -Id $tunnelProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Downloaded from: $downloadedFiles / $VmCount VMs"     -ForegroundColor $(if ($failedVms -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Output: $destDir"                                     -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# List downloaded files
$files = Get-ChildItem -Path $destDir -Filter "*-telemetry.jsonl" -ErrorAction SilentlyContinue
if ($files) {
    Write-Info "Downloaded files:"
    $files | ForEach-Object { Write-Host "  $_  ($([Math]::Round($_.Length / 1KB, 1)) KB)" }
    Write-Host ""
}

# Optionally run analysis
if ($Analyze -and $files) {
    Write-Info "Running telemetry analysis..."
    Write-Host ""
    & (Join-Path $PSScriptRoot "Analyze-Telemetry.ps1") -ConsoleDir $destDir -WorkerCount $VmCount
}
