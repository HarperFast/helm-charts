# Interacting with a Deployed Harper Cluster

How to connect to your running Harper pods, run database operations, and test
functionality against **individual instances** (essential for verifying
replication). Everything here works on the local k3d cluster and on a real
k3s/OpenShift deployment.

Harper exposes two HTTP interfaces per pod:

| Port | Interface | Use for |
|---|---|---|
| **9925** | **Operations API** — JSON-over-HTTP admin/data API | databases, tables, SQL, users, cluster ops, config |
| **9926** | **Component/REST server** — auto-generated REST from your schema | RESTful CRUD on resources, apps, WebSocket/MQTT |

Most testing uses the Operations API on 9925.

---

## 1. Credentials

```bash
export NS=harper
export HUSER=$(kubectl -n $NS get secret harper-admin -o jsonpath='{.data.username}' | base64 -d)
export HPASS=$(kubectl -n $NS get secret harper-admin -o jsonpath='{.data.password}' | base64 -d)
echo "admin = $HUSER / $HPASS"
```

---

## 2. Three ways to reach the pods

### A. The load-balanced Service (any pod)
Good for normal client traffic; you don't control which pod answers.

```bash
kubectl -n $NS port-forward svc/harper 9925:9925
# then, in another shell:
curl -s -u "$HUSER:$HPASS" -X POST http://localhost:9925 \
  -H 'Content-Type: application/json' -d '{"operation":"describe_all"}' | jq
```

### B. A specific instance (required for replication testing)
Each pod has a stable name `harper-0`, `harper-1`, ... Port-forward straight to one:

```bash
kubectl -n $NS port-forward pod/harper-0 19250:9925   # node 0 on localhost:19250
kubectl -n $NS port-forward pod/harper-1 19251:9925   # node 1 on localhost:19251
```

### C. The helper script (easiest for ad-hoc commands)
`scripts/harper-op.sh` handles the port-forward + auth for you and targets a
specific instance by ordinal, or `svc` for the load-balanced Service:

```bash
./scripts/harper-op.sh 0   '{"operation":"describe_all"}'
./scripts/harper-op.sh 1   '{"operation":"cluster_status"}'
./scripts/harper-op.sh svc '{"operation":"system_information"}'
```

> Inside a pod, loopback requests are auto-authorized as super-user
> (`authentication.authorizeLocal`), so you can also exec in without creds:
> `kubectl -n $NS exec -it harper-0 -- harperdb get_configuration` (CLI), or hit
> `http://localhost:9925` from within the container.

A convenient shell function for the rest of this doc:

```bash
hop() { ./scripts/harper-op.sh "$1" "$2" | jq; }   # hop <ordinal|svc> '<json>'
```

---

## 3. Core database operations (Operations API)

