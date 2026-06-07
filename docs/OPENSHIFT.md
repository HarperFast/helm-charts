# Deploying Harper on OpenShift

A complete walkthrough for deploying a Harper cluster on Red Hat OpenShift,
written for engineers who know OpenShift but are new to Harper. It covers image
access (including disconnected clusters), the SecurityContextConstraints (SCC)
requirements, deploying and verifying a replicated cluster, reaching the admin
API, NetworkPolicy, and TLS.

The chart ships an OpenShift overlay, [`values-openshift.yaml`](../charts/harper/values-openshift.yaml),
which sets `openShift.enabled=true` (drops `runAsUser`/`runAsGroup`/`fsGroup` so
the SCC assigns them) and creates a `Route`.

---

## 1. Images & registries

The Harper Pro image is **amd64-only** and published in two places:

| Source | Repository | Notes |
|---|---|---|
| Red Hat certified | `registry.connect.redhat.com/harperfast/harper-pro-openshift` | requires a Red Hat registry pull secret |
| Docker Hub | `harperfast/harper-pro-openshift` | open; the chart default |

> On ARM-based OpenShift the stock image won't run. Use an amd64 node pool.

### Pull secret (Red Hat certified registry)

```bash
oc new-project harper
oc -n harper create secret docker-registry redhat-connect-pull-secret \
  --docker-server=registry.connect.redhat.com \
  --docker-username='<your-RH-service-account>' \
  --docker-password='<token>'
```

Then deploy with:

```bash
--set image.repository=registry.connect.redhat.com/harperfast/harper-pro-openshift \
--set imagePullSecrets[0].name=redhat-connect-pull-secret
```

### Disconnected / air-gapped clusters

Mirror the image into your internal registry and point Harper at it.

```bash
# 1. mirror (run from a host with access to both registries)
oc image mirror \
  registry.connect.redhat.com/harperfast/harper-pro-openshift:5.0.26 \
  <internal-registry>/harper/harper-pro-openshift:5.0.26
```

```yaml
# 2. (optional) cluster-wide digest mirror so any pull is redirected
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: harper
spec:
  imageDigestMirrors:
    - source: registry.connect.redhat.com/harperfast/harper-pro-openshift
      mirrors:
        - <internal-registry>/harper/harper-pro-openshift
```

Then `--set image.repository=<internal-registry>/harper/harper-pro-openshift`.
For immutable pulls, pin by digest instead of tag:
`--set image.digest=sha256:<digest>` (takes precedence over `image.tag`).

---

## 2. SecurityContextConstraints (SCC)

**The default `restricted-v2` SCC is sufficient — no custom SCC is required.**
The image is built to OpenShift conventions: it runs as the **arbitrary UID**
the SCC assigns, with **GID 0** (the root group). Harper's home and install
directories (`/home/harperdb`) are group-0-writable, which is exactly why the
arbitrary UID can run it. The chart's `openShift.enabled=true` drops
`runAsUser`/`runAsGroup`/`fsGroup` so OpenShift fills them from the namespace.

Verify the namespace will assign a UID range and that the ServiceAccount can use
`restricted-v2`:

```bash
oc get project harper -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}'
oc adm policy who-can use scc restricted-v2 -n harper
```

If your cluster has been hardened (e.g. `restricted-v2` removed, or a custom SCC
without GID 0), grant a suitable SCC to the chart's ServiceAccount:

```bash
oc adm policy add-scc-to-user restricted-v2 -z harper -n harper   # -z = serviceaccount
```

> **Symptom if this is wrong:** the pod crashes on startup with
> `EACCES: permission denied, mkdir '/opt/harper/hdb'` or a write error under
> `/home/harperdb`. That means the process isn't in GID 0 / the volume isn't
> group-writable — fix the SCC rather than the chart.

---

## 3. Deploy — single node first, then scale

Even though the overlay defaults to 3 replicas, **install one node first** to
confirm the image, SCC, and storage are happy before introducing replication.

