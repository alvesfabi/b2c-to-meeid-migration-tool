#!/bin/bash
# Interactive script to generate appsettings.json on a worker VM.
# Run this AFTER Setup-Worker.sh has cloned and built the app.
#
# Usage:
#   bash Configure-Worker.sh                     # interactive
#   bash Configure-Worker.sh --role worker        # skip role prompt
#   bash Configure-Worker.sh --role master
#
# The script asks for credentials one by one and writes the config
# to the console app directory. Much easier than editing with nano.

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/b2c-migration/app}"
CONFIG_FILE="$APP_DIR/appsettings.json"

# ───────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────

color_green='\033[0;32m'
color_yellow='\033[1;33m'
color_cyan='\033[0;36m'
color_reset='\033[0m'

prompt() {
    local varname="$1"
    local label="$2"
    local default="${3:-}"
    local value

    if [ -n "$default" ]; then
        printf "${color_cyan}  %s${color_reset} [${color_yellow}%s${color_reset}]: " "$label" "$default"
    else
        printf "${color_cyan}  %s${color_reset}: " "$label"
    fi
    read -r value
    value="${value:-$default}"

    if [ -z "$value" ]; then
        echo "    ⚠  Value required. Aborting." >&2
        exit 1
    fi

    printf -v "$varname" '%s' "$value"
}

prompt_secret() {
    local varname="$1"
    local label="$2"
    local value

    printf "${color_cyan}  %s${color_reset} (paste + Enter, input hidden): " "$label"
    # Use stty instead of read -s for better paste compatibility (Bastion SSH)
    stty -echo 2>/dev/null
    read -r value
    stty echo 2>/dev/null
    local len=${#value}
    echo ""
    echo -e "    → received ${len} characters"

    if [ -z "$value" ]; then
        echo "    ⚠  Value required. Aborting." >&2
        exit 1
    fi

    printf -v "$varname" '%s' "$value"
}

prompt_optional() {
    local varname="$1"
    local label="$2"
    local default="${3:-}"
    local value

    if [ -n "$default" ]; then
        printf "${color_cyan}  %s${color_reset} [${color_yellow}%s${color_reset}]: " "$label" "$default"
    else
        printf "${color_cyan}  %s${color_reset} (optional, press Enter to skip): " "$label"
    fi
    read -r value
    value="${value:-$default}"

    printf -v "$varname" '%s' "$value"
}

# ───────────────────────────────────────────
# Parse args
# ───────────────────────────────────────────
ROLE=""
WORKER_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --worker-id) WORKER_ID="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ───────────────────────────────────────────
# Banner
# ───────────────────────────────────────────
echo ""
echo -e "${color_green}╔══════════════════════════════════════════════╗${color_reset}"
echo -e "${color_green}║   B2C Migration Kit — Worker Configuration  ║${color_reset}"
echo -e "${color_green}╚══════════════════════════════════════════════╝${color_reset}"
echo ""

# ───────────────────────────────────────────
# Role selection
# ───────────────────────────────────────────
if [ -z "$ROLE" ]; then
    echo "Select the role for this VM:"
    echo "  1) master   — runs 'harvest' only (enqueues user IDs)"
    echo "  2) worker   — runs 'worker-migrate' + 'phone-registration'"
    echo ""
    printf "  Enter 1 or 2: "
    read -r role_choice
    case "$role_choice" in
        1|master)  ROLE="master" ;;
        2|worker)  ROLE="worker" ;;
        *)         echo "Invalid choice"; exit 1 ;;
    esac
fi

if [ "$ROLE" = "worker" ] && [ -z "$WORKER_ID" ]; then
    prompt WORKER_ID "Worker ID (e.g. 1, 2, 3)" "1"
fi

echo ""
echo -e "${color_green}=== Role: $ROLE ===${color_reset}"
echo ""

# ───────────────────────────────────────────
# B2C Tenant
# ───────────────────────────────────────────
echo -e "${color_green}── Azure AD B2C ──${color_reset}"
prompt B2C_TENANT_ID       "B2C Tenant ID (GUID)"
prompt B2C_TENANT_DOMAIN   "B2C Tenant Domain (e.g. contoso.onmicrosoft.com)"
prompt B2C_CLIENT_ID       "B2C App Registration Client ID"
prompt_secret B2C_CLIENT_SECRET  "B2C App Registration Client Secret"
echo ""

# ───────────────────────────────────────────
# External ID Tenant
# ───────────────────────────────────────────
echo -e "${color_green}── Entra External ID ──${color_reset}"
prompt EEID_TENANT_ID       "External ID Tenant ID (GUID)"
prompt EEID_TENANT_DOMAIN   "External ID Tenant Domain (e.g. contoso.onmicrosoft.com)"
prompt EEID_CLIENT_ID       "External ID App Registration Client ID"
prompt_secret EEID_CLIENT_SECRET  "External ID App Registration Client Secret"
prompt EEID_EXTENSION_APP_ID "Extension App ID (no hyphens)"
echo ""