All of these are `POST` bodies to port 9925. Create a database and table, then
read/write. (Full reference: https://docs.harperdb.io/reference/v5/operations-api/operations)

### Create a database and table
```bash
hop svc '{"operation":"create_database","database":"dev"}'
hop svc '{"operation":"create_table","database":"dev","table":"dog","primary_key":"id"}'
hop svc '{"operation":"describe_table","database":"dev","table":"dog"}'
```

### Insert / update / upsert
```bash
hop svc '{"operation":"insert","database":"dev","table":"dog","records":[
  {"id":1,"name":"Penny","breed":"Mutt","age":7},
  {"id":2,"name":"Harper","breed":"Husky","age":3}
]}'

hop svc '{"operation":"update","database":"dev","table":"dog","records":[{"id":2,"age":4}]}'

hop svc '{"operation":"upsert","database":"dev","table":"dog","records":[{"id":3,"name":"Rex"}]}'
```

### Read: by id, by condition, and SQL
```bash
hop svc '{"operation":"search_by_hash","database":"dev","table":"dog","ids":[1,2],"get_attributes":["*"]}'

hop svc '{"operation":"search_by_conditions","database":"dev","table":"dog",
  "operator":"and","conditions":[{"search_attribute":"age","search_type":"greater_than","search_value":3}],
  "get_attributes":["*"]}'

hop svc '{"operation":"sql","sql":"SELECT id, name, age FROM dev.dog ORDER BY age DESC"}'
```

### Delete / drop
```bash
hop svc '{"operation":"delete","database":"dev","table":"dog","ids":[3]}'
hop svc '{"operation":"drop_table","database":"dev","table":"dog"}'
hop svc '{"operation":"drop_database","database":"dev"}'
```

---

## 4. Testing each instance + replication

This is why per-pod access matters: write on one node, confirm it appears on the
others.

```bash
# seed schema on any node
hop 0 '{"operation":"create_database","database":"dev"}'
hop 0 '{"operation":"create_table","database":"dev","table":"dog","primary_key":"id"}'

# write on node 0
hop 0 '{"operation":"insert","database":"dev","table":"dog","records":[{"id":100,"name":"from-node-0"}]}'

# read the SAME record from node 1 and node 2 (async replication, give it a moment)
sleep 2
hop 1 '{"operation":"sql","sql":"SELECT * FROM dev.dog WHERE id=100"}'
hop 2 '{"operation":"sql","sql":"SELECT * FROM dev.dog WHERE id=100"}'
```

Inspect the mesh from each node:

```bash
hop 0 '{"operation":"cluster_status"}'      # connections + per-database sockets + latency
hop 0 '{"operation":"cluster_get_routes"}'  # the peer routes this node was given
```

`cluster_status` returns `connections[].database_sockets[]` with `connected`,
`latency`, and `lastReceived*` timestamps — a growing gap between
`lastReceivedRemoteTime` and `lastReceivedLocalTime` means a node is catching up.

Run one command across every pod:

```bash
for i in 0 1 2; do
  echo "== harper-$i =="
  ./scripts/harper-op.sh $i '{"operation":"sql","sql":"SELECT count(*) AS n FROM dev.dog"}'
done
```

### Live cluster membership (normally the chart wires this for you)
The chart forms the mesh automatically, but you can inspect/modify it live
(super-user only). See https://docs.harperdb.io/reference/v5/replication/clustering

```bash
# add a route to another node (PATCH/upsert)
hop 0 '{"operation":"cluster_set_routes","routes":["wss://harper-2.harper-headless.harper.svc.cluster.local:9933"]}'

# add / remove a full node
hop 0 '{"operation":"add_node","hostname":"harper-3.harper-headless.harper.svc.cluster.local","verify_tls":false}'
hop 0 '{"operation":"remove_node","hostname":"harper-3.harper-headless.harper.svc.cluster.local"}'
```

---

## 5. Users & roles

```bash
# create a role, then a user with that role
hop svc '{"operation":"add_role","role":"app_readwrite","permission":{"super_user":false}}'
hop svc '{"operation":"add_user","role":"app_readwrite","username":"seer_app","password":"S3cret!","active":true}'
hop svc '{"operation":"list_users"}'
hop svc '{"operation":"list_roles"}'

# verify the new user can authenticate (against the service)
kubectl -n $NS port-forward svc/harper 9925:9925 >/dev/null 2>&1 &
curl -s -u "seer_app:S3cret!" -X POST http://localhost:9925 \
  -H 'Content-Type: application/json' -d '{"operation":"describe_all"}' | jq
```

> A planned Kubernetes operator will manage users and roles declaratively; for
> now, manage them via the Operations API as above.

---

## 6. Runtime configuration

```bash
hop 0 '{"operation":"get_configuration"}'

# change a value at runtime (Harper restarts the relevant subsystem)
hop 0 '{"operation":"set_configuration","logging_level":"debug"}'
```

> Chart-managed config (`HARPER_DEFAULT_CONFIG`) is re-applied on pod restart, so
> ad-hoc `set_configuration` changes are good for experiments but will revert on
> the next roll. For permanent changes, edit `values.yaml`.

---

## 7. The REST interface (port 9926)

When you define resources/tables, Harper auto-generates REST endpoints. Expose
9926 and use plain HTTP verbs:

```bash
kubectl -n $NS port-forward svc/harper 9926:9926 >/dev/null 2>&1 &

# GET a record by primary key
curl -s -u "$HUSER:$HPASS" http://localhost:9926/dev/dog/1 | jq
# PUT (upsert) a record
curl -s -u "$HUSER:$HPASS" -X PUT http://localhost:9926/dev/dog/4 \
  -H 'Content-Type: application/json' -d '{"name":"Bolt","age":2}'
# query with a filter
curl -s -u "$HUSER:$HPASS" "http://localhost:9926/dev/dog/?age=gt=3" | jq
```

---

## 8. Health & monitoring

```bash
hop 0 '{"operation":"system_information"}'   # CPU, memory, disk, threads, version
hop 0 '{"operation":"registration_info"}'    # license / edition
# analytics (if enabled): recent metrics aggregated per analytics.aggregatePeriod
hop 0 '{"operation":"get_analytics","metric":"database-size"}'
```

Standard k8s health checks:

```bash
kubectl -n $NS get pods -o wide
kubectl -n $NS top pods 2>/dev/null || echo "(metrics-server not installed)"
kubectl -n $NS logs harper-0 --tail=50
```

---

## 9. A quick load / scale smoke test

Insert a batch and time a query — a cheap proxy for bulk-ingest and query
performance:

```bash
# generate 5,000 records and bulk insert them
python3 - <<'PY' > /tmp/batch.json
import json
recs=[{"id":i,"name":f"dog{i}","age":i%15,"tags":[{"k":"v","n":i}]} for i in range(5000)]
print(json.dumps({"operation":"insert","database":"dev","table":"dog","records":recs}))
PY
./scripts/harper-op.sh svc "$(cat /tmp/batch.json)"

# time an aggregate query
time ./scripts/harper-op.sh svc '{"operation":"sql","sql":"SELECT age, count(*) FROM dev.dog GROUP BY age"}'
```

For larger/CSV loads use `csv_data_load` / `csv_url_load` (see the Operations API
reference). On Apple Silicon remember the image is emulated, so latency numbers
here are **not** representative — run perf tests on an amd64 cluster.

---

## Cheat sheet

```bash
hop()  { ./scripts/harper-op.sh "$1" "$2" | jq; }
hop svc '{"operation":"describe_all"}'                 # what's there
hop 0   '{"operation":"cluster_status"}'               # mesh health from node 0
hop 1   '{"operation":"sql","sql":"SELECT 1"}'         # run SQL on node 1
hop svc '{"operation":"list_users"}'                   # users
hop 0   '{"operation":"system_information"}'           # node health
```
