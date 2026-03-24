# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Initializes the migration environment: creates app registrations, ensures
    extension properties, and generates appsettings.workerN.json files.

.DESCRIPTION
    Idempotent setup script that prepares both tenants for migration:
      1. Creates (or reuses) B2C app registrations with User.Read.All.
      2. Creates (or reuses) External ID app registrations with User.ReadWrite.All.
      3. Ensures extension properties (B2CObjectId, RequiresMigration) exist on the
         EEID ExtensionApp.
      4. Generates appsettings.workerN.json files with all credentials.

    The script is fully idempotent — safe to re-run. Existing app registrations are
    reused (matched by display name), and extension properties are only created if missing.

    Authentication is performed via device code flow — you will be prompted to sign in
    as a Global Administrator once per tenant (unless skipped).

.PARAMETER StartWorker
    First worker number to provision.  Default: 5.

.PARAMETER EndWorker
    Last worker number to provision.  Default: 8.

.PARAMETER ConfigFile
    appsettings JSON file from which tenant IDs and shared configuration are read.
    Default: appsettings.worker1.json.

.PARAMETER SecretExpiryYears
    Validity period for generated client secrets, in years.  Default: 2.

.PARAMETER Force
    Overwrite existing appsettings.workerN.json files.
    Without this flag, workers whose config file already exists are skipped.

.PARAMETER SkipB2C
    Skip creating B2C app registrations.  Credentials are read from the ConfigFile.

.PARAMETER SkipEEID
    Skip creating External ID app registrations.  Credentials are read from the ConfigFile.
    NOTE: EEID authentication is still performed to ensure extension properties exist.

.PARAMETER WhatIf
    Print every action that would be taken without calling any Graph API or writing any file.

.EXAMPLE
    # Full setup for workers 1-3 (apps + extension properties + configs)
    .\Initialize-MigrationEnvironment.ps1 -StartWorker 1 -EndWorker 3 -Force

.EXAMPLE
    # Skip B2C (apps already exist), create EEID apps + extension properties
    .\Initialize-MigrationEnvironment.ps1 -StartWorker 1 -EndWorker 3 -SkipB2C -Force

.EXAMPLE
    # Only ensure extension properties (skip all app creation, rewrite configs)
    .\Initialize-MigrationEnvironment.ps1 -StartWorker 1 -EndWorker 3 -SkipB2C -SkipEEID -Force

.EXAMPLE
    # Preview everything without touching Azure
    .\Initialize-MigrationEnvironment.ps1 -WhatIf
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 99)]
    [int]$StartWorker = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 99)]
    [int]$EndWorker = 8,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.worker1.json",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 5)]
    [int]$SecretExpiryYears = 2,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipB2C,

    [Parameter(Mandatory = $false)]
    [switch]$SkipEEID,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Shared helpers (Write-Success / Write-Info / Write-Warn / Write-Err)
. (Join-Path $PSScriptRoot "_Common.ps1")

# Well-known Graph IDs and helper functions are now in _Common.ps1
# ($GRAPH_APP_ID, $PERM_USER_READ_ALL, $PERM_USER_READWRITE, $DEVICE_CODE_CLIENT,
#  Get-DeviceCodeToken, Invoke-Graph, Get-GraphSpId, New-WorkerApp, New-WorkerAppSettingsContent)

# ─── Resolve paths ─────────────────────────────────────────────────────────────
$rootDir       = Split-Path -Parent $PSScriptRoot
$consoleAppDir = Join-Path $rootDir "src\B2CMigrationKit.Console"
$configPath    = if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile }
                 else { Join-Path $consoleAppDir $ConfigFile }

if (-not (Test-Path $configPath)) {
    Write-Err "Config not found: $configPath"
    Write-Info "Use -ConfigFile to point to an existing appsettings file."
    exit 1
}

# ─── Read template config ──────────────────────────────────────────────────────
try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
}
catch {
    Write-Err "Failed to parse config file: $_"
    exit 1
}

