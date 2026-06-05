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

## 4. Scale to a replicating mesh

Scale up, wait for all pods to be ready, then **join them into a mesh**. Each
pod boots advertising its own replication identity but with no peers; the join
script connects them using Harper's documented `add_node` flow (with
`verify_tls:false`, which establishes trust between the self-signed nodes — the
supported approach for fresh self-signed installs).

```bash
helm upgrade harper ./charts/harper -n harper \
  --set replicaCount=3 \
  --set persistence.storageClassName=local-path \
  --set persistence.size=5Gi

kubectl -n harper rollout status sts/harper --timeout=300s
kubectl -n harper get pods -o wide        # should spread across agent nodes
```

The chart forms the mesh **automatically**: a post-install/upgrade hook Job
(`replication.autoJoin`, on by default) runs `add_node` from `harper-0` to every
peer once the pods are up. Watch it and confirm:

```bash
kubectl -n harper logs job/harper-join          # shows add_node + cluster_status
./scripts/harper-op.sh 0 '{"operation":"cluster_status"}'
```

You want `connected: true` sockets. (You can also re-run it by hand any time with
`./scripts/harper-join-cluster.sh 3`, or disable the auto Job with
`--set replication.autoJoin=false`.) Then run the replication checks in
[TESTING.md §4](TESTING.md) (write on `harper-0`, read on `harper-1`).

> Why a join step? Replication is mutual-TLS and Harper gives each node its own
> per-node cert from an internal store. Pre-sharing one cert breaks node
> identity ("Should not connect to self"); per-node self-signed certs don't
> trust each other ("certificate signature failure"). `add_node` is Harper's
> built-in way to establish that trust. For production, issue per-node certs
> from one CA (e.g. cert-manager) so trust is automatic — confirm the exact
> setup with Harper engineering.

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
   matches the certified image's architecture. This is the path I'd use for the
   replication/upgrade/scaling tests that need Harper actually running.

If/when a multi-arch (arm64) Harper image is available, none of this applies —
just set `image.repository`/`image.tag` accordingly.
