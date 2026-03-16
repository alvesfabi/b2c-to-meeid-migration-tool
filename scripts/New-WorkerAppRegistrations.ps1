# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Provisions app registrations in B2C and External ID for additional migration workers
    and writes the corresponding appsettings.workerN.json files.

.DESCRIPTION
    For each worker number in [StartWorker..EndWorker] this script:
      1. Creates a B2C app registration with User.Read.All (Application) and grants admin consent.
      2. Creates an External ID app registration with User.ReadWrite.All (Application) and grants
         admin consent.
      3. Generates a client secret for each registration.
      4. Writes appsettings.workerN.json to src/B2CMigrationKit.Console/.

    Authentication is performed via device code flow — you will be prompted to sign in as an admin
    once for the B2C tenant and once for the External ID tenant.

    Required admin role in each tenant: Application Administrator (or Global Administrator).

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

.PARAMETER WhatIf
    Print every action that would be taken without calling any Graph API or writing any file.

.EXAMPLE
    # Provision workers 5-8 (default)
    .\New-WorkerAppRegistrations.ps1

.EXAMPLE
    # Provision only worker 6
    .\New-WorkerAppRegistrations.ps1 -StartWorker 6 -EndWorker 6

.EXAMPLE
    # Overwrite existing files and re-create secrets
    .\New-WorkerAppRegistrations.ps1 -Force

.EXAMPLE
    # Preview everything without touching Azure
    .\New-WorkerAppRegistrations.ps1 -WhatIf
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
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Shared helpers (Write-Success / Write-Info / Write-Warn / Write-Err)
. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Well-known Graph resource IDs ─────────────────────────────────────────────
# Source: https://learn.microsoft.com/en-us/graph/permissions-reference

# Microsoft Graph resource app ID (same in every tenant)
$GRAPH_APP_ID          = "00000003-0000-0000-c000-000000000000"

# Application permission role IDs (stable Microsoft-assigned GUIDs)
$PERM_USER_READ_ALL    = "df021288-bdef-4463-88db-98f22de89214"  # User.Read.All (Application)
$PERM_USER_READWRITE   = "741f803b-c850-494e-b5df-cde7c675a1ca"  # User.ReadWrite.All (Application)

# Public client used for device code authentication (Microsoft Graph Command Line Tools)
$DEVICE_CODE_CLIENT    = "14d82eec-204b-4c2f-b7e8-296a70dab67e"

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
Write-Host "  B2C Migration Kit – Provision Worker App Registrations"       -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Info "Workers to provision : $StartWorker – $EndWorker ($($EndWorker - $StartWorker + 1) worker(s))"
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

# ─── Device code authentication helper ────────────────────────────────────────
function Get-DeviceCodeToken {
    param(
        [string]$TenantId,
        [string]$TenantLabel,
        [string[]]$Scopes
    )

    Write-Host ""
    Write-Host "──────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  Sign in as ADMIN in: $TenantLabel" -ForegroundColor Yellow
    Write-Host "  Required permission: Application.ReadWrite.All"             -ForegroundColor Yellow
    Write-Host "──────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host ""

    try {
        $dcResp = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
            -Body @{
                client_id = $DEVICE_CODE_CLIENT
                scope     = ($Scopes -join ' ')
            }
    }
    catch {
        Write-Err "Device code request for '$TenantLabel' failed: $_"
        throw
    }

    Write-Host $dcResp.message -ForegroundColor White
    Write-Host ""
    Write-Host "  Waiting for authentication..." -ForegroundColor Gray

    $deadline = [DateTime]::UtcNow.AddSeconds([int]$dcResp.expires_in)
    $interval = [int]$dcResp.interval

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $DEVICE_CODE_CLIENT
                    device_code = $dcResp.device_code
                }
            Write-Success "✓ Authenticated to $TenantLabel"
            return $tok.access_token
        }
        catch {
            $body = $null
            if ($_.ErrorDetails.Message) {
                $body = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            }
            switch ($body.error) {
                "authorization_pending" { continue }
                "authorization_declined" { throw "Authentication was declined." }
                "expired_token"          { throw "Device code expired — please re-run the script." }
                default                  { throw }
            }
        }
    }
    throw "Authentication timed out after $($dcResp.expires_in)s"
}

