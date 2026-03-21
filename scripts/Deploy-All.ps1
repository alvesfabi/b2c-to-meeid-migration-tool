<#
.SYNOPSIS
    Full end-to-end deployment of the B2C Migration Kit to Azure VMs.

.DESCRIPTION
    Orchestrates the complete deployment pipeline:
      1. Deploy infrastructure via Bicep
      2. Build the .NET console app (self-contained linux-x64)
      3. Upload app tarball to Blob Storage
      4. Upload per-worker configs to Key Vault
      5. Provision each VM via az vm run-command (or print Bastion instructions)

.EXAMPLE
    ./Deploy-All.ps1 -StorageAccountName stb2cmig123

.EXAMPLE
    ./Deploy-All.ps1 -StorageAccountName stb2cmig123 -SkipInfra -SkipBuild -VmCount 2

.EXAMPLE
    ./Deploy-All.ps1 -StorageAccountName stb2cmig123 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = 'eastus2',

    [string]$StorageAccountName,

    [ValidateRange(1, 16)]
    [int]$VmCount = 4,

    [string]$ConfigProfile = 'worker',

    [switch]$SkipInfra,

    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Auto-generate StorageAccountName if not provided ─────────────────────────
if (-not $StorageAccountName) {
    $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    $sanitizedRg = ($ResourceGroup -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($sanitizedRg.Length -gt 14) { $sanitizedRg = $sanitizedRg.Substring(0, 14) }
    $StorageAccountName = "st${sanitizedRg}${suffix}"

    # Check if it's available
    $available = az storage account check-name --name $StorageAccountName --query nameAvailable -o tsv 2>$null
    if ($available -ne 'true') {
        # Retry with different suffix
        $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $StorageAccountName = "st${sanitizedRg}${suffix}"
    }

    Write-Host "Auto-generated storage account name: $StorageAccountName" -ForegroundColor Cyan
}

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$infraDir   = Join-Path $repoRoot "infra"
$consoleDir = Join-Path $repoRoot "src" "B2CMigrationKit.Console"
$publishDir = Join-Path $consoleDir "bin" "publish"
$tarball    = Join-Path $publishDir "b2c-migration-app.tar.gz"

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Host "  Step ${Number}: $Title" -ForegroundColor Magenta
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Host ""
}

function Confirm-Continue {
    param([string]$Message)
    Write-Err $Message
    $choice = Read-Host "Continue anyway? [y/N]"
    if ($choice -notin @('y', 'Y', 'yes')) {
        Write-Err "Aborted."
        exit 1
    }
}

# ─── Preflight ────────────────────────────────────────────────────────────────

Write-Info "Verifying Azure CLI is logged in..."
$account = az account show --query "{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Err "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Success "✓ Azure CLI: $($account.name) ($($account.id))"

# ─── Step 1: Deploy Infrastructure ───────────────────────────────────────────

Write-Step 1 "Deploy Infrastructure"

if ($SkipInfra) {
    Write-Warn "Skipping infrastructure deployment (-SkipInfra)."
}
elseif ($WhatIfPreference) {
    Write-Info "[WhatIf] Would run: az deployment sub create --location $Location --template-file infra/main.bicep --parameters infra/main.bicepparam"
}
else {
    Write-Info "Deploying Bicep template (this may take 10-20 minutes)..."
    az deployment sub create `
        --location $Location `
        --template-file (Join-Path $infraDir "main.bicep") `
        --parameters (Join-Path $infraDir "main.bicepparam") `
        --name "b2c-migration-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    if ($LASTEXITCODE -ne 0) {
        Confirm-Continue "Infrastructure deployment failed."
    }
    else {
        Write-Success "✓ Infrastructure deployed."
    }
}

# ─── Step 2: Build Console App ───────────────────────────────────────────────

Write-Step 2 "Build Console App"

if ($SkipBuild) {
    Write-Warn "Skipping build (-SkipBuild)."
    if (-not (Test-Path $tarball)) {
        Write-Err "Tarball not found at $tarball — cannot skip build."
        exit 1
    }
}
elseif ($WhatIfPreference) {
    Write-Info "[WhatIf] Would run: dotnet publish (linux-x64 self-contained) + tar"
}
else {
    Write-Info "Publishing self-contained linux-x64 build..."
    dotnet publish $consoleDir `
        --configuration Release `
        --runtime linux-x64 `
        --self-contained true `
        --output $publishDir `
        --nologo `
        --verbosity quiet

    if ($LASTEXITCODE -ne 0) {
        Confirm-Continue "dotnet publish failed."
    }
    else {
        Write-Success "✓ Build complete."
    }

    Write-Info "Creating tarball..."
    Push-Location $publishDir
    try {
        tar czf "b2c-migration-app.tar.gz" -C $publishDir --exclude "b2c-migration-app.tar.gz" .
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $tarball)) {
        Write-Err "Tarball creation failed."
        exit 1
    }

    $sizeMb = [math]::Round((Get-Item $tarball).Length / 1MB, 1)
    Write-Success "✓ Tarball created: $tarball ($sizeMb MB)"
}

# ─── Step 3: Upload Tarball to Blob Storage ──────────────────────────────────

Write-Step 3 "Upload App to Blob Storage"

if ($WhatIfPreference) {
    Write-Info "[WhatIf] Would upload $tarball to blob container 'app-deploy'."
}
else {
    Write-Info "Uploading tarball to storage account '$StorageAccountName'..."
    az storage blob upload `
        --account-name $StorageAccountName `
        --container-name "app-deploy" `
        --name "b2c-migration-app.tar.gz" `
        --file $tarball `
        --auth-mode login `
        --overwrite

    if ($LASTEXITCODE -ne 0) {
        Confirm-Continue "Blob upload failed."
    }
    else {
        Write-Success "✓ Tarball uploaded to blob storage."
    }
}

