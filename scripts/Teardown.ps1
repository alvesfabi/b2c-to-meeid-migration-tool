<#
.SYNOPSIS
    Delete the B2C migration resource group.

.PARAMETER ResourceGroup
    Resource group name (default: rg-b2c-migration).

.PARAMETER Force
    Skip confirmation prompt.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-b2c-migration' }),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "Deleting resource group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "This will destroy ALL resources in the group."

if (-not $Force) {
    $confirm = Read-Host 'Are you sure? (y/N)'
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host 'Aborted.'
        exit 0
    }
}

az group delete --name $ResourceGroup --yes
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to delete resource group." -ForegroundColor Red
    exit 1
}

Write-Host "Resource group '$ResourceGroup' deleted." -ForegroundColor Green
