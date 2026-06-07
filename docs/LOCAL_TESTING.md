# Local Testing with k3d

The closest local mirror of your production environment is **k3d** — it runs
real **k3s** inside Docker, so the same lightweight distro, the same default
ingress (Traefik), and the same `local-path` storage provisioner you'd expect
from k3s. You can stand up a multi-node cluster in ~30 seconds and tear it down
just as fast.

> **Architecture note (read first):** the certified image
> `harperfast/harper-pro-openshift` is **amd64-only**. On an amd64 host
> (Linux, Windows/WSL2, or an Intel Mac) everything below "just works." On
> **Apple Silicon (M1–M4)** the image runs under emulation, which is slow and
> occasionally flaky — fine for a quick functional check, but do your final
> validation on an amd64 machine (a cheap cloud VM or CI runner). See
> [Apple Silicon](#apple-silicon-notes) below.

---

## 1. Install the tools

| Tool | macOS (Homebrew) | Linux |
|---|---|---|
| Docker | Docker Desktop | Docker Engine |
| kubectl | `brew install kubectl` | [docs](https://kubernetes.io/docs/tasks/tools/) |
| helm | `brew install helm` | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| k3d | `brew install k3d` | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |

Verify:

```bash
docker info >/dev/null && kubectl version --client && helm version && k3d version
```

---

## 2. Create a multi-node cluster

A 1-server + 3-agent cluster lets you exercise the replication mesh and
pod-anti-affinity spreading just like a real deployment.

```bash
k3d cluster create harper-dev \
  --servers 1 \
  --agents 3 \
  --port "9925:9925@loadbalancer" \
  --port "9926:9926@loadbalancer" \
  --wait

kubectl get nodes
```

k3d automatically points your kubeconfig at the new cluster. The default
StorageClass is `local-path` (k3s's built-in provisioner), which supports
`ReadWriteOnce` — exactly what this chart needs.

> Or just run `./scripts/local-k3d-up.sh` from the repo root, which does all of
> the above.

---

## 3. Deploy a single node first

Always smoke-test one node before scaling — it's the fastest way to confirm the
image boots happily with the chart's config and admin bootstrap.

```bash
helm install harper ./charts/harper \
  -n harper --create-namespace \
  --set replicaCount=1 \
  --set persistence.storageClassName=local-path \
  --set persistence.size=5Gi

kubectl -n harper rollout status sts/harper --timeout=300s
kubectl -n harper logs sts/harper                  # Harper boot/install logs
```

Hit the Operations API:

```bash
USER=$(kubectl -n harper get secret harper-admin -o jsonpath='{.data.username}' | base64 -d)
PASS=$(kubectl -n harper get secret harper-admin -o jsonpath='{.data.password}' | base64 -d)

kubectl -n harper port-forward svc/harper 9925:9925 &
curl -s -u "$USER:$PASS" -X POST http://localhost:9925 \
  -H 'Content-Type: application/json' -d '{"operation":"describe_all"}' | jq
```

A JSON response means the chart, config seeding, and admin bootstrap all work.

---

## 4. Deploy a 3-node replicated cluster

For a multi-node cluster, do a **clean install** (a fresh data volume). This
matters: Harper persists node + certificate state, so leftover state from an
earlier single-node or mis-joined run will block the mesh. Start clean:

```bash
# if a release already exists, wipe it AND its data volumes first
helm uninstall harper -n harper 2>/dev/null || true
kubectl -n harper delete pvc -l app.kubernetes.io/instance=harper 2>/dev/null || true

helm install harper ./charts/harper -n harper --create-namespace \
  --set replicaCount=3 \
  --set persistence.storageClassName=local-path \
  --set persistence.size=5Gi

kubectl -n harper rollout status sts/harper --timeout=600s
kubectl -n harper get pods -o wide        # harper-0/1/2, spread across agent nodes
```

Each pod boots with its own unique identity (`node.hostname` = its pod FQDN) and
empty routes. The chart then forms the mesh **automatically**: a
post-install/upgrade hook Job (`replication.autoJoin`, on by default) runs
`add_node` from `harper-0` to the peers. This is Harper's documented
**cross-generated certificate** flow — `add_node` with `verify_tls:false` makes
the nodes generate and sign certs for each other and store them for all future
connections, and gossip discovery propagates membership to the rest of the
cluster. No manual certificate handling is required.

```bash
kubectl -n harper logs job/harper-join          # add_node calls + cluster_status
```

Confirm every node has a unique name and is connected:

```bash
for i in 0 1 2; do echo "harper-$i:"; ./scripts/harper-op.sh $i '{"operation":"cluster_status"}' \
  | jq '{node_name, conns:(.connections|length), connected:[.connections[]?.database_sockets[]?.connected]}'; done
```

You want `node_name` = `harper-N.harper-headless...` (not `localhost`) and
`connected: [true, ...]`. If the Job ran before all pods were Ready, re-run the
join once (gossip needs the targets up to sign CSRs):

```bash
./scripts/harper-join-cluster.sh 3
```

> **Notes from the Harper replication docs:**
> - Identity comes from `node.hostname`; trust comes from the cross-generated
>   certs that `add_node` exchanges. Don't hand-place certs into `keys/` — it
>   fights that flow.
> - For production, supply per-node certs from one CA via `tls.certificate` /
>   `tls.certificateAuthority` / `tls.privateKey` (Harper loads them into its
>   certificate table), or use cert-manager.
> - **Users and roles are NOT replicated.** The chart sets the same admin on
>   every pod, but app users created via the API must be created on each node.

---

## 4b. Verify replication works (write here, read there)

The real proof: write on one node, read it back from another.

```bash
# 1. create a database + table (replicated DDL like create_table propagates)
./scripts/harper-op.sh 0 '{"operation":"create_database","database":"dev"}'
./scripts/harper-op.sh 0 '{"operation":"create_table","database":"dev","table":"dog","primary_key":"id"}'

# 2. WRITE on harper-0
./scripts/harper-op.sh 0 '{"operation":"insert","database":"dev","table":"dog","records":[{"id":1,"name":"penny"}]}'

# 3. READ the same record from harper-1 and harper-2 (give async replication a moment)
sleep 3
./scripts/harper-op.sh 1 '{"operation":"sql","sql":"SELECT * FROM dev.dog WHERE id=1"}'
./scripts/harper-op.sh 2 '{"operation":"sql","sql":"SELECT * FROM dev.dog WHERE id=1"}'
```

Both reads should return `penny`. Try it the other way too (write on `harper-2`,
read on `harper-0`) — replication is bidirectional. To watch it live, tail a
receiving node while you insert on another:

```bash
kubectl -n harper logs -f harper-1 | grep -i replication
```

> Note: `create_table` (and inserts/updates/deletes) replicate, but **destructive
> schema ops** (`drop_table`, `drop_database`) do **not** — run those on each node.

---

## 5. (Optional) Install Longhorn to mirror prod exactly

`local-path` is enough for functional testing, but if you want to validate
Longhorn behavior (snapshots, the storage-class tuning from `ARCHITECTURE.md`):

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s

# then deploy against it
helm upgrade harper ./charts/harper -n harper \
  --set persistence.storageClassName=longhorn --set replicaCount=3
```

> Longhorn on k3d works but is heavier (it wants real block devices); give
> Docker plenty of CPU/RAM. For day-to-day chart iteration, stick with
> `local-path`.

---

## 6. Tear down

```bash
helm uninstall harper -n harper || true
k3d cluster delete harper-dev
# or: ./scripts/local-k3d-down.sh
```

PVCs from a StatefulSet are **not** auto-deleted; `k3d cluster delete` removes
everything since the data lives inside the cluster's Docker volumes.

---

## Apple Silicon notes

The certified image is amd64-only. Options, fastest to most reliable:

1. **Quick check under emulation.** Docker Desktop can run amd64 images via
   Rosetta/QEMU. It works for a single node but is slow and can hit occasional
   crashes during heavy I/O. Enable *Settings → General → Use Rosetta for x86/amd64
   emulation* in Docker Desktop, then deploy as above. Expect slow boots.
2. **Test chart mechanics only.** `helm template` + `kubectl apply --dry-run=server`
   validates all manifests without running Harper — useful for iterating on the
   chart itself on any architecture.
3. **Use an amd64 host for functional tests (recommended).** A small amd64 cloud
   VM (or a CI runner) running k3s/k3d gives you a clean, fast environment that
   matches the certified image's architecture. This is the recommended path for
   the replication/upgrade/scaling tests that need Harper actually running.

If/when a multi-arch (arm64) Harper image is available, none of this applies —
just set `image.repository`/`image.tag` accordingly.