# ─── Step 4: Upload Configs to Key Vault ─────────────────────────────────────

Write-Step 4 "Upload Worker Configs to Key Vault"

$kvName = az keyvault list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
if (-not $kvName) {
    Write-Warn "Could not find Key Vault in resource group '$ResourceGroup'."
    Write-Warn "Skipping config upload. Upload manually after Key Vault is available."
}
else {
    Write-Info "Key Vault: $kvName"

    $configsUploaded = 0
    for ($i = 1; $i -le $VmCount; $i++) {
        $configFile = Join-Path $repoRoot "appsettings.${ConfigProfile}${i}.json"
        $secretName = "appsettings-${ConfigProfile}${i}"

        if (-not (Test-Path $configFile)) {
            Write-Warn "  Config file not found: $configFile — skipping."
            continue
        }

        if ($WhatIfPreference) {
            Write-Info "  [WhatIf] Would upload $configFile as secret '$secretName'."
        }
        else {
            Write-Info "  Uploading $configFile → $secretName ..."
            az keyvault secret set `
                --vault-name $kvName `
                --name $secretName `
                --file $configFile `
                --only-show-errors | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Write-Warn "  ⚠ Failed to upload $secretName."
            }
            else {
                $configsUploaded++
            }
        }
    }

    if (-not $WhatIfPreference) {
        Write-Success "✓ $configsUploaded / $VmCount configs uploaded to Key Vault."
    }
}

# ─── Step 5: Provision VMs ───────────────────────────────────────────────────

Write-Step 5 "Provision Worker VMs"

$provisionedVms = 0
$failedVms = @()

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName    = "vm-b2c-worker$i"
    $secretName = "appsettings-${ConfigProfile}${i}"

    Write-Info "Provisioning $vmName ..."

    if ($WhatIfPreference) {
        Write-Info "  [WhatIf] Would run Setup-Worker.sh on $vmName via az vm run-command."
        continue
    }

    $scriptContent = @"
#!/bin/bash
set -euo pipefail
az login --identity --allow-no-subscriptions
DEPLOY_DIR=/opt/b2c-migration/app
sudo mkdir -p `$DEPLOY_DIR
sudo chown `$(whoami) `$DEPLOY_DIR
az storage blob download --account-name $StorageAccountName --container-name app-deploy --name b2c-migration-app.tar.gz --file /tmp/b2c-migration-app.tar.gz --auth-mode login
tar xzf /tmp/b2c-migration-app.tar.gz -C `$DEPLOY_DIR
chmod +x `$DEPLOY_DIR/B2CMigrationKit.Console
az keyvault secret show --vault-name $kvName --name $secretName --query value -o tsv > `$DEPLOY_DIR/appsettings.json
echo "Setup complete for $vmName"
"@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "setup-$vmName.sh"
    $scriptContent | Set-Content -Path $tempScript -NoNewline

    az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $vmName `
        --command-id RunShellScript `
        --scripts "@$tempScript" 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  ⚠ run-command failed for $vmName (may be blocked by policy)."
        $failedVms += $vmName
    }
    else {
        Write-Success "  ✓ $vmName provisioned."
        $provisionedVms++
    }

    Remove-Item $tempScript -ErrorAction SilentlyContinue
}

if (-not $WhatIfPreference) {
    if ($failedVms.Count -gt 0) {
        Write-Host ""
        Write-Warn "Some VMs could not be provisioned via run-command."
        Write-Warn "Deploy manually via Bastion for: $($failedVms -join ', ')"
        Write-Host ""
        Write-Info "Manual steps per VM:"
        Write-Info "  1. Open tunnel:  ./scripts/Connect-Worker.ps1 -WorkerIndex <N>"
        Write-Info "  2. SSH:          ssh -p 220<N> azureuser@localhost"
        Write-Info "  3. Run:          bash Setup-Worker.sh $StorageAccountName $kvName appsettings-<profile><N>"
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "  Deployment Summary" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""

if ($WhatIfPreference) {
    Write-Info "[WhatIf] Dry run complete — no changes were made."
}
else {
    Write-Info "Resource Group:    $ResourceGroup"
    Write-Info "Storage Account:   $StorageAccountName"
    Write-Info "Key Vault:         $($kvName ?? '(not found)')"
    Write-Info "VMs Provisioned:   $provisionedVms / $VmCount"
    if ($failedVms.Count -gt 0) {
        Write-Warn "VMs Pending:       $($failedVms -join ', ')"
    }
}

Write-Host ""
Write-Info "Next steps:"
Write-Info "  1. Connect via Bastion:"
Write-Info "       ./scripts/Connect-Worker.ps1 -WorkerIndex 1"
Write-Info "       ssh -p 2201 azureuser@localhost"
Write-Host ""
Write-Info "  2. Run migration on each VM:"
Write-Info "       cd /opt/b2c-migration/app"
Write-Info "       ./B2CMigrationKit.Console harvest --config appsettings.json        # ONE worker only"
Write-Info "       ./B2CMigrationKit.Console worker-migrate --config appsettings.json # ALL workers"
Write-Info "       ./B2CMigrationKit.Console phone-registration --config appsettings.json"
Write-Host ""
Write-Info "  3. Monitor from local machine:"
Write-Info "       ./scripts/Watch-Migration.ps1 -WorkerCount $VmCount"
Write-Host ""
Write-Success "Done!"
