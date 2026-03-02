# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# _Common.ps1 - Shared helpers for all local-run scripts.
# Dot-source this file at the top of each script:
#   . (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Output helpers ───────────────────────────────────────────────────────────
function Write-Success { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host $Message -ForegroundColor Cyan  }
function Write-Warn    { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err     { param([string]$Message) Write-Host $Message -ForegroundColor Red   }

# ─── Azurite (VS Code extension) ──────────────────────────────────────────────
# Azurite is expected to be running via the
# "Azurite" VS Code extension (ms-azuretools.vscode-azurite).
# The scripts do NOT install or start Azurite automatically; instead they
# check whether the expected ports are already listening and guide the user
# to start the extension if they are not.

$AZURITE_BLOB_PORT  = 10000
$AZURITE_QUEUE_PORT = 10001

function Test-PortOpen {
    param([int]$Port)
    $result = Test-NetConnection -ComputerName localhost -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue 2>$null
    return $result
}

<#
.SYNOPSIS
    Verifies that Azurite is running (blob + queue ports open).
    If not, shows clear instructions to start it from VS Code and exits the caller.
.PARAMETER SkipAzurite
    When $true the check is skipped entirely (non-local storage detected).
#>
function Confirm-AzuriteRunning {
    param([bool]$SkipAzurite = $false)

    if ($SkipAzurite) {
        Write-Info "Skipping Azurite check (cloud storage configuration detected)."
        return
    }

    Write-Info "Checking Azurite (VS Code extension)..."

    $blobOk  = Test-PortOpen -Port $AZURITE_BLOB_PORT
    $queueOk = Test-PortOpen -Port $AZURITE_QUEUE_PORT

    if ($blobOk -and $queueOk) {
        Write-Success "✓ Azurite is running (blob :$AZURITE_BLOB_PORT / queue :$AZURITE_QUEUE_PORT)"
        return
    }

    Write-Err ""
    Write-Err "✗ Azurite is not running!"
    Write-Err ""
    Write-Info "Azurite is managed by the VS Code extension, not by npm."
    Write-Info "Start it from VS Code before running this script:"
    Write-Info ""
    Write-Info "  Option 1 – Command Palette  (Ctrl+Shift+P)  →  'Azurite: Start Service'"
    Write-Info "  Option 2 – Status bar       →  click  'Azurite Blob Service' / 'Azurite Queue Service'"
    Write-Info ""
    Write-Info "Extension page: https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-azurite"
    Write-Info ""

    if (-not $blobOk)  { Write-Warn "  Port $AZURITE_BLOB_PORT  (Blob)  – NOT listening" }
    if (-not $queueOk) { Write-Warn "  Port $AZURITE_QUEUE_PORT (Queue) – NOT listening" }

    Write-Err ""
    Write-Err "Start Azurite in VS Code and then re-run this script."
    exit 1
}

<#
.SYNOPSIS
    Reads the ConnectionStringOrUri from a config JSON file and decides
    whether local Azurite is required. Returns a hashtable with:
      NeedsAzurite : [bool]
      ConnString   : [string]
#>
function Get-StorageMode {
    param([string]$ConfigPath)

    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $cs  = $cfg.Migration.Storage.ConnectionStringOrUri

        $isLocal = ($cs -eq "UseDevelopmentStorage=true") -or
                   ($cs -like "*127.0.0.1*") -or
                   ($cs -like "*localhost*")

        if ($isLocal) {
            Write-Info "Detected local storage (Azurite)."
        }
        else {
            Write-Info "Detected cloud storage – Azurite not required."
        }

        return @{ NeedsAzurite = $isLocal; ConnString = $cs }
    }
    catch {
        Write-Warn "⚠ Could not parse config for storage type – assuming Azurite."
        return @{ NeedsAzurite = $true; ConnString = "UseDevelopmentStorage=true" }
    }
}

<#
.SYNOPSIS
    Creates the required Azure Storage containers and queues for local development.
    Uses Azure CLI when available; otherwise emits a warning (resources are created
    automatically on first use).
.PARAMETER HarvestQueueName
    Name of the harvest queue (default: user-ids-to-process).
.PARAMETER PhoneRegQueueName
    Name of the phone-registration queue (default: phone-registration).
    Pass $null or empty string to skip creating this queue.
#>
function Initialize-LocalStorage {
    param(
        [string]$HarvestQueueName  = "user-ids-to-process",
        [string]$PhoneRegQueueName = "phone-registration"
    )

    Write-Info "Initializing local storage resources..."

    $azCli = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCli) {
        Write-Warn "⚠ Azure CLI (az) not found – skipping resource pre-creation."
        Write-Warn "  Resources will be created automatically on first use by the application."
        return
    }

    $cs = "UseDevelopmentStorage=true"
    $errors = 0

    # Blob containers
    foreach ($container in @("user-exports", "migration-errors", "import-audit")) {
        $out = az storage container create --name $container --connection-string $cs --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "  ⚠ Could not create blob container '$container' (may already exist)"
            $errors++
        }
    }

    # Harvest queue (Master/Worker pattern)
    $out = az storage queue create --name $HarvestQueueName --connection-string $cs --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  ⚠ Could not create queue '$HarvestQueueName' (may already exist)"
        $errors++
    }

    # Phone-registration queue (async phone reg worker)
    if ($PhoneRegQueueName) {
        $out = az storage queue create --name $PhoneRegQueueName --connection-string $cs --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "  ⚠ Could not create queue '$PhoneRegQueueName' (may already exist)"
            $errors++
        }
    }

    if ($errors -eq 0) {
        Write-Success "✓ Storage resources ready (containers + queues '$HarvestQueueName', '$PhoneRegQueueName')"
    }
    else {
        Write-Warn "  Some resources could not be pre-created – the app will create them on first use."
    }
}

<#
.SYNOPSIS
    Builds and runs the B2C Migration Kit console application.
.PARAMETER AppDir
    Directory containing the .csproj (must be the working directory for dotnet run).
.PARAMETER Operation
    The operation to pass as the first argument (export, import, harvest, worker-export).
.PARAMETER ConfigFile
    Config file name (relative to AppDir).
.PARAMETER VerboseLogging
    Adds --verbose flag.
#>
function Invoke-ConsoleApp {
    param(
        [string]$AppDir,
        [string]$Operation,
        [string]$ConfigFile,
        [bool]$VerboseLogging = $false
    )

    $appArgs = @($Operation, "--config", $ConfigFile)
    if ($VerboseLogging) { $appArgs += "--verbose" }

    try {
        Push-Location $AppDir

        Write-Info "Building console application..."
        dotnet build --configuration Debug --nologo --verbosity quiet

        if ($LASTEXITCODE -ne 0) {
            Write-Err "Build failed."
            exit 1
        }

        Write-Success "✓ Build successful"
        Write-Host ""

        dotnet run --no-build --configuration Debug -- $appArgs
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
