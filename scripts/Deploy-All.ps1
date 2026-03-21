<#
.SYNOPSIS
    Full end-to-end deployment of the B2C Migration Kit to Azure VMs.

.DESCRIPTION
    Orchestrates the complete deployment pipeline:
      1. Deploy infrastructure via Bicep
      2. Provision each VM: git clone → dotnet publish → config from Key Vault
      VMs build the app themselves (no blob upload needed).

.EXAMPLE
    ./Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\b2c-mig-deploy.pub

.EXAMPLE
    ./Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SkipInfra -VmCount 2

.EXAMPLE
    ./Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = 'eastus2',

    [string]$StorageAccountName,

    [ValidateRange(1, 16)]
    [int]$VmCount = 4,

    [string]$VmSize = 'Standard_B2s',

    [string]$AdminUsername = 'azureuser',

    [string]$SshPublicKeyFile = "$HOME/.ssh/id_ed25519.pub",

    [bool]$DeployBastion = $true,

    [string]$GitRepo = '',

    [string]$GitBranch = '',

    [string]$ConfigProfile = 'worker',

    [switch]$SkipInfra
)

$ErrorActionPreference = 'Stop'

# Auto-detect repo URL and branch from the local git repo if not specified
if (-not $GitRepo) {
    $GitRepo = git remote get-url origin 2>$null
    if (-not $GitRepo) {
        $GitRepo = 'https://github.com/microsoft/b2c-to-meeid-migration-tool.git'
    }
}
if (-not $GitBranch) {
    $GitBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if (-not $GitBranch) {
        $GitBranch = 'main'
    }
}

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
    Write-Info "[WhatIf] Would run: az deployment sub create --location $Location --template-file infra/main.bicep"
}
else {
    # Read SSH public key
    if (-not (Test-Path $SshPublicKeyFile)) {
        Write-Err "SSH public key not found at $SshPublicKeyFile"
        Write-Err "Generate one: ssh-keygen -t ed25519 -C 'b2c-migration'"
        Write-Err "Or pass -SshPublicKeyFile <path>"
        exit 1
    }
    $sshKey = (Get-Content $SshPublicKeyFile -Raw).Trim()

    Write-Info "Deploying Bicep template (this may take 10-20 minutes)..."
    az deployment sub create `
        --location $Location `
        --template-file (Join-Path $infraDir "main.bicep") `
        --parameters `
            resourceGroupName=$ResourceGroup `
            location=$Location `
            storageAccountName=$StorageAccountName `
            vmCount=$VmCount `
            vmSize=$VmSize `
            adminUsername=$AdminUsername `
            adminSshPublicKey=$sshKey `
            deployBastion=$DeployBastion `
        --name "b2c-migration-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    if ($LASTEXITCODE -ne 0) {
        Confirm-Continue "Infrastructure deployment failed."
    }
    else {
        Write-Success "✓ Infrastructure deployed."
    }
}

# ─── Step 2: Provision VMs (git clone + build on each VM) ────────────────────

Write-Step 2 "Provision Worker VMs"

Write-Info "Strategy: Each VM clones the repo from GitHub and builds locally."
Write-Info "Repo:     $GitRepo"
Write-Info "Branch:   $GitBranch"
Write-Host ""

$provisionedVms = 0
$failedVms = @()

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName = "vm-b2c-worker$i"

    Write-Info "Provisioning $vmName ..."

    if ($WhatIfPreference) {
        Write-Info "  [WhatIf] Would run git clone + dotnet publish on $vmName via az vm run-command."
        continue
    }

    # The script runs on the VM as root via run-command.
    # It installs prerequisites itself in case cloud-init used an older template.
    $scriptContent = @"
#!/bin/bash
set -euo pipefail

export HOME=/root
export DOTNET_CLI_HOME=/root

DEPLOY_DIR=/opt/b2c-migration/app
REPO_DIR=/opt/b2c-migration/repo

echo "=== Installing prerequisites ==="
if ! command -v git &>/dev/null || ! command -v dotnet &>/dev/null || ! dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then
    # Ensure Microsoft package repo is registered
    if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]; then
        wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/ms-prod.deb
        dpkg -i /tmp/ms-prod.deb
    fi
    apt-get update -y
    apt-get install -y dotnet-sdk-8.0 git
    echo "Prerequisites installed."
else
    echo "Prerequisites already present."
fi

mkdir -p `$DEPLOY_DIR
mkdir -p /opt/b2c-migration/telemetry
chmod 775 `$DEPLOY_DIR /opt/b2c-migration/telemetry

echo "=== Cloning repo ==="
rm -rf `$REPO_DIR
git clone --depth 1 --branch $GitBranch $GitRepo `$REPO_DIR

echo "=== Building ==="
dotnet publish `$REPO_DIR/src/B2CMigrationKit.Console/B2CMigrationKit.Console.csproj \
    --configuration Release \
    --output `$DEPLOY_DIR \
    --nologo \
    --verbosity quiet

chmod +x `$DEPLOY_DIR/B2CMigrationKit.Console 2>/dev/null || true
chown -R ${AdminUsername}:${AdminUsername} `$DEPLOY_DIR /opt/b2c-migration/telemetry

echo "=== Setup complete for $vmName ==="
echo "App deployed to `$DEPLOY_DIR"
"@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "setup-$vmName.sh"
    $scriptContent | Set-Content -Path $tempScript -NoNewline

    $result = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $vmName `
        --command-id RunShellScript `
        --scripts "@$tempScript" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  run-command failed for $vmName (may be blocked by policy)."
        Write-Warn "  $result"
        $failedVms += $vmName
    }
    else {
        # Extract stdout/stderr from the JSON response
        try {
            $json = $result | ConvertFrom-Json
            $msg = $json.value[0].message
            if ($msg -match '\[stderr\]\s*\S') {
                Write-Warn "  $vmName completed with warnings:"
                Write-Host $msg
                $failedVms += $vmName
            }
            else {
                Write-Success "  $vmName provisioned."
            }
        }
        catch {
            Write-Success "  $vmName provisioned."
        }
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
        Write-Info "  3. Run:          bash /opt/b2c-migration/repo/scripts/Setup-Worker.sh"
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
    Write-Info "VMs Provisioned:   $provisionedVms / $VmCount"
    if ($failedVms.Count -gt 0) {
        Write-Warn "VMs Pending:       $($failedVms -join ', ')"
    }
}

Write-Host ""
Write-Info "Next steps:"
Write-Info "  1. Connect via Bastion:"
Write-Info "       ./scripts/Connect-Worker.ps1 -WorkerIndex 1"
Write-Info "       ssh -p 2201 $AdminUsername@localhost"
Write-Host ""
Write-Info "  2. Copy your worker config to the VM:"
Write-Info "       scp -P 2201 appsettings.worker1.json ${AdminUsername}@localhost:/opt/b2c-migration/app/appsettings.json"
Write-Host ""
Write-Info "  3. Run migration on each VM:"
Write-Info "       cd /opt/b2c-migration/app"
Write-Info "       ./B2CMigrationKit.Console harvest --config appsettings.json        # ONE worker only"
Write-Info "       ./B2CMigrationKit.Console worker-migrate --config appsettings.json # ALL workers"
Write-Info "       ./B2CMigrationKit.Console phone-registration --config appsettings.json"
Write-Host ""
Write-Info "  4. Monitor from local machine:"
Write-Info "       ./scripts/Watch-Migration.ps1 -WorkerCount $VmCount"
Write-Host ""
Write-Success "Done!"