# ───────────────────────────────────────────
# Storage
# ───────────────────────────────────────────
echo -e "${color_green}── Azure Storage ──${color_reset}"
echo "  Using Managed Identity (DefaultAzureCredential)."
prompt STORAGE_ACCOUNT "Storage Account Name (just the name, not the full URL)"
STORAGE_URI="https://${STORAGE_ACCOUNT}.blob.core.windows.net"
echo -e "  → Connection URI: ${color_yellow}${STORAGE_URI}${color_reset}"

prompt_optional AUDIT_MODE "Audit Mode (Table / File / None)" "File"
echo ""

# ───────────────────────────────────────────
# Telemetry
# ───────────────────────────────────────────
echo -e "${color_green}── Telemetry ──${color_reset}"
if [ "$ROLE" = "worker" ]; then
    TELEMETRY_LOG="worker${WORKER_ID}-telemetry.jsonl"
else
    TELEMETRY_LOG="master-telemetry.jsonl"
fi
prompt_optional TELEMETRY_LOG_FILE "Telemetry log file" "$TELEMETRY_LOG"
echo ""

# ───────────────────────────────────────────
# Generate JSON
# ───────────────────────────────────────────
echo -e "${color_green}── Generating config ──${color_reset}"

# Escape any special JSON characters in secrets
escape_json() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

B2C_SECRET_ESC=$(escape_json "$B2C_CLIENT_SECRET")
EEID_SECRET_ESC=$(escape_json "$EEID_CLIENT_SECRET")

cat > "$CONFIG_FILE" <<JSONEOF
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  },
  "Migration": {
    "B2C": {
      "TenantId": "$B2C_TENANT_ID",
      "TenantDomain": "$B2C_TENANT_DOMAIN",
      "AppRegistration": {
        "ClientId": "$B2C_CLIENT_ID",
        "ClientSecret": $B2C_SECRET_ESC,
        "Name": "B2C App Registration",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "ExternalId": {
      "TenantId": "$EEID_TENANT_ID",
      "TenantDomain": "$EEID_TENANT_DOMAIN",
      "ExtensionAppId": "$EEID_EXTENSION_APP_ID",
      "AppRegistration": {
        "ClientId": "$EEID_CLIENT_ID",
        "ClientSecret": $EEID_SECRET_ESC,
        "Name": "External ID App Registration",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "Storage": {
      "ConnectionStringOrUri": "$STORAGE_URI",
      "ExportContainerName": "user-exports",
      "ErrorContainerName": "migration-errors",
      "ImportAuditContainerName": "import-audit",
      "ExportBlobPrefix": "users_",
      "AuditTableName": "migrationAudit",
      "AuditMode": "$AUDIT_MODE",
      "UseManagedIdentity": true
    },
    "Telemetry": {
      "ConnectionString": "",
      "Enabled": true,
      "UseApplicationInsights": false,
      "UseConsoleLogging": true,
      "SamplingPercentage": 100.0,
      "TrackDependencies": true,
      "TrackExceptions": true,
      "LogFilePath": "$TELEMETRY_LOG_FILE"
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
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities"
    },
    "Harvest": {
      "QueueName": "user-ids-to-process",
      "IdsPerMessage": 20,
      "PageSize": 999,
      "MessageVisibilityTimeout": "00:05:00",
      "MaxUsers": 0
    },
    "Import": {
      "AttributeMappings": {},
      "ExcludeFields": ["createdDateTime", "lastPasswordChangeDateTime"],
      "MigrationAttributes": {
        "StoreB2CObjectId": true,
        "SetRequireMigration": true,
        "OverwriteExtensionAttributes": false
      },
      "SkipPhoneRegistration": false
    },
    "PhoneRegistration": {
      "QueueName": "phone-registration",
      "ThrottleDelayMs": 400,
      "MessageVisibilityTimeoutSeconds": 120,
      "EmptyQueuePollDelayMs": 5000,
      "MaxEmptyPolls": 3,
      "UseFakePhoneWhenMissing": false
    },
    "BatchDelayMs": 0,
    "MaxConcurrency": 8
  }
}
JSONEOF

chmod 600 "$CONFIG_FILE"

echo ""
echo -e "${color_green}✓ Config written to: ${CONFIG_FILE}${color_reset}"
echo -e "  File permissions set to 600 (owner-only read/write)."
echo ""

# ───────────────────────────────────────────
# Validate
# ───────────────────────────────────────────
echo -e "${color_green}── Running validate ──${color_reset}"
echo ""
cd "$APP_DIR"
if ./B2CMigrationKit.Console validate --config appsettings.json; then
    echo ""
    echo -e "${color_green}✓ All checks passed!${color_reset}"
else
    echo ""
    echo -e "${color_yellow}⚠ Some checks failed. Review the output above and fix your config.${color_reset}"
    echo "  To edit:   nano $CONFIG_FILE"
    echo "  To re-run: ./B2CMigrationKit.Console validate --config appsettings.json"
fi

echo ""
echo -e "${color_green}── Next steps ──${color_reset}"
if [ "$ROLE" = "master" ]; then
    echo "  cd $APP_DIR"
    echo "  ./B2CMigrationKit.Console harvest --config appsettings.json"
else
    echo "  cd $APP_DIR"
    echo "  ./B2CMigrationKit.Console worker-migrate --config appsettings.json"
    echo "  ./B2CMigrationKit.Console phone-registration --config appsettings.json"
fi
echo ""
