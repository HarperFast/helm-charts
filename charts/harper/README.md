# Harper Helm Chart

Deploys a configurable number of **Harper (Harper Pro)** instances on Kubernetes
or OpenShift as a `StatefulSet`, with:

- **Configurable replica count** (`replicaCount`) and **Harper release** (`image.tag`).
- **Full passthrough of every `harper-config.yaml` option** via `config:` —
  see the [v5 configuration reference](https://docs.harperdb.io/reference/v5/configuration/options).
- **Automatic native-replication mesh** (Plexus / WebSocket) wiring across pods
  using their stable StatefulSet DNS names.
- **Per-pod persistence** via `volumeClaimTemplates` (Longhorn by default).
- **Repeatable, declarative deploys** — the chart-managed config is re-seeded on
  every boot, and pods roll automatically when it changes (config checksum).
- OpenShift `Route`, k8s `Ingress`, cert-manager TLS, PDB, and ServiceMonitor.

## Quick start

```bash
# k3s + Longhorn
helm install harper ./charts/harper \
  -n harper --create-namespace \
  -f ./charts/harper/values-k3s-longhorn.yaml

# OpenShift
helm install harper ./charts/harper \
  -n harper --create-namespace \
  -f ./charts/harper/values-openshift.yaml
```

## Try it locally first

No cluster yet? Spin up a free local **k3d** (k3s-in-Docker) cluster:

```bash
./scripts/local-k3d-up.sh
helm install harper ./charts/harper -n harper --create-namespace \
  --set replicaCount=1 --set persistence.storageClassName=local-path --set persistence.size=5Gi
```

Full local walkthrough: [`../../docs/LOCAL_TESTING.md`](../../docs/LOCAL_TESTING.md).

See also [`../../docs/GETTING_STARTED.md`](../../docs/GETTING_STARTED.md) and
[`../../docs/TESTING.md`](../../docs/TESTING.md).

## Key values

| Value | Default | Purpose |
|---|---|---|
| `replicaCount` | `3` | Number of Harper instances |
| `image.repository` | `harperfast/harper-pro-openshift` | Certified image |
| `image.tag` | `5.0.26` | **The Harper release to deploy** |
| `config` | see values.yaml | **Every `harper-config.yaml` option** — passed via `HARPER_DEFAULT_CONFIG` |
| `replication.enabled` | `auto` | Mesh on when `replicaCount > 1` |
| `replication.autoJoin` | `true` | Auto-form the mesh via a post-install `add_node` hook Job |
| `persistence.storageClassName` | `longhorn` | Per-pod volume class |
| `persistence.size` | `20Gi` | Per-pod volume size |
| `harper.admin.*` | — | Bootstrap super-user (Secret-backed) |
| `harper.rootPath` | `/opt/harper/hdb` | Harper data/config/logs root (PVC mount) |
| `harper.home` | `/home/harperdb` | Process HOME (image user's group-0-writable home) |
| `tls.*` | disabled | cert-manager or existing-secret TLS |
| `openShift.enabled` | `false` | SCC-friendly security context + Route |
| `serviceMonitor.enabled` | `false` | Prometheus Operator scraping |

## Setting arbitrary Harper options

Anything under `config:` is serialized to JSON and passed to Harper as
`HARPER_DEFAULT_CONFIG`, so the image installs normally and applies your settings
on top (the chart does **not** pre-write a config file — that would make Harper
skip its installer). Example: 

```yaml
config:
  http:
    port: 9926
    securePort: 4443
    http2: true
  mqtt:
    network: { port: 1883, securePort: 8883 }
    webSocket: true
  storage:
    engine: lmdb
    writeAsync: false
    caching: true
  logging:
    level: debug
    stdStreams: true
  threads:
    count: 11
```

> When `replication.enabled` is on, the chart owns the `replication:` block —
> do not also set `config.replication`.

## How replication is wired

For multi-node clusters, a small `harper-entry.sh` wrapper gives each pod its own
replication identity (`hostname`/`url` from its StatefulSet ordinal —
`<release>-harper-<n>.<headless-svc>.<ns>.svc.<cluster-domain>`) on
`replication.securePort` (default `9933`), with **empty routes**. The mesh is
then formed **automatically** by a post-install/upgrade hook Job
(`replication.autoJoin`, default `true`) that runs `add_node` from `harper-0` to
every peer once the pods are ready — no manual step:

```bash
kubectl -n harper logs job/harper-join                 # see the join + cluster_status
./scripts/harper-op.sh 0 '{"operation":"cluster_status"}'
```

The Job re-runs on every `helm upgrade`, so scaling up re-forms the mesh with the
new peers. To join by hand instead, set `replication.autoJoin=false` and run
`./scripts/harper-join-cluster.sh <replicas>`.

> **Why an explicit join?** Harper replication is mutual-TLS and each node gets
> its own per-node cert from an internal store. A single pre-shared cert breaks
> node identity ("Should not connect to self"); separate self-signed certs don't
> trust each other ("certificate signature failure"). `add_node` with
> `verify_tls:false` is Harper's documented way to establish trust between fresh
> self-signed nodes. For production, issue **per-node** certs from one CA (e.g.
> cert-manager) so trust is automatic. (`scripts/gen-replication-certs.sh` is
> retained for that per-CA direction but is not used by the default flow.)

## Assumptions to validate against your image

- The image's start command is `harperdb run` (override with `harper.command`).
- Admin bootstrap honors `HDB_ADMIN_USERNAME` / `HDB_ADMIN_PASSWORD` /
  `TC_AGREEMENT` env vars.
- `ROOTPATH` relocates Harper's data/config root.

All three match the published HarperDB container conventions; confirm on the
exact `harper-pro-openshift` tag you deploy.
