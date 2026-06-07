#!/usr/bin/env bash
# Generate a SHARED CA + a server cert covering every Harper pod's DNS name,
# and store it as a Kubernetes TLS secret. All nodes then trust the same CA, so
# the replication mesh (wss:// on 9933) connects instead of failing with
# "certificate signature failure".
#
# Usage:
#   ./scripts/gen-replication-certs.sh [replicas] [secret-name]
#     replicas     default 3
#     secret-name  default "<release>-tls"
#
# Env overrides: HARPER_NS (default harper), HARPER_RELEASE (default harper).
#
# After running, install/upgrade with:
#   helm upgrade harper ./charts/harper -n harper --reuse-values \
#     --set tls.enabled=true --set tls.existingSecret=<secret-name>
#   kubectl -n harper delete pod -l app.kubernetes.io/name=harper   # reload certs
set -euo pipefail

NS="${HARPER_NS:-harper}"
REL="${HARPER_RELEASE:-harper}"
REPLICAS="${1:-3}"
SECRET="${2:-${REL}-tls}"
DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
HEADLESS="${REL}-headless"

command -v openssl >/dev/null || { echo "openssl is required"; exit 1; }

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

echo ">> Generating shared CA..."
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout "$DIR/ca.key" -out "$DIR/ca.crt" \
  -subj "/CN=harper-cluster-ca/O=Harper" >/dev/null 2>&1

# Build the SAN list: localhost + client service + headless + every pod.
SAN="subjectAltName=DNS:localhost,IP:127.0.0.1"
SAN="${SAN},DNS:${REL}.${NS}.svc.${DOMAIN}"
SAN="${SAN},DNS:${HEADLESS}.${NS}.svc.${DOMAIN}"
i=0
while [ "$i" -lt "$REPLICAS" ]; do
  SAN="${SAN},DNS:${REL}-${i}.${HEADLESS}.${NS}.svc.${DOMAIN}"
  i=$((i + 1))
done
echo ">> SANs: ${SAN#subjectAltName=}"

echo ">> Generating server key + cert signed by the CA..."
openssl req -newkey rsa:4096 -nodes \
  -keyout "$DIR/tls.key" -out "$DIR/tls.csr" \
  -subj "/CN=${REL}.${NS}.svc.${DOMAIN}/O=Harper" >/dev/null 2>&1
openssl x509 -req -in "$DIR/tls.csr" \
  -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -days 3650 -out "$DIR/tls.crt" \
  -extfile <(printf "%s" "$SAN") >/dev/null 2>&1

echo ">> Creating secret '${SECRET}' in namespace '${NS}'..."
kubectl -n "$NS" create secret generic "$SECRET" \
  --from-file=tls.crt="$DIR/tls.crt" \
  --from-file=tls.key="$DIR/tls.key" \
  --from-file=ca.crt="$DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF

Done. Now enable TLS and reload the pods:

  helm upgrade ${REL} ./charts/harper -n ${NS} --reuse-values \\
    --set tls.enabled=true --set tls.existingSecret=${SECRET}
  kubectl -n ${NS} delete pod -l app.kubernetes.io/name=harper

Then re-check replication:
  ./scripts/harper-op.sh 0 '{"operation":"cluster_status"}'
EOF