```bash
helm install harper ./charts/harper -n harper --create-namespace \
  -f ./charts/harper/values-openshift.yaml \
  --set replicaCount=1 \
  --set image.repository=registry.connect.redhat.com/harperfast/harper-pro-openshift \
  --set imagePullSecrets[0].name=redhat-connect-pull-secret \
  --set persistence.storageClassName=<your-RWO-storageclass>

oc -n harper rollout status sts/harper --timeout=600s
oc -n harper logs sts/harper        # should show Harper install + start, no EACCES
```

`persistence.storageClassName` must be a **ReadWriteOnce** class (Harper stores
data per-pod via `volumeClaimTemplates`). Leave it unset to use the cluster
default.

Confirm the API is reachable (see §5), then scale to a replicated cluster:

```bash
helm upgrade harper ./charts/harper -n harper \
  -f ./charts/harper/values-openshift.yaml \
  --set replicaCount=3 \
  --set image.repository=registry.connect.redhat.com/harperfast/harper-pro-openshift \
  --set imagePullSecrets[0].name=redhat-connect-pull-secret \
  --set persistence.storageClassName=<your-RWO-storageclass>

oc -n harper rollout status sts/harper --timeout=600s
oc -n harper get pods -o wide
```

---

## 4. Replication & how to verify it

When `replicaCount > 1` the chart enables Harper's peer-to-peer replication:

- Each pod boots with a **unique identity** — `node.hostname` is set to its
  StatefulSet FQDN (`harper-<n>.harper-headless.<ns>.svc.cluster.local`).
- A **post-install/upgrade hook Job** (`replication.autoJoin`, default on) runs
  `add_node` from `harper-0` to the peers. This is Harper's documented
  **cross-generated certificate** flow: `add_node` with `verify_tls:false` makes
  the self-signed nodes generate and sign certs for each other and store them
  for all future connections; gossip discovery then propagates membership.

Watch the join and verify the mesh:

```bash
oc -n harper logs job/harper-join

oc -n harper exec harper-0 -- true   # ensure pod is reachable
# admin creds:
HUSER=$(oc -n harper get secret harper-admin -o jsonpath='{.data.username}' | base64 -d)
HPASS=$(oc -n harper get secret harper-admin -o jsonpath='{.data.password}' | base64 -d)

# from a local shell, port-forward harper-0 and check status:
oc -n harper port-forward harper-0 9925:9925 &
curl -s -u "$HUSER:$HPASS" -X POST http://localhost:9925 \
  -H 'Content-Type: application/json' -d '{"operation":"cluster_status"}'
```

You want each node's `node_name` to be its FQDN (not `localhost`) and
`database_sockets` with `"connected":true`.

You can also let Helm assert it for you — the chart ships a replication test:

```bash
helm test harper -n harper --logs   # runs connection + replication checks
```

### Prove replication (write here, read there)

```bash
# write on harper-0, read on harper-1 (port-forward each, or use scripts/harper-op.sh)
curl -s -u "$HUSER:$HPASS" -X POST http://localhost:9925 -H 'Content-Type: application/json' \
  -d '{"operation":"insert","database":"dev","table":"dog","records":[{"id":1,"name":"penny"}]}'
# (port-forward harper-1 to another local port and SELECT id=1 — it should return penny)
```

### Replication troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `certificate signature failure` | nodes haven't joined, or stale cert/node state from a prior run | clean reinstall (`helm uninstall` + delete PVCs), then redeploy; the join Job re-runs |
| `Should not connect to self` / `node_name: localhost` | identity not set | ensure you're on a chart version that sets `node.hostname` (this one does); clean reinstall |
| mesh never connects, no cert errors | pod-to-pod traffic blocked | enable the NetworkPolicy (§6) or check your cluster's default-deny rules |
| pod `CrashLoopBackOff`, `EACCES` | SCC / GID 0 | see §2 |

> Note from Harper's docs: **users/roles are not replicated**, and destructive
> schema ops (`drop_table`/`drop_database`) must be run on each node. The chart
> sets the same admin on every pod.

---

## 5. Reaching the Operations API

Harper exposes two HTTP interfaces:

