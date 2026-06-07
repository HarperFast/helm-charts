#!/usr/bin/env bash
# Tear down the local k3d cluster created by local-k3d-up.sh.
# Usage: ./scripts/local-k3d-down.sh [cluster-name]
set -euo pipefail

CLUSTER="${1:-harper-dev}"

helm uninstall harper -n harper 2>/dev/null || true
echo ">> Deleting k3d cluster '${CLUSTER}'..."
k3d cluster delete "${CLUSTER}"
echo "Done."
