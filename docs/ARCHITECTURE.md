# Architecture & Design Decisions

## Why a StatefulSet (not a Deployment)

Harper persists data to local files (LMDB/RocksDB) under `rootPath` and each node
has a **stable identity** in the replication mesh. That maps exactly to a
StatefulSet: stable network names (`<sts>-<n>.<headless>...`), ordered rollout,
and per-pod `volumeClaimTemplates`.

## How replication is wired (and why it's simple)

Harper's native replication (Plexus, v4.4+) is a **bi-directional pub/sub mesh
over WebSocket**, asynchronous, eventually consistent, with **no primary/replica
election**. Nodes are peers; a node joins by listing peer `routes` in its
config.

Because membership is static for a given `size`, we generate each pod's
`replication` block at boot from its ordinal:

```
replication:
  hostname: <sts>-<n>.<headless>.<ns>.svc.cluster.local
  url: wss://<self>:9933
  routes:                       # every OTHER pod
    - wss://<sts>-0...:9933
    - wss://<sts>-2...:9933
```

For multi-node clusters this is done by a small entry wrapper (`harper-entry.sh`,
shipped in a ConfigMap) that builds the block as JSON and forces it via
`HARPER_SET_CONFIG`, then execs Harper.

Contrast with the MongoDB operator: its hardest job is replica-set membership +
election. Harper has neither, so the control surface is smaller — the work is
just (a) bring up the pods and (b) hand each one the right peer list.

## Declarative config, repeatable deploys

Config from `config:` (verbatim passthrough of every option in the
[v5 reference](https://docs.harperdb.io/reference/v5/configuration/options)) is
serialized to JSON and passed to the container as **`HARPER_DEFAULT_CONFIG`**.
The image installs itself on first boot (creating a complete valid config, the
data directories, and the admin user) and layers our settings on top; on restart
Harper re-applies them. Pods carry a `checksum/config` annotation, so changing config
triggers a rolling restart automatically.

## Why not pre-seed harper-config.yaml

An earlier approach wrote a partial `harper-config.yaml` into `rootPath`. That
**breaks the Harper Pro image**: when a config file already exists, the image
treats the instance as already-installed — it skips the installer (so the
`database` directory and admin user are never created) and strict-validates the
file, demanding fields the installer would normally have written. The supported
mechanism is instead the config env vars (`HARPER_DEFAULT_CONFIG` /
`HARPER_SET_CONFIG`), which the installer respects while still doing a full
install. See the
[Configuration Overview](https://docs.harperdb.io/reference/v5/configuration/overview).

## Single-node vs. multi-node startup

Single-node runs the image's **native entrypoint** directly (just
`HARPER_DEFAULT_CONFIG` + admin env). Multi-node uses a thin `harper-entry.sh`
wrapper that computes the per-pod replication block, forces it via
`HARPER_SET_CONFIG`, and execs `harper.command` (`harperdb run` by default).

## Storage on Longhorn

Harper's read performance comes from memory-mapped local files. Longhorn
replicates blocks across nodes, which adds network latency. Two tunings matter:

- `dataLocality: best-effort` keeps a replica on the pod's node.
- `numberOfReplicas: 1–2` — Harper already replicates at the application layer
  when `size > 1`, so 3× Longhorn replicas under 3× Harper nodes is redundant
  write amplification.

Longhorn snapshots + backup-to-S3 can also serve as the backup mechanism;
decide whether Longhorn or Harper's native snapshot/restore is the source of
truth so backup consistency semantics are explicit.

## Security context / OpenShift

The certified `harper-pro-openshift` image is unprivileged. On vanilla k8s the
chart sets an explicit non-root UID/fsGroup. With `openShift.enabled=true` it
drops `runAsUser`/`runAsGroup`/`fsGroup` so the restricted-v2 SCC assigns them,
and creates a `Route` instead of an `Ingress`.

## Ports

| Port | Purpose |
|---|---|
| 9925 | Operations API (admin/JSON) |
| 9926 | Component HTTP server (REST/apps/WebSocket) |
| 4443 | HTTPS (component server) when TLS enabled |
| 9933 | Native replication (secure WebSocket) |
| 1883 / 8883 | MQTT / MQTT-TLS (when enabled via `config.mqtt`) |
| 9932 | Legacy clustering (image-exposed; not used by native replication) |

## Roadmap: operator

A Kubernetes operator (`HarperCluster` CRD) building on this chart's machinery
is planned as a follow-up. It will add declarative users/roles, health surfaced
in resource `.status`, and continuous drift correction via a reconcile loop.
The chart covers deploy, configuration, replication, scaling, and upgrades
today.
