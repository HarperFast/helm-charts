#!/usr/bin/env bash
# Create a local multi-node k3d (k3s-in-Docker) cluster for testing the Harper
# chart. Mirrors a k3s prod environment: Traefik ingress + local-path storage.
#
# Usage: ./scripts/local-k3d-up.sh [cluster-name] [agent-count]
set -euo pipefail

CLUSTER="${1:-harper-dev}"
AGENTS="${2:-3}"

for bin in docker kubectl helm k3d; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found. See docs/LOCAL_TESTING.md"; exit 1; }
done

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER}\b"; then
  echo "Cluster '${CLUSTER}' already exists. Delete it with: k3d cluster delete ${CLUSTER}"
else
  echo ">> Creating k3d cluster '${CLUSTER}' (1 server + ${AGENTS} agents)..."
  k3d cluster create "${CLUSTER}" \
    --servers 1 \
    --agents "${AGENTS}" \
    --port "9925:9925@loadbalancer" \
    --port "9926:9926@loadbalancer" \
    --wait
fi

echo
echo ">> Nodes:"
kubectl get nodes
echo
echo ">> Default StorageClass:"
kubectl get storageclass
echo
cat <<EOF
Cluster ready. Deploy a single Harper node:

  helm install harper ./charts/harper -n harper --create-namespace \\
    --set replicaCount=1 \\
    --set persistence.storageClassName=local-path \\
    --set persistence.size=5Gi

Then follow docs/LOCAL_TESTING.md (scale to 3, run docs/TESTING.md checks).
Tear down with: ./scripts/local-k3d-down.sh ${CLUSTER}
EOF
