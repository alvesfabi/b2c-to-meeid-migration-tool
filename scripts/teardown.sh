#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown.sh — Delete the B2C migration resource group
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-b2c-migration}"

echo "Deleting resource group: $RESOURCE_GROUP"
echo "This will destroy ALL resources in the group."
read -rp "Are you sure? (y/N): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

az group delete --name "$RESOURCE_GROUP" --yes
echo "Resource group '$RESOURCE_GROUP' deleted."
