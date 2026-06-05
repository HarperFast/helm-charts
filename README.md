# Harper Helm Charts

Helm charts for deploying [Harper](https://www.harperdb.io) clusters on
Kubernetes and OpenShift.

The `harper` chart runs N Harper instances as a `StatefulSet` with stable
network identity, per-pod persistent storage, an automatically wired native
replication mesh, and full passthrough of every
[`harper-config.yaml` option](https://docs.harperdb.io/reference/v5/configuration/options).

## Install from the hosted repo

[Helm](https://helm.sh) v3.8+ must be installed — see Helm's
[documentation](https://helm.sh/docs) to get started.

```bash
helm repo add harper https://harperfast.github.io/helm-charts
helm repo update
helm install harper harper/harper -n harper --create-namespace
```

To uninstall:

```bash
helm uninstall harper -n harper
```

## Try it locally first (free, ~30 seconds)

The quickest way to try the chart is a local [k3d](https://k3d.io) cluster —
real k3s inside Docker:

```bash
./scripts/local-k3d-up.sh                       # 1 server + 3 agents
helm install harper ./charts/harper -n harper --create-namespace \
  --set replicaCount=1 \
  --set persistence.storageClassName=local-path --set persistence.size=5Gi
```

Full walkthrough (multi-node, replication checks, Longhorn, Apple Silicon
caveat): [docs/LOCAL_TESTING.md](docs/LOCAL_TESTING.md).

## What's in this repo

```
helm-charts/
├── charts/harper/          The Harper Helm chart
├── docs/
│   ├── GETTING_STARTED.md  Install on k3s + Longhorn and OpenShift
│   ├── LOCAL_TESTING.md    Stand up a free local k3d cluster and test the chart
│   ├── INTERACTING.md      Connect to pods & run Harper ops against each instance
│   ├── TESTING.md          Verify replication, scaling, upgrades, users
│   └── ARCHITECTURE.md     How it works + design decisions
└── scripts/                local-k3d-up.sh / local-k3d-down.sh / harper-op.sh /
                            harper-join-cluster.sh / gen-replication-certs.sh
```

## Target environments

- **k3s + Longhorn** (lightweight Kubernetes + replicated block storage).
- **Red Hat OpenShift** using the certified, unprivileged image
  [`harperfast/harper-pro-openshift`](https://catalog.redhat.com/en/software/containers/harperfast/harper-pro-openshift).

## Configuration

Every `harper-config.yaml` option can be set via the chart's `config:` value.
See [charts/harper/README.md](charts/harper/README.md) for the full values
reference, replication wiring details, and examples.

## Roadmap

A Kubernetes operator (`HarperCluster` CRD) for declarative day-2 operations —
users/roles, upgrades, scaling, drift correction — is planned as a follow-up
to this chart.

## License

[Apache-2.0](LICENSE)
