# Testing & Verification

How to prove each capability works. Assumes a deployed release named `harper` in
namespace `harper`. Set credentials first:

```bash
export NS=harper
export USER=$(kubectl -n $NS get secret harper-admin -o jsonpath='{.data.username}' | base64 -d)
export PASS=$(kubectl -n $NS get secret harper-admin -o jsonpath='{.data.password}' | base64 -d)
kubectl -n $NS port-forward svc/harper 9925:9925 &
OPS=http://localhost:9925
```

## 1. Chart renders correctly (no cluster needed)

```bash
helm lint ./charts/harper
helm template harper ./charts/harper -f ./charts/harper/values-k3s-longhorn.yaml \
  | kubectl apply --dry-run=client -f -      # server-side: --dry-run=server
```

## 2. Operations API is up

```bash
curl -s -u "$USER:$PASS" -X POST $OPS \
  -H 'Content-Type: application/json' \
  -d '{"operation":"describe_all"}' | jq
```

A JSON response (or a 401 before you add `-u`) proves the API is routing.
`helm test harper -n $NS` runs the bundled smoke test.

> For a full guide to running database operations, SQL, users, and per-instance
> commands, see **[INTERACTING.md](INTERACTING.md)** and the `scripts/harper-op.sh`
> helper (`./scripts/harper-op.sh 1 '{"operation":"describe_all"}'`).

## 3. Persistence survives pod restarts

```bash
# write data
curl -s -u "$USER:$PASS" -X POST $OPS -H 'Content-Type: application/json' -d '{
  "operation":"create_database","database":"verify"}'
curl -s -u "$USER:$PASS" -X POST $OPS -H 'Content-Type: application/json' -d '{
  "operation":"create_table","database":"verify","table":"t","primary_key":"id"}'
curl -s -u "$USER:$PASS" -X POST $OPS -H 'Content-Type: application/json' -d '{
  "operation":"insert","database":"verify","table":"t","records":[{"id":1,"v":"hello"}]}'

# delete the pod, wait for reschedule, read back
kubectl -n $NS delete pod harper-0
kubectl -n $NS rollout status sts/harper
curl -s -u "$USER:$PASS" -X POST $OPS -H 'Content-Type: application/json' -d '{
  "operation":"sql","sql":"SELECT * FROM verify.t"}' | jq
```

The record should still be present (data survives on the PVC regardless of
storage class).

## 4. Replication mesh (the key multi-node check)

Port-forward two *specific* pods and confirm a write on one is visible on the
other:

```bash
kubectl -n $NS port-forward pod/harper-0 19250:9925 &
kubectl -n $NS port-forward pod/harper-1 19251:9925 &

# write on node 0
curl -s -u "$USER:$PASS" -X POST http://localhost:19250 -H 'Content-Type: application/json' -d '{
  "operation":"insert","database":"verify","table":"t","records":[{"id":2,"v":"from-node-0"}]}'

# read on node 1 (allow a moment for async replication)
sleep 2
curl -s -u "$USER:$PASS" -X POST http://localhost:19251 -H 'Content-Type: application/json' -d '{
  "operation":"sql","sql":"SELECT * FROM verify.t WHERE id=2"}' | jq
```

Inspect mesh health:

```bash
curl -s -u "$USER:$PASS" -X POST $OPS -H 'Content-Type: application/json' \
  -d '{"operation":"cluster_status"}' | jq
```

Confirm each pod seeded the right peers:

```bash
for i in 0 1 2; do
  echo "== harper-$i =="
  kubectl -n $NS exec harper-$i -- sh -c 'cat $ROOTPATH/harper-config.yaml | sed -n "/replication:/,\$p"'
done
```

## 5. Repeatable / declarative config change

```bash
# change a config value; pods should roll because the config checksum changes
helm upgrade harper ./charts/harper -n $NS \
  -f ./charts/harper/values-k3s-longhorn.yaml \
  --set config.logging.level=debug

kubectl -n $NS rollout status sts/harper
kubectl -n $NS get pod harper-0 -o jsonpath='{.spec.containers[0].image}{"\n"}'
kubectl -n $NS exec harper-0 -- sh -c 'grep -A2 logging $ROOTPATH/harper-config.yaml'
```

## 6. Version upgrade

```bash
helm upgrade harper ./charts/harper -n $NS --reuse-values --set image.tag=5.0.27
kubectl -n $NS rollout status sts/harper
kubectl -n $NS get pods -l app.kubernetes.io/instance=harper \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

OpenShift/k8s performs an ordered rolling update (one pod at a time with
`OrderedReady`).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod CrashLoop, logs show config/CLI error | image start command isn't `harperdb run` | set `harper.command` / verify image entrypoint |
| Pod runs but admin login fails | admin env var names differ on this image | confirm `HDB_ADMIN_*` names; check `kubectl logs` for the install step |
| `config file validation error` / `database does not exist` | a config file was pre-seeded so Harper skipped install | wipe the PVC and reinstall; the chart now configures via `HARPER_DEFAULT_CONFIG`, not a seeded file |
| `Pending` PVC | storage class missing/!RWO | set `persistence.storageClassName` to a valid RWO class |
| `certificate signature failure` in replication logs | nodes haven't joined yet (each self-signs its own CA) | form the mesh with `scripts/harper-join-cluster.sh` (uses `add_node` + `verify_tls:false`) |
| `Should not connect to self` repeating | static routes / shared single cert in use | use the `add_node` join flow instead; redeploy without `tls.existingSecret` and run `harper-join-cluster.sh` |
| `Hostname/IP does not match certificate's altnames` | a shared single cert was applied (wrong) or stale cluster state | clean reinstall (wipe PVC), deploy multi-node, then `harper-join-cluster.sh` |
| Replication not converging | pods can't reach peers on 9933 | check headless Service + NetworkPolicy; inspect `cluster_status` |
| OpenShift pod denied | SCC/UID | ensure `openShift.enabled=true` (drops runAsUser/fsGroup) |
