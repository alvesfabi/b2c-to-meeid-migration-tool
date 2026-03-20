#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy.sh — Deploy B2C-to-MEEID migration infrastructure and worker app
#
# Usage:
#   ./scripts/deploy.sh              # Deploy infrastructure + app
#   ./scripts/deploy.sh --teardown   # Delete the resource group
#
# Environment variables (all optional, sensible defaults provided):
#   LOCATION              Azure region           (default: eastus)
#   RESOURCE_GROUP        Resource group name     (default: rg-b2c-migration)
#   STORAGE_ACCOUNT_NAME  Storage account name    (prompted if not set)
#   VM_COUNT              Number of worker VMs    (default: 2)
#   VM_SIZE               VM SKU                  (default: Standard_B2s)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_KEY_PATH="$HOME/.ssh/b2c-migration-key"

# Defaults
LOCATION="${LOCATION:-eastus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-b2c-migration}"
VM_COUNT="${VM_COUNT:-2}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
ADMIN_USERNAME="azureuser"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------- Teardown mode ----------
if [[ "${1:-}" == "--teardown" ]]; then
    info "Tearing down resource group: $RESOURCE_GROUP"
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    info "Deletion initiated (--no-wait). Monitor with: az group show -n $RESOURCE_GROUP"
    exit 0
fi

# ---------- Prerequisites ----------
info "Checking prerequisites..."

command -v az >/dev/null 2>&1       || die "Azure CLI (az) not found. Install: https://aka.ms/install-azure-cli"
command -v dotnet >/dev/null 2>&1   || die "dotnet SDK not found. Install: https://dot.net/download"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found."

# Verify logged in
az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"
info "Logged in as: $(az account show --query user.name -o tsv)"

# ---------- Storage account name ----------
if [[ -z "${STORAGE_ACCOUNT_NAME:-}" ]]; then
    read -rp "Storage account name (globally unique, 3-24 lowercase alphanum): " STORAGE_ACCOUNT_NAME
    [[ -z "$STORAGE_ACCOUNT_NAME" ]] && die "Storage account name is required."
fi

# ---------- SSH key ----------
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    info "Generating SSH keypair at $SSH_KEY_PATH"
    ssh-keygen -t ed25519 -C "b2c-migration" -f "$SSH_KEY_PATH" -N ""
fi
SSH_PUB_KEY="$(cat "${SSH_KEY_PATH}.pub")"

# ---------- Deploy infrastructure ----------
info "Deploying infrastructure (location=$LOCATION, rg=$RESOURCE_GROUP, vms=$VM_COUNT, size=$VM_SIZE)..."

DEPLOYMENT_OUTPUT=$(az deployment sub create \
    --location "$LOCATION" \
    --template-file "$REPO_ROOT/infra/main.bicep" \
    --parameters \
        location="$LOCATION" \
        resourceGroupName="$RESOURCE_GROUP" \
        storageAccountName="$STORAGE_ACCOUNT_NAME" \
        vmCount="$VM_COUNT" \
        vmSize="$VM_SIZE" \
        adminUsername="$ADMIN_USERNAME" \
        adminSshPublicKey="$SSH_PUB_KEY" \
    --query 'properties.outputs' -o json)

BASTION_NAME=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['bastionName']['value'])")
STORAGE_NAME=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['storageAccountName']['value'])")
QUEUE_ENDPOINT=$(echo "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['storageQueueEndpoint']['value'])")

info "Infrastructure deployed successfully."
info "  Bastion: $BASTION_NAME"
info "  Storage: $STORAGE_NAME"
info "  Queue:   $QUEUE_ENDPOINT"

# ---------- Build .NET app ----------
APP_DIR="$REPO_ROOT/src"
PUBLISH_DIR="$REPO_ROOT/publish"

if [[ -d "$APP_DIR" ]]; then
    info "Building .NET console app..."
    dotnet publish "$APP_DIR" -c Release -o "$PUBLISH_DIR" --nologo -v quiet
    info "Published to $PUBLISH_DIR"
else
    warn "No src/ directory found — skipping dotnet build."
    PUBLISH_DIR=""
fi

# ---------- Deploy app to VMs via Bastion tunnel ----------
if [[ -n "$PUBLISH_DIR" && -d "$PUBLISH_DIR" ]]; then
    for i in $(seq 1 "$VM_COUNT"); do
        VM_NAME="vm-b2c-worker${i}"
        info "Deploying app to $VM_NAME..."

        VM_ID=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query id -o tsv)

        # Find a free local port
        LOCAL_PORT=$((2200 + i))

        # Open Bastion tunnel in background
        az network bastion tunnel \
            --name "$BASTION_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --target-resource-id "$VM_ID" \
            --resource-port 22 \
            --port "$LOCAL_PORT" &
        TUNNEL_PID=$!

        # Wait for tunnel to be ready
        sleep 10

        # SCP published app
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -P "$LOCAL_PORT" -i "$SSH_KEY_PATH" \
            -r "$PUBLISH_DIR"/* "${ADMIN_USERNAME}@127.0.0.1:/home/${ADMIN_USERNAME}/app/" 2>/dev/null || {
                warn "SCP to $VM_NAME failed — you may need to copy manually."
            }

        # Copy appsettings if exists
        if [[ -f "$REPO_ROOT/appsettings.json" ]]; then
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -P "$LOCAL_PORT" -i "$SSH_KEY_PATH" \
                "$REPO_ROOT/appsettings.json" "${ADMIN_USERNAME}@127.0.0.1:/home/${ADMIN_USERNAME}/app/" 2>/dev/null || true
        fi

        # Kill tunnel
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true

        info "  $VM_NAME done."
    done
fi

# ---------- Summary ----------
echo ""
echo "============================================================"
echo "  B2C Migration Infrastructure — Deployment Complete"
echo "============================================================"
echo ""
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  Location:        $LOCATION"
echo "  Storage Account: $STORAGE_NAME"
echo "  Queue Endpoint:  $QUEUE_ENDPOINT"
echo "  Bastion:         $BASTION_NAME"
echo "  Worker VMs:      $VM_COUNT"
echo ""
echo "  SSH to a worker via Bastion:"
echo "    az network bastion ssh \\"
echo "      --name $BASTION_NAME \\"
echo "      --resource-group $RESOURCE_GROUP \\"
echo "      --target-resource-id <VM_RESOURCE_ID> \\"
echo "      --auth-type ssh-key \\"
echo "      --username $ADMIN_USERNAME \\"
echo "      --ssh-key $SSH_KEY_PATH"
echo ""
echo "  List VM IDs:"
echo "    az vm list -g $RESOURCE_GROUP --query '[].{name:name, id:id}' -o table"
echo ""
echo "  Teardown:"
echo "    ./scripts/deploy.sh --teardown"
echo "============================================================"