# ─── Graph REST helper ─────────────────────────────────────────────────────────
function Invoke-Graph {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body = $null
    )
    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = "application/json"
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $detail = ""
        if ($_.ErrorDetails.Message) {
            $ej = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($ej.error) { $detail = " – [$($ej.error.code)] $($ej.error.message)" }
        }
        throw "Graph $Method $Uri failed$detail"
    }
}

# Locate the Microsoft Graph service principal object ID in a tenant
function Get-GraphSpId {
    param([hashtable]$Headers, [string]$TenantLabel)
    $res = Invoke-Graph -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$GRAPH_APP_ID'&`$select=id" `
        -Headers $Headers
    if (-not $res.value -or $res.value.Count -eq 0) {
        throw "Microsoft Graph service principal not found in $TenantLabel. Cannot grant admin consent."
    }
    return $res.value[0].id
}

# Create an app registration + SP, grant admin consent, and add a client secret.
# Returns @{ AppObjectId; ClientId; ClientSecret }
function New-WorkerApp {
    param(
        [hashtable]$Headers,
        [string]$AppDisplayName,
        [string]$PermissionRoleId,
        [string]$GraphSpId,
        [string]$TenantLabel,
        [int]$WorkerNumber
    )

    Write-Info "  [$TenantLabel] Creating '$AppDisplayName'..."

    # 1. Create app registration with the desired permission declared
    $app = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications" `
        -Headers $Headers `
        -Body @{
            displayName            = $AppDisplayName
            signInAudience         = "AzureADMyOrg"
            requiredResourceAccess = @(
                @{
                    resourceAppId  = $GRAPH_APP_ID
                    resourceAccess = @(
                        @{ id = $PermissionRoleId; type = "Role" }
                    )
                }
            )
        }
    Write-Info "    App object ID : $($app.id)"
    Write-Info "    Client ID     : $($app.appId)"

    # 2. Create service principal (required for admin consent grant)
    Start-Sleep -Seconds 3   # wait for app creation to propagate
    $sp = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" `
        -Headers $Headers `
        -Body @{ appId = $app.appId }
    Write-Info "    Service principal: $($sp.id)"

    # 3. Grant admin consent via app role assignment
    Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" `
        -Headers $Headers `
        -Body @{
            principalId = $sp.id
            resourceId  = $GraphSpId
            appRoleId   = $PermissionRoleId
        } | Out-Null
    Write-Info "    Admin consent granted for role $PermissionRoleId"

    # 4. Create client secret
    $expiry     = [DateTime]::UtcNow.AddYears($SecretExpiryYears).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $secretResp = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/addPassword" `
        -Headers $Headers `
        -Body @{
            passwordCredential = @{
                displayName = "worker-$WorkerNumber-local-dev"
                endDateTime = $expiry
            }
        }
    Write-Success "    ✓ Done  (secret expires $expiry)"

    return @{
        AppObjectId  = $app.id
        ClientId     = $app.appId
        ClientSecret = $secretResp.secretText
    }
}

# Build the JSON content for appsettings.workerN.json
function New-AppSettingsContent {
    param(
        [int]   $WorkerN,
        [string]$B2cTenantId,
        [string]$B2cTenantDomain,
        [string]$B2cClientId,
        [string]$B2cClientSecret,
        [string]$EeidTenantId,
        [string]$EeidTenantDomain,
        [string]$ExtAppId,
        [string]$EeidClientId,
        [string]$EeidClientSecret
    )

    # Use a here-string so the output matches the format of existing worker configs exactly
    return @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  },
  "Migration": {
    "B2C": {
      "TenantId": "$B2cTenantId",
      "TenantDomain": "$B2cTenantDomain",
      "AppRegistration": {
        "ClientId": "$B2cClientId",
        "ClientSecret": "$B2cClientSecret",
        "Name": "B2C App Registration (Local - Worker $WorkerN)",
        "Enabled": true
      },
      "Scopes": [
        "https://graph.microsoft.com/.default"
      ]
    },
    "ExternalId": {
      "TenantId": "$EeidTenantId",
      "TenantDomain": "$EeidTenantDomain",
      "ExtensionAppId": "$ExtAppId",
      "AppRegistration": {
        "ClientId": "$EeidClientId",
        "ClientSecret": "$EeidClientSecret",
        "Name": "External ID App Registration $WorkerN (Local)",
        "Enabled": true
      },
      "Scopes": [
        "https://graph.microsoft.com/.default"
      ]
    },
    "Storage": {
      "ConnectionStringOrUri": "UseDevelopmentStorage=true",
      "AuditTableName": "migrationAudit",
      "AuditMode": "File",
      "AuditFilePath": "migration-audit-worker${WorkerN}.jsonl",
      "UseManagedIdentity": false
    },
    "Telemetry": {
      "ConnectionString": "",
      "Enabled": true,
      "UseApplicationInsights": false,
      "UseConsoleLogging": true,
      "SamplingPercentage": 100.0,
      "TrackDependencies": true,
      "TrackExceptions": true,
      "LogFilePath": "worker${WorkerN}-telemetry.jsonl"
    },
    "Retry": {
      "MaxRetries": 5,
      "InitialDelayMs": 1000,
      "MaxDelayMs": 30000,
      "BackoffMultiplier": 2.0,
      "UseRetryAfterHeader": true,
      "OperationTimeoutSeconds": 120
    },
    "Export": {
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities",
      "WorkerBlobPrefix": "w${WorkerN}_"
    },
    "Import": {
      "AttributeMappings": {},
      "ExcludeFields": [
        "createdDateTime",
        "lastPasswordChangeDateTime"
      ],
      "MigrationAttributes": {
        "StoreB2CObjectId": true,
        "SetRequireMigration": true,
        "OverwriteExtensionAttributes": false
      },
      "SkipPhoneRegistration": false
    },
    "BatchSize": 100,
    "PageSize": 100,
    "VerboseLogging": true,
    "BatchDelayMs": 0,
    "MaxConcurrency": 8
  }
}
"@
}

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
        "https://graph.microsoft.com/User.Read"
    )

    # Authenticate to B2C tenant first
    $b2cToken  = Get-DeviceCodeToken `
        -TenantId    $b2cTenantId `
        -TenantLabel "B2C ($b2cTenantDomain)" `
        -Scopes      $adminScopes

    # Authenticate to External ID tenant
    $eeidToken = Get-DeviceCodeToken `
        -TenantId    $eeidTenantId `
        -TenantLabel "External ID ($eeidTenantDomain)" `
        -Scopes      $adminScopes

    $b2cHeaders  = @{ Authorization = "Bearer $b2cToken";  "Content-Type" = "application/json" }
    $eeidHeaders = @{ Authorization = "Bearer $eeidToken"; "Content-Type" = "application/json" }

    # Locate the Microsoft Graph SP in each tenant (needed for admin consent)
    Write-Host ""
    Write-Info "Locating Microsoft Graph service principal in each tenant..."
    $b2cGraphSpId  = Get-GraphSpId -Headers $b2cHeaders  -TenantLabel "B2C"
    $eeidGraphSpId = Get-GraphSpId -Headers $eeidHeaders -TenantLabel "External ID"
    Write-Info "  B2C  Graph SP : $b2cGraphSpId"
    Write-Info "  EEID Graph SP : $eeidGraphSpId"
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
        $b2cApp = New-WorkerApp `
            -Headers          $b2cHeaders `
            -AppDisplayName   "B2C App Registration (Local - Worker $n)" `
            -PermissionRoleId $PERM_USER_READ_ALL `
            -GraphSpId        $b2cGraphSpId `
            -TenantLabel      "B2C" `
            -WorkerNumber     $n

        # External ID app registration (User.ReadWrite.All)
        $eeidApp = New-WorkerApp `
            -Headers          $eeidHeaders `
            -AppDisplayName   "External ID App Registration $n (Local)" `
            -PermissionRoleId $PERM_USER_READWRITE `
            -GraphSpId        $eeidGraphSpId `
            -TenantLabel      "External ID" `
            -WorkerNumber     $n
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
    $content = New-AppSettingsContent `
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
