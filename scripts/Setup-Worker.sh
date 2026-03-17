#!/bin/bash
# Setup script to run ON the VM via Bastion SSH if az vm run-command is blocked.
# Usage: curl -sL <raw-url> | bash -s -- <storage-account> <keyvault-name> <config-secret-name>
#
# Example:
#   bash Setup-Worker.sh stb2cmig123 kv-b2c-mig-abc123 appsettings-worker1

set -euo pipefail

STORAGE_ACCOUNT="${1:?Usage: $0 <storage-account> <keyvault-name> <config-secret-name>}"
KV_NAME="${2:?Missing keyvault name}"
SECRET_NAME="${3:?Missing config secret name}"
DEPLOY_DIR="/opt/b2c-migration/app"

echo "=== Authenticating with Managed Identity ==="
az login --identity --allow-no-subscriptions

echo "=== Downloading app artifact ==="
sudo mkdir -p "$DEPLOY_DIR"
sudo chown "$(whoami)" "$DEPLOY_DIR"

az storage blob download \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "app-deploy" \
    --name "b2c-migration-app.tar.gz" \
    --file /tmp/b2c-migration-app.tar.gz \
    --auth-mode login

echo "=== Extracting ==="
tar xzf /tmp/b2c-migration-app.tar.gz -C "$DEPLOY_DIR"
chmod +x "$DEPLOY_DIR/B2CMigrationKit.Console"

echo "=== Downloading config from Key Vault ==="
az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$SECRET_NAME" \
    --query "value" -o tsv > "$DEPLOY_DIR/appsettings.json"

echo ""
echo "=== Setup complete ==="
echo "Run migration:"
echo "  cd $DEPLOY_DIR"
echo "  ./B2CMigrationKit.Console harvest --config appsettings.json"
echo "  ./B2CMigrationKit.Console worker-migrate --config appsettings.json"
echo "  ./B2CMigrationKit.Console phone-registration --config appsettings.json"