| Port | Interface | Exposed by the default Route? |
|---|---|---|
| 9926 | Component / REST server (apps, REST, WebSocket/MQTT) | **yes** |
| 9925 | Operations API (admin: databases, SQL, users, cluster ops) | no |

The `Route` created by the overlay serves the **component server (9926)**. The
**Operations API (9925)** — which every admin example uses — is **not** routed
by default. Reach it as an admin via port-forward:

```bash
oc -n harper port-forward svc/harper 9925:9925
curl -u "$HUSER:$HPASS" -X POST http://localhost:9925 \
  -H 'Content-Type: application/json' -d '{"operation":"describe_all"}'
```

If you need external admin access, enable the optional second Route (keep it
behind your ingress security — it's the admin plane):

```bash
helm upgrade harper ./charts/harper -n harper --reuse-values \
  --set route.operationsApi.enabled=true
oc -n harper get route harper-ops
```

---

## 6. NetworkPolicy (default-deny clusters)

Many OpenShift clusters default-deny pod traffic. Harper needs pod-to-pod on the
replication port (9933) plus in-namespace access to 9925/9926. The chart ships
an optional NetworkPolicy:

```bash
helm upgrade harper ./charts/harper -n harper --reuse-values \
  --set networkPolicy.enabled=true
```

It allows intra-namespace ingress to the Harper ports, DNS egress, and
pod-to-pod replication egress. For clients in **other** namespaces, add them:

```bash
--set networkPolicy.allowedNamespaces[0]=my-app-namespace
```

(Or `--set networkPolicy.allowExternal=true` to allow any source — use with
care.) The Route/router traffic is generally allowed by the platform; if your
router runs with a namespace label you restrict on, add it to
`allowedNamespaces`.

---

## 7. TLS

### Router TLS (default)

The overlay enables an **edge**-terminated Route: TLS at the router, plaintext
from the router to the pod inside the cluster. Good enough for many internal
deployments and needs no Harper-side cert.

### End-to-end TLS (reencrypt)

If policy requires encryption all the way to the pod, terminate at the router
and re-encrypt to Harper:

1. Give Harper a serving cert (see [chart README → Bringing your own
   certificates](../charts/harper/README.md#bringing-your-own-certificates)) and
   enable HTTPS:

   ```bash
   --set tls.enabled=true --set tls.existingSecret=my-harper-tls \
   --set config.http.securePort=4443
   ```

2. Switch the Route to reencrypt and give the router the CA that signed Harper's
   cert so it trusts the backend:

   ```yaml
   # values-overlay.yaml
   route:
     tls:
       termination: reencrypt
       destinationCACertificate: |
         -----BEGIN CERTIFICATE-----
         ...your CA...
         -----END CERTIFICATE-----
   ```

`passthrough` is also supported (Harper terminates TLS itself) — set
`route.tls.termination=passthrough` with Harper HTTPS enabled.

### Replication TLS

Replication is always mutual-TLS between pods. By default Harper self-signs and
cross-generates trust via `add_node` (§4). For managed trust, supply per-node
certs from one CA (cert-manager via `tls.certManager`, or your own secret) — see
the chart README.

---

## 8. Day-2 quick reference

```bash
# upgrade Harper version (rolling, one pod at a time)
helm upgrade harper ./charts/harper -n harper --reuse-values --set image.tag=<new>

# scale (re-runs the join Job to add new peers)
helm upgrade harper ./charts/harper -n harper --reuse-values --set replicaCount=5

# change any harper-config.yaml option (pods roll automatically)
helm upgrade harper ./charts/harper -n harper --reuse-values --set config.logging.level=debug

# admin password
oc -n harper get secret harper-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

Storage notes: PVCs are **not** deleted on `helm uninstall` (data is preserved);
delete them explicitly to start clean. Expanding a PVC requires a StorageClass
with `allowVolumeExpansion: true` and is done per-claim; PVCs cannot shrink, so
size up front.

> Backups: Harper supports snapshot/restore; on OpenShift you can also use CSI
> `VolumeSnapshot`/ODF against the per-pod PVCs. Define and test your DR process
> before production — it is not automated by this chart.
