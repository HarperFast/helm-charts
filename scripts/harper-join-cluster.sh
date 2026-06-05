#!/usr/bin/env bash
# Form the Harper replication mesh using the documented `add_node` flow.
#
# Each pod boots advertising its own replication identity but with no routes.
# This script connects them by calling add_node from harper-0 for every other
# pod, with verify_tls:false so Harper establishes trust between the self-signed
# nodes (the documented approach for fresh self-signed installs). add_node
# without subscriptions creates a fully-replicating relationship.
#
# Usage:
#   ./scripts/harper-join-cluster.sh [replicas]
#       replicas  default 3
#
# Env overrides: HARPER_NS (default harper), HARPER_RELEASE (default harper),
#                CLUSTER_DOMAIN (default cluster.local).
#
# Run AFTER the StatefulSet is fully ready:
#   kubectl -n harper rollout status sts/harper
set -euo pipefail

NS="${HARPER_NS:-harper}"
REL="${HARPER_RELEASE:-harper}"
REPLICAS="${1:-3}"
DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
HEADLESS="${REL}-headless"
HERE="$(cd "$(dirname "$0")" && pwd)"

U="$(kubectl -n "$NS" get secret "${REL}-admin" -o jsonpath='{.data.username}' | base64 -d)"
P="$(kubectl -n "$NS" get secret "${REL}-admin" -o jsonpath='{.data.password}' | base64 -d)"

echo ">> Forming mesh from ${REL}-0 across ${REPLICAS} nodes..."
i=1
while [ "$i" -lt "$REPLICAS" ]; do
  HOST="${REL}-${i}.${HEADLESS}.${NS}.svc.${DOMAIN}"
  echo ">> add_node ${HOST}"
  "${HERE}/harper-op.sh" 0 "{\"operation\":\"add_node\",\"hostname\":\"${HOST}\",\"verify_tls\":false,\"authorization\":{\"username\":\"${U}\",\"password\":\"${P}\"}}"
  i=$((i + 1))
done

echo
echo ">> cluster_status from ${REL}-0:"
"${HERE}/harper-op.sh" 0 '{"operation":"cluster_status"}'
