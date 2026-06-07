#!/usr/bin/env bash
# Run a Harper Operations API call against a specific instance or the
# load-balanced service.
#
# Usage:
#   ./scripts/harper-op.sh <target> '<json-operation>'
#     <target>  = a pod ordinal (0, 1, 2, ...) to hit that exact instance,
#                 or "svc" to hit the load-balanced client Service.
#
# Examples:
#   ./scripts/harper-op.sh 0 '{"operation":"describe_all"}'
#   ./scripts/harper-op.sh 1 '{"operation":"sql","sql":"SELECT * FROM dev.dog"}'
#   ./scripts/harper-op.sh svc '{"operation":"cluster_status"}'
#
# Env overrides: HARPER_NS (default "harper"), HARPER_RELEASE (default "harper").
set -euo pipefail

NS="${HARPER_NS:-harper}"
REL="${HARPER_RELEASE:-harper}"
TARGET="${1:?usage: harper-op.sh <ordinal|svc> '<json>'}"
JSON="${2:?provide an operation JSON payload}"

if [ "$TARGET" = "svc" ]; then
  OBJ="svc/${REL}"
else
  OBJ="pod/${REL}-${TARGET}"
fi

USER="$(kubectl -n "$NS" get secret "${REL}-admin" -o jsonpath='{.data.username}' | base64 -d)"
PASS="$(kubectl -n "$NS" get secret "${REL}-admin" -o jsonpath='{.data.password}' | base64 -d)"

PORT=$(( 20000 + RANDOM % 10000 ))
kubectl -n "$NS" port-forward "$OBJ" "${PORT}:9925" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT

# wait for the forward to be ready
for _ in $(seq 1 40); do
  (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null && { exec 3>&- 3<&-; break; }
  sleep 0.25
done

curl -s -u "${USER}:${PASS}" -X POST "http://127.0.0.1:${PORT}" \
  -H 'Content-Type: application/json' -d "$JSON"
echo