$b2cTenantId      = $cfg.Migration.B2C.TenantId
$b2cTenantDomain  = $cfg.Migration.B2C.TenantDomain
$eeidTenantId     = $cfg.Migration.ExternalId.TenantId
$eeidTenantDomain = $cfg.Migration.ExternalId.TenantDomain
$extensionAppId   = $cfg.Migration.ExternalId.ExtensionAppId

foreach ($field in @("b2cTenantId","b2cTenantDomain","eeidTenantId","eeidTenantDomain","extensionAppId")) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable $field).Value)) {
        Write-Err "Missing required field in config: $field"
        exit 1
    }
}

# ─── Header ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit – Initialize Migration Environment"       -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Info "Workers to provision : $StartWorker – $EndWorker ($($EndWorker - $StartWorker + 1) worker(s))"
if ($SkipB2C)  { Write-Warn "SkipB2C  : B2C app creation will be skipped (using credentials from config)" }
if ($SkipEEID) { Write-Warn "SkipEEID : EEID app creation will be skipped (using credentials from config)" }
Write-Info "B2C tenant           : $b2cTenantDomain  ($b2cTenantId)"
Write-Info "External ID tenant   : $eeidTenantDomain  ($eeidTenantId)"
Write-Info "Secret expiry        : $SecretExpiryYears year(s)"
Write-Info "Output directory     : $consoleAppDir"
if ($WhatIf) {
    Write-Host ""
    Write-Warn "⚠ WhatIf – no Graph API calls will be made and no files will be written"
}
Write-Host ""

if ($StartWorker -gt $EndWorker) {
    Write-Err "StartWorker ($StartWorker) must be <= EndWorker ($EndWorker)"
    exit 1
}

# Validate skip flags have required credentials in config
if ($SkipB2C -and (-not $WhatIf)) {
    $B2CClientId     = $cfg.Migration.B2C.AppRegistration.ClientId
    $B2CClientSecret = $cfg.Migration.B2C.AppRegistration.ClientSecret
    if ([string]::IsNullOrWhiteSpace($B2CClientId) -or [string]::IsNullOrWhiteSpace($B2CClientSecret)) {
        Write-Err "-SkipB2C requires B2C.AppRegistration.ClientId and ClientSecret in the config file"
        exit 1
    }
    Write-Info "B2C credentials read from config: ClientId=$($B2CClientId.Substring(0,8))…"
}
if ($SkipEEID -and (-not $WhatIf)) {
    $EEIDClientId     = $cfg.Migration.ExternalId.AppRegistration.ClientId
    $EEIDClientSecret = $cfg.Migration.ExternalId.AppRegistration.ClientSecret
    if ([string]::IsNullOrWhiteSpace($EEIDClientId) -or [string]::IsNullOrWhiteSpace($EEIDClientSecret)) {
        Write-Err "-SkipEEID requires ExternalId.AppRegistration.ClientId and ClientSecret in the config file"
        exit 1
    }
    Write-Info "EEID credentials read from config: ClientId=$($EEIDClientId.Substring(0,8))…"
}

# ─── Check for already-existing output files (before authenticating) ───────────
$workersToProvision = @()
foreach ($n in $StartWorker..$EndWorker) {
    $outFile = Join-Path $consoleAppDir "appsettings.worker$n.json"
    if ((Test-Path $outFile) -and -not $Force -and -not $WhatIf) {
        Write-Warn "Worker $n`: appsettings.worker$n.json already exists — skipping. Use -Force to overwrite."
    }
    else {
        $workersToProvision += $n
    }
}

if ($workersToProvision.Count -eq 0) {
    Write-Info "Nothing to do. All config files already exist. Use -Force to overwrite."
    exit 0
}

Write-Info "Will provision: workers $($workersToProvision -join ', ')"
Write-Host ""

# Functions Get-DeviceCodeToken, Invoke-Graph, Get-GraphSpId, New-WorkerApp,
# and New-WorkerAppSettingsContent (formerly New-AppSettingsContent) are now
# defined in _Common.ps1 — no local copies needed.

