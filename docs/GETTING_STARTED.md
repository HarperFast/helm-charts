# Getting Started

This guide installs the Harper Helm chart on **k3s + Longhorn** and on
**OpenShift**.

## Prerequisites

- `kubectl` configured against your cluster
- `helm` v3.8+
- A storage class (Longhorn on k3s; any RWO class on OpenShift)
- For the certified image, a pull secret if pulling from
  `registry.connect.redhat.com`
- (Optional) cert-manager for TLS; Prometheus Operator for ServiceMonitor

```bash
git clone https://github.com/HarperDB/helm-charts.git
cd helm-charts
```

---

## Installing the chart

### 1. Lint and preview (always do this first)

```bash
helm lint ./charts/harper
helm template harper ./charts/harper -f ./charts/harper/values-k3s-longhorn.yaml | less
```

`helm template` renders every manifest without touching the cluster — review
the StatefulSet, ConfigMap (note the seeded `harper-config.yaml`), and Services.

### 2. Start with a single node (fastest path to "is the image happy")

```bash
helm install harper ./charts/harper -n harper --create-namespace \
  --set replicaCount=1 \
  --set persistence.storageClassName=longhorn

kubectl -n harper rollout status sts/harper
kubectl -n harper logs sts/harper                   # Harper boot/install
```

If the pod is `Running` and the Operations API answers (see TESTING.md), the
image assumptions hold and you can scale out.

### 3. Scale to a replicating mesh

```bash
helm upgrade harper ./charts/harper -n harper \
  -f ./charts/harper/values-k3s-longhorn.yaml \
  --set replicaCount=3
```

The chart enables replication automatically when `replicaCount > 1` and wires a
full WebSocket mesh on port 9933.

### 4. k3s + Longhorn tuning (recommended)

Create a Longhorn StorageClass that matches Harper's app-layer replication
instead of stacking redundant block replicas:

```yaml
# longhorn-harper-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-harper
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "2"        # Harper already replicates; avoid 3x amplification
  dataLocality: "best-effort"  # co-locate a replica with the pod for read speed
  staleReplicaTimeout: "30"
```

```bash
kubectl apply -f longhorn-harper-sc.yaml
helm upgrade harper ./charts/harper -n harper \
  --set persistence.storageClassName=longhorn-harper --set replicaCount=3
```

### 5. OpenShift

```bash
# optional: create the pull secret for the certified registry
oc -n harper create secret docker-registry redhat-connect-pull-secret \
  --docker-server=registry.connect.redhat.com \
  --docker-username='<user>' --docker-password='<token>'

helm install harper ./charts/harper -n harper --create-namespace \
  -f ./charts/harper/values-openshift.yaml \
  --set imagePullSecrets[0].name=redhat-connect-pull-secret

oc -n harper get route harper
```

`values-openshift.yaml` sets `openShift.enabled=true`, which drops
`runAsUser`/`fsGroup` so the restricted-v2 SCC assigns them (the image is
unprivileged), and creates a Route.

### Setting any Harper config option

Everything under `config:` lands in `harper-config.yaml`. Example enabling MQTT
and switching the storage engine:

```bash
helm upgrade harper ./charts/harper -n harper \
  --set config.mqtt.network.port=1883 \
  --set config.mqtt.webSocket=true \
  --set config.storage.engine=lmdb
```

For nested/complex values use a `-f my-values.yaml` overlay rather than
`--set`.

---

> **Coming soon:** a Kubernetes operator (`HarperCluster` CRD) for declarative
> day-2 operations — users/roles, upgrades, scaling — is planned as a follow-up
> to this chart.

Continue to [TESTING.md](TESTING.md) to verify each capability.
