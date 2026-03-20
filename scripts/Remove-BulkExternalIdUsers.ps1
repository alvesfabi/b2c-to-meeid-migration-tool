<#
.SYNOPSIS
    Deletes migrated test users from Entra External ID tenant.

.DESCRIPTION
    Queries users with the RequiresMigration extension attribute and deletes them.
    Uses Graph API directly from the local machine (client credentials flow).
    Safety: requires -Force or interactive confirmation before deleting.

.PARAMETER ConfigFile
    Path to appsettings JSON file. Default: appsettings.worker1.json

.PARAMETER Filter
    OData filter override. Default: users with RequiresMigration attribute set to true.
    Use "all" to match users where the attribute is true OR false.

.PARAMETER MaxUsers
    Maximum number of users to process. Default: 1000

.PARAMETER WhatIf
    Preview deletions without executing them.

.PARAMETER Force
    Skip interactive confirmation prompt.

.EXAMPLE
    .\scripts\Remove-BulkExternalIdUsers.ps1 -WhatIf
    .\scripts\Remove-BulkExternalIdUsers.ps1 -Force
    .\scripts\Remove-BulkExternalIdUsers.ps1 -Filter "all" -Force
#>
param(
    [string]$ConfigFile = "appsettings.worker1.json",
    [string]$Filter     = "true",
    [int]   $MaxUsers   = 1000,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Resolve config ──────────────────────────────────────────────────────────
$rootDir       = Split-Path -Parent $PSScriptRoot
$consoleAppDir = Join-Path $rootDir "src\B2CMigrationKit.Console"
$configPath    = $ConfigFile

if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $configPath = Join-Path $consoleAppDir $ConfigFile
}

if (-not (Test-Path $configPath)) {
    Write-Err "Configuration file not found: $configPath"
    exit 1
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Bulk Delete External ID Users"    -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── Load config & derive attribute name ──────────────────────────────────────
$cfg            = Get-Content $configPath -Raw | ConvertFrom-Json
$tenantId       = $cfg.Migration.ExternalId.TenantId
$clientId       = $cfg.Migration.ExternalId.AppRegistration.ClientId
$clientSecret   = $cfg.Migration.ExternalId.AppRegistration.ClientSecret
$extensionAppId = $cfg.Migration.ExternalId.ExtensionAppId

$cleanAppId = $extensionAppId -replace "-", ""
$migAttr    = $cfg.Migration.Import.MigrationAttributes.RequireMigrationTarget
if ([string]::IsNullOrWhiteSpace($migAttr)) {
    $migAttr = "extension_${cleanAppId}_RequiresMigration"
}

Write-Info "Tenant          : $tenantId"
Write-Info "Migration attr  : $migAttr"
Write-Info "Filter          : $Filter"
if ($WhatIf) { Write-Warn "[WhatIf mode — no users will be deleted]" }
Write-Host ""

# ─── Acquire token ────────────────────────────────────────────────────────────
Write-Info "Acquiring access token..."
$tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -Body @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = "https://graph.microsoft.com/.default"
    } -ContentType "application/x-www-form-urlencoded"

$accessToken = $tokenResponse.access_token
$headers = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }
Write-Success "✓ Access token acquired"

# ─── Build OData filter ──────────────────────────────────────────────────────
$graphBase = "https://graph.microsoft.com/v1.0"
$odataFilter = switch ($Filter) {
    "true"  { "$migAttr eq true" }
    "false" { "$migAttr eq false" }
    "all"   { "$migAttr eq true or $migAttr eq false" }
    default { $Filter }  # allow custom OData filter passthrough
}

# ─── Query users ──────────────────────────────────────────────────────────────
Write-Info "Querying users..."
$users = [System.Collections.Generic.List[object]]::new()
$uri   = "$graphBase/users?`$filter=$([uri]::EscapeDataString($odataFilter))&`$select=id,userPrincipalName,displayName,$migAttr&`$top=100"

do {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    foreach ($u in $response.value) {
        $users.Add($u)
        if ($users.Count -ge $MaxUsers) { break }
    }
    $uri = $response.'@odata.nextLink'
} while ($uri -and $users.Count -lt $MaxUsers)

if ($users.Count -eq 0) {
    Write-Warn "No users found matching the filter."
    exit 0
}

Write-Success "Found $($users.Count) user(s) to delete."
Write-Host ""

# ─── Confirm ──────────────────────────────────────────────────────────────────
if (-not $WhatIf -and -not $Force) {
    Write-Warn "⚠  This will permanently delete $($users.Count) user(s) from External ID."
    $confirm = Read-Host "Type 'DELETE' to confirm"
    if ($confirm -ne 'DELETE') {
        Write-Info "Aborted."
        exit 0
    }
}

# ─── Delete users ─────────────────────────────────────────────────────────────
$successCount = 0
$failCount    = 0
$total        = $users.Count

foreach ($u in $users) {
    if ($WhatIf) {
        Write-Warn "  [WhatIf] Would delete: $($u.id)  ($($u.userPrincipalName))"
        continue
    }

    try {
        Invoke-RestMethod -Method Delete -Uri "$graphBase/users/$($u.id)" -Headers $headers | Out-Null
        $successCount++
        $pct = [Math]::Round($successCount * 100 / $total)
        Write-Success "  ✓ [$successCount/$total ${pct}%] $($u.userPrincipalName)"
    }
    catch {
        $failCount++
        Write-Err "  ✗ $($u.id) ($($u.userPrincipalName)) — $_"
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
if ($WhatIf) {
    Write-Warn "═══════════════════════════════════════════════════════"
    Write-Warn "  [WhatIf] No users deleted. Found: $total"
    Write-Warn "  Remove -WhatIf and add -Force to delete."
    Write-Warn "═══════════════════════════════════════════════════════"
}
elseif ($failCount -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Deleted: $successCount   Failed: $failCount"
    Write-Success "═══════════════════════════════════════════════════════"
}
else {
    Write-Warn "═══════════════════════════════════════════════════════"
    Write-Warn "  Deleted: $successCount   Failed: $failCount"
    Write-Warn "  Review errors above."
    Write-Warn "═══════════════════════════════════════════════════════"
}
Write-Host ""