# ─── Authenticate (skip in WhatIf mode) ────────────────────────────────────────
if ($WhatIf) {
    Write-Warn "WhatIf: skipping authentication steps"
    $b2cHeaders    = @{ Authorization = "Bearer WhatIf-Token"; "Content-Type" = "application/json" }
    $eeidHeaders   = @{ Authorization = "Bearer WhatIf-Token"; "Content-Type" = "application/json" }
    $b2cGraphSpId  = "00000000-0000-0000-0000-000000000001"
    $eeidGraphSpId = "00000000-0000-0000-0000-000000000002"
}
else {
    $adminScopes = @(
        "https://graph.microsoft.com/Application.ReadWrite.All"
        "https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All"
        "https://graph.microsoft.com/User.Read"
    )

    # Authenticate to B2C tenant (skip if -SkipB2C)
    if ($SkipB2C) {
        Write-Info "Skipping B2C authentication (-SkipB2C)"
        $b2cHeaders   = $null
        $b2cGraphSpId = $null
    }
    else {
        $b2cToken    = Get-DeviceCodeToken `
            -TenantId    $b2cTenantId `
            -TenantLabel "B2C ($b2cTenantDomain)" `
            -Scopes      $adminScopes
        $b2cHeaders  = @{ Authorization = "Bearer $b2cToken";  "Content-Type" = "application/json" }
    }

    # Authenticate to External ID tenant (always needed for extension properties)
    $eeidToken   = Get-DeviceCodeToken `
        -TenantId    $eeidTenantId `
        -TenantLabel "External ID ($eeidTenantDomain)" `
        -Scopes      $adminScopes
    $eeidHeaders = @{ Authorization = "Bearer $eeidToken"; "Content-Type" = "application/json" }

    # Locate the Microsoft Graph SP in each tenant (needed for admin consent)
    Write-Host ""
    Write-Info "Locating Microsoft Graph service principal in each tenant..."
    if (-not $SkipB2C) {
        $b2cGraphSpId  = Get-GraphSpId -Headers $b2cHeaders  -TenantLabel "B2C"
        Write-Info "  B2C  Graph SP : $b2cGraphSpId"
    }
    if (-not $SkipEEID) {
        $eeidGraphSpId = Get-GraphSpId -Headers $eeidHeaders -TenantLabel "External ID"
        Write-Info "  EEID Graph SP : $eeidGraphSpId"
    }
}

# ─── Ensure extension properties on EEID ExtensionApp ──────────────────────────
if ($WhatIf) {
    Write-Host ""
    Write-Warn "[WhatIf] Would ensure extension properties (B2CObjectId, RequiresMigration) on ExtensionApp $extensionAppId"
}
else {
    Write-Host ""
    Ensure-ExtensionProperties -Headers $eeidHeaders -ExtensionAppId $extensionAppId
}

# ─── Provision workers ─────────────────────────────────────────────────────────
$results = @()

foreach ($n in $workersToProvision) {
    Write-Host ""
    Write-Host "───────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Worker $n" -ForegroundColor Cyan
    Write-Host "───────────────────────────────────────────────────────────────" -ForegroundColor Cyan

    if ($WhatIf) {
        Write-Warn "  [WhatIf] Would create 'B2C App Registration (Local - Worker $n)' in B2C"
        Write-Warn "  [WhatIf] Would create 'External ID App Registration $n (Local)' in External ID"
        Write-Warn "  [WhatIf] Would write appsettings.worker$n.json"
        $results += [pscustomobject]@{
            Worker      = $n
            B2cClientId = "WhatIf"
            EeidClientId= "WhatIf"
            File        = "appsettings.worker$n.json"
            Skipped     = $false
        }
        continue
    }

    try {
        # B2C app registration (User.Read.All)
        if ($SkipB2C) {
            Write-Info "  [B2C] Skipped – using provided credentials (ClientId: $($B2CClientId.Substring(0,8))…)"
            $b2cApp = @{ ClientId = $B2CClientId; ClientSecret = $B2CClientSecret }
        }
        else {
            $b2cApp = New-WorkerApp `
                -Headers          $b2cHeaders `
                -AppDisplayName   "B2C App Registration (Local - Worker $n)" `
                -PermissionRoleIds $PERM_USER_READ_ALL `
                -GraphSpId        $b2cGraphSpId `
                -TenantLabel      "B2C" `
                -WorkerNumber     $n
        }

        # External ID app registration (User.ReadWrite.All + UserAuthenticationMethod.ReadWrite.All)
        if ($SkipEEID) {
            Write-Info "  [EEID] Skipped – using provided credentials (ClientId: $($EEIDClientId.Substring(0,8))…)"
            $eeidApp = @{ ClientId = $EEIDClientId; ClientSecret = $EEIDClientSecret }
        }
        else {
            $eeidApp = New-WorkerApp `
                -Headers          $eeidHeaders `
                -AppDisplayName   "External ID App Registration $n (Local)" `
                -PermissionRoleIds @($PERM_USER_READWRITE, $PERM_USER_AUTH_RW) `
                -GraphSpId        $eeidGraphSpId `
                -TenantLabel      "External ID" `
                -WorkerNumber     $n
        }
    }
    catch {
        Write-Err "Failed to provision worker $n`: $_"
        Write-Warn "  Skipping worker $n. Other workers will still be attempted."
        $results += [pscustomobject]@{
            Worker      = $n
            B2cClientId = "ERROR"
            EeidClientId= "ERROR"
            File        = "appsettings.worker$n.json"
            Skipped     = $true
        }
        continue
    }

    # Write appsettings file
    $content = New-WorkerAppSettingsContent `
        -WorkerN           $n `
        -B2cTenantId       $b2cTenantId `
        -B2cTenantDomain   $b2cTenantDomain `
        -B2cClientId       $b2cApp.ClientId `
        -B2cClientSecret   $b2cApp.ClientSecret `
        -EeidTenantId      $eeidTenantId `
        -EeidTenantDomain  $eeidTenantDomain `
        -ExtAppId          $extensionAppId `
        -EeidClientId      $eeidApp.ClientId `
        -EeidClientSecret  $eeidApp.ClientSecret

    $outFile = Join-Path $consoleAppDir "appsettings.worker$n.json"
    Set-Content -Path $outFile -Value $content -Encoding UTF8 -NoNewline
    Write-Success "✓ Written: $(Split-Path $outFile -Leaf)"

    $results += [pscustomobject]@{
        Worker      = $n
        B2cClientId = $b2cApp.ClientId
        EeidClientId= $eeidApp.ClientId
        File        = "appsettings.worker$n.json"
        Skipped     = $false
    }
}

# ─── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$succeeded = $results | Where-Object { -not $_.Skipped }
$failed    = $results | Where-Object { $_.Skipped }

foreach ($r in $results) {
    if ($r.Skipped) {
        Write-Err "  Worker $($r.Worker): FAILED – check errors above"
    }
    elseif ($WhatIf) {
        Write-Warn "  Worker $($r.Worker): [WhatIf] $($r.File)"
    }
    else {
        $b2cShort  = $r.B2cClientId.Substring(0, [Math]::Min(8, $r.B2cClientId.Length))
        $eeidShort = $r.EeidClientId.Substring(0, [Math]::Min(8, $r.EeidClientId.Length))
        Write-Success "  Worker $($r.Worker): B2C=$b2cShort…  EEID=$eeidShort…  → $($r.File)"
    }
}

Write-Host ""

if ($succeeded.Count -gt 0 -and -not $WhatIf) {
    Write-Info "To run the new workers, open one terminal per worker:"
    Write-Host ""
    foreach ($r in $succeeded) {
        Write-Host ("  .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker{0}.json" -f $r.Worker) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Warn "⚠ Client secrets are embedded in the generated appsettings files."
    Write-Warn "  These files contain credentials — keep them out of source control."
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Err "⚠ $($failed.Count) worker(s) failed. Review errors above and re-run with -StartWorker/-EndWorker to retry specific workers."
    exit 1
}
