# Bernstein

Deployment process of the Poll application, from its sources to a Kubernetes cluster:
build the images, push them to a private registry and deploy them with no-downtime updates.
The reasons behind each choice are in [docs/technical-choices.md](docs/technical-choices.md).

| Component | Source                    | Image                     | Status       |
| --------- | ------------------------- | ------------------------- | ------------ |
| Poll      | `poll-application/poll`   | built, pushed to ACR      | deployed     |
| Redis     | -                         | `redis:8.2-alpine`        | deployed     |
| Worker    | `poll-application/worker` | built, pushed to ACR      | deployed     |
| Result    | `poll-application/result` | built, pushed to ACR      | deployed     |
| PostgreSQL| -                         | `postgres:18`             | deployed     |

## Quick start (deploy from scratch on your own cluster)

Prerequisites: the tools of [Requirements](#requirements), and an AKS cluster attached to an Azure
Container Registry (see [Create the infrastructure](#create-the-infrastructure) to create them).

```sh
git clone <this repository> && cd bernstein
az login                                    # your Azure account (see Credentials and secrets)
az account set --subscription <subscription-id>
cp .env.example .env                        # choose REDIS_PASSWORD and POSTGRES_PASSWORD
make credentials AKS_RESOURCE_GROUP=<your-resource-group> AKS_CLUSTER=<your-cluster>
make all                                    # build and push the images, then deploy
make addresses                              # poll: http://<ip>, result: http://<ip>
```

- **The Makefile defaults to our cluster** (`bernstein-rg` / `bernstein-aks`): always pass
  `AKS_RESOURCE_GROUP` and `AKS_CLUSTER` to the targets that use Azure (`start`, `stop`,
  `credentials`, `status`), or `make credentials` fails on a resource group you cannot access.
  `make build-push`, `make deploy` and `make all` need no cluster name: they use the registry
  of `.env` (or the only one of the subscription) and the current `kubectl` context.
- If the subscription has several registries, also set `ACR_NAME` in `.env`.
- The first deployment takes a few minutes: Azure creates the disk of PostgreSQL and the public
  IPs of poll and result. `make all` waits for every rollout, then prints the addresses.
- To check a no-downtime update: `make watch` in a terminal, change the sources of poll or
  result, then `make all` in another one (see [No-downtime update](#no-downtime-update-scriptswatchsh)).

## Infrastructure

- **Azure** (Azure for Students), region `denmarkeast`, resource group `bernstein-rg`.
- **Registry**: Azure Container Registry `bernsteindcacr` (Basic), private.
- **Cluster**: AKS `bernstein-aks` (Free tier, 2 × `Standard_B2s_v2`), attached to the registry
  with the `AcrPull` role, so the nodes pull the images without any pull secret.

### Why 2 nodes, and how cluster upgrades work

The subscription allows 6 vCPUs in the region, and a `Standard_B2s_v2` node has 2.
A system node pool must keep `maxUnavailable: 0`, so an AKS upgrade (Kubernetes version or
node image) always adds a temporary surge node: the pool uses `maxSurge: 1`.

- With 2 nodes, an upgrade peaks at 3 nodes (6 vCPUs), within the quota. The surge node is
  ready **before** an old node is drained, so 2 schedulable nodes remain at all times.
- With 3 nodes, the surge node would need 8 vCPUs and the upgrade would fail on the quota.
  A third node therefore requires a quota increase.

During a drain, the 2 Poll, Worker and Result replicas (one per node) and their
`PodDisruptionBudget`s keep the application available.

### Create the infrastructure

Equivalent commands for our setup (the registry name must be globally unique):

```sh
az group create --name bernstein-rg --location denmarkeast
az acr create --resource-group bernstein-rg --name <registry> --sku Basic
az aks create --resource-group bernstein-rg --name bernstein-aks --tier free \
  --node-count 2 --node-vm-size Standard_B2s_v2 \
  --network-plugin azure --network-plugin-mode overlay \
  --node-os-upgrade-channel NodeImage \
  --attach-acr <registry> --generate-ssh-keys
az aks nodepool update --resource-group bernstein-rg --cluster-name bernstein-aks \
  --name nodepool1 --max-surge 1
```

`--attach-acr` gives the cluster nodes the `AcrPull` role on the registry. To check it, or to
restore it on an existing cluster:

```sh
az aks check-acr --resource-group bernstein-rg --name bernstein-aks --acr <registry>.azurecr.io
az aks update --resource-group bernstein-rg --name bernstein-aks --attach-acr <registry>
```

## Requirements

- `az` (Azure CLI), logged in, `kubectl`, `docker`, `make`, `bash` 4+ and `curl`.
- An AKS cluster attached to an ACR (`az aks update --attach-acr <acr>`).
- **Azure permissions**: `Contributor` on the resource group of the cluster and the registry
  (to push the images, fetch the cluster credentials, start and stop the cluster). Attaching
  the registry to the cluster (`--attach-acr`) creates a role assignment, so it also needs
  `Owner` (or `User Access Administrator`) on the registry.

## Credentials and secrets

Nothing secret is committed. Two kinds of credentials are needed:

1. **Azure credentials**: they are those of the Azure CLI. Log in once with `az login`
   (or `az login --service-principal ...` in a CI), and select the subscription with
   `az account set --subscription <id>`. The scripts use them to push to the registry and
   to fetch the cluster credentials. There are no separate Kubernetes credentials to set:
   `make credentials` (or `make start`) writes them in `~/.kube/config` with
   `az aks get-credentials`, from the Azure login.
2. **Application secrets**: read from the environment, or from a `.env` file at the root of
   the repository (ignored by git). Variables already set in the environment take precedence.

   ```sh
   cp .env.example .env   # then fill it in
   ```

   | Variable         | Required | Description                                                            |
   | ---------------- | -------- | ---------------------------------------------------------------------- |
   | `ACR_NAME`       | no       | Registry name (without `.azurecr.io`). Detected if the subscription has only one. |
   | `REDIS_PASSWORD` | yes      | Password of the Redis queue, stored in the `redis` Kubernetes Secret.  |
   | `POSTGRES_PASSWORD` | yes   | Password of the PostgreSQL database, stored in the `postgres` Kubernetes Secret. |

   The deploy script creates the Kubernetes Secrets from these variables: passwords never
   appear in the manifests nor on a command line.

   `POSTGRES_PASSWORD` is only applied when the database is created (first start on an empty
   volume). To change it afterwards, also run `ALTER USER poll PASSWORD '...'` in the database.

## Deployment

```sh
make start        # start the cluster (if stopped) and point kubectl to it
make all          # build and push the images, then deploy
make addresses    # show the external addresses
```

The cluster defaults to ours; for another one, pass its name to every Azure target, e.g.
`make start AKS_RESOURCE_GROUP=<rg> AKS_CLUSTER=<name>`. `deploy.sh` itself targets the current
`kubectl` context, and `make start` waits until the cluster runs but the API server name may take
a minute or two to resolve after a start (see [Troubleshooting](#troubleshooting)).

| Target       | Description                                                        |
| ------------ | ------------------------------------------------------------------ |
| `start`      | Start the AKS cluster and fetch its kubectl credentials            |
| `stop`       | Stop the AKS cluster, so it no longer uses credits                 |
| `credentials`| Point kubectl to the AKS cluster                                   |
| `status`     | Show the cluster power state and the application pods              |
| `build-push` | Build and push the images (`SERVICES="poll worker"` for a subset)  |
| `deploy`     | Deploy the application to the cluster                              |
| `all`        | `build-push` then `deploy`                                         |
| `addresses`  | Show the external addresses of the application                     |
| `watch`      | Request the pages continuously and count the errors                |
| `rebalance`  | Spread the replicas over the nodes again (run by `start`)          |

### Build and push (`scripts/build-push.sh`)

- Each image is tagged with a hash of its sources: the same sources always give the same tag,
  and an image already in the registry is not rebuilt (`FORCE=1` to override).
- Images are built for `linux/amd64` (the node architecture), whatever the local machine.

### Deploy (`scripts/deploy.sh`)

1. Checks that the cluster is reachable and that every image is in the registry, before
   touching anything.
2. Applies the namespace and creates or updates the Secrets.
3. Applies the manifests of `k8s/` (Kustomize) through a temporary overlay that points each
   image to the registry with the tag of its current sources. Only the services whose sources
   changed get a new tag, so only they are rolled out.
   The build uses `--load-restrictor LoadRestrictionsNone`, because `k8s/postgres` reads
   `poll-application/schema.sql` outside its directory (to render the manifests by hand:
   `kubectl kustomize --load-restrictor LoadRestrictionsNone k8s`).
4. Waits for the rollouts and prints the external addresses.

### No-downtime update (`scripts/watch.sh`)

To check that an update causes no downtime, run `make watch` in a terminal, then change the
sources of a service and redeploy it in another one:

```sh
make watch                                  # terminal 1: stop it with Ctrl-C
make all                                    # terminal 2, after changing e.g. poll's sources
```

`make watch` requests the external address of every `LoadBalancer` Service (poll and result)
in a loop (about once a second per page from a remote machine, as each request waits for the
previous one), prints each failed request (HTTP error or no answer within 5 s) and a
progress line every 5 seconds. It also prints each new poll pod that serves the page, so the
rollout is visible. On Ctrl-C (or after `DURATION` seconds), it prints the totals and fails if
any request failed. URLs can also be given: `scripts/watch.sh http://<ip>/`.

Measured on AKS while changing poll's sources and running `make all`: 688 requests on poll and
687 on result, 0 errors; the new pods took over within the rollout.

## Kubernetes resources

Everything lives in the `bernstein` namespace (`k8s/`).

### Poll

- `Deployment` with 2 replicas spread over the nodes, exposed by a `LoadBalancer` Service.
- **No-downtime updates**: `RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1`, a
  readiness probe (`/readyz`, which checks Redis) so a pod only receives traffic once ready,
  and a `preStop` delay so a terminating pod keeps serving while the load balancer forgets it.
- A `PodDisruptionBudget` (`minAvailable: 1`) keeps one replica up during a `kubectl drain`.
- Liveness probe on `/healthz`, CPU and memory requests and limits.
- **Threaded gunicorn workers** (`GUNICORN_CMD_ARGS="--workers 2 --threads 4"`): the image runs
  a single synchronous worker, which any connection that does not send its request at once
  (the Azure load balancer TCP probes, scanners, browser preconnects) blocks for seconds. The
  Kubernetes probes then timed out and restarted the pods. Measured: up to 5 s on `/healthz`
  with one sync worker, at most 11 ms with threaded workers.

### Redis

- `Deployment` with 1 replica and the `Recreate` strategy: two Redis pods at once would be
  two separate queues. Exposed inside the cluster only (`ClusterIP`).
- Password protected (`--requirepass`, from the `redis` Secret).
- No persistence: it is only a transit queue, emptied continuously by the worker.

### Result

- `Deployment` with 2 replicas spread over the nodes, exposed by a `LoadBalancer` Service, with
  the same no-downtime setup as Poll: `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`),
  readiness probe on `/readyz` (checks PostgreSQL), `preStop` delay and a `PodDisruptionBudget`.
- **Sticky sessions** (`sessionAffinity: ClientIP`): the browser talks to Socket.IO with HTTP
  long-polling only (`transports: ['polling']`), and each request carries a session id known by
  a single pod. AKS turns this setting into a `SourceIP` distribution on the Azure load balancer
  rule, and kube-proxy keeps each client IP on the same pod. Measured with a Socket.IO polling
  client: without it, 26 of 45 requests were rejected (`Session ID unknown`); with it, none.
- `externalTrafficPolicy` stays `Cluster`: with `Local`, a node left without a ready result pod
  during a rollout would keep receiving traffic until the Azure probe marks it down.
- `terminationGracePeriodSeconds: 15`: node runs as PID 1 without a SIGTERM handler, so it
  ignores SIGTERM and is only stopped by the final SIGKILL. A short period keeps rollouts fast;
  the pod has already left the load balancer by then.
- Configuration from the `postgres` ConfigMap (`envFrom`) and the `postgres` Secret, runs as
  the image's `node` user (uid 1000).

### Worker

- `Deployment` with 2 replicas spread over the nodes. Both pop the same Redis list (`BLPOP`
  hands each vote to a single worker), so votes keep being processed while a node is drained
  or lost. No Service: its port 80 only serves the health endpoints.
- **Updates**: `RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1`. The readiness probe
  (`/readyz`) checks Redis and PostgreSQL, so an old worker is only stopped once the new one is
  connected to both. A `PodDisruptionBudget` (`minAvailable: 1`) keeps one worker during a drain.
- **Liveness on `/readyz`** (not `/healthz`): the worker never reconnects a lost PostgreSQL
  connection, it only exits on the next vote (after putting it back in the queue). The probe
  restarts it after a minute without Redis or PostgreSQL, so it reconnects as soon as they are
  back. A restart is harmless: the worker waits for its dependencies on startup.
- Configuration from the `postgres` ConfigMap (`envFrom`), passwords from the `redis` and
  `postgres` Secrets. Runs as uid 10001 rather than the image's `ubuntu` user (1000), which
  belongs to the sudo and adm groups.
- Limit: a vote popped by a worker that is killed before writing it (a window of a few
  milliseconds) is lost; the application has no acknowledgement mechanism.

### PostgreSQL

- `StatefulSet` with 1 replica, `postgres:18`, exposed inside the cluster only by the headless
  Service `postgres` (port 5432), which resolves to the pod once it is ready.
- **Persistent votes**: a `volumeClaimTemplate` creates a 1 GiB `PersistentVolumeClaim`
  (`data-postgres-0`) on the default AKS StorageClass (`default`, an Azure Standard SSD disk),
  mounted on `/var/lib/postgresql`. Since PostgreSQL 18, the image stores its data in
  `/var/lib/postgresql/18/docker` (`PGDATA`) and the volume is mounted on the parent directory.
- **Schema**: `poll-application/schema.sql` is turned into the `postgres-schema` ConfigMap by
  Kustomize (no copy) and mounted in `/docker-entrypoint-initdb.d`: the image applies it when it
  creates the database, i.e. only on an empty volume.
- **Configuration**: the `postgres` ConfigMap holds the connection settings shared with the
  worker and result (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`); the
  password comes from the `postgres` Secret (key `password`).
- Startup, readiness and liveness probes with `pg_isready` over TCP, CPU and memory requests
  and limits.

Why these choices:

- **StatefulSet rather than Deployment**: it gives the pod a stable identity (`postgres-0`) and
  its own volume, created from the template and reattached to the pod wherever it is
  rescheduled. It never runs two pods for one identity, while a Deployment could start the new
  pod before the old one has released the disk.
- **A single replica**: PostgreSQL has no built-in multi-writer replication; several replicas
  would need an operator (streaming replication, failover), which is out of proportion here.
- **Updates**: `RollingUpdate` on a single replica stops the pod, then starts the new one: the
  database is briefly unavailable (a few seconds). Voting is not affected: poll only talks to
  Redis. On a database error, the worker puts the current vote back at the head of the Redis
  queue and exits; Kubernetes restarts it (also through its liveness probe if no vote comes)
  and it waits for the database, so no vote is lost.
  Result also exits on a connection error and is restarted: the result page is unavailable
  until the database is back. A database update is therefore not a no-downtime update, unlike
  poll and result updates.
- **No PodDisruptionBudget**: with one replica, `minAvailable: 1` would forbid any eviction and
  block `kubectl drain` (and AKS upgrades) forever. The short interruption is accepted instead.

What happens to the data:

| Action                              | Result                                                                                       |
| ----------------------------------- | -------------------------------------------------------------------------------------------- |
| Delete the pod                      | The StatefulSet recreates `postgres-0` with the same PVC: data kept.                        |
| Delete the StatefulSet              | The PVC is kept (`persistentVolumeClaimRetentionPolicy: Retain`) and reused on redeploy.    |
| Delete the namespace or the PVC     | The disk is deleted (`reclaimPolicy: Delete` of the `default` StorageClass): **data lost**.               |
| `kubectl drain` the node            | The pod is evicted, the Azure disk is detached, then attached to the node where the pod restarts: data kept, a short interruption. The node pool has no availability zones, so the disk can follow the pod on any node. |

### Scheduling and affinity

The replicas of poll, result and the worker are spread over the nodes, so that losing or
draining a node keeps every service up. Each of them uses a `topologySpreadConstraint` on
`kubernetes.io/hostname` with `maxSkew: 1`:

- **`whenUnsatisfiable: ScheduleAnyway`** (a preference, not a rule): with 2 nodes,
  `DoNotSchedule` (or a required `podAntiAffinity`) would leave a replica `Pending` during a
  `kubectl drain` or after a node loss, as the other node already runs one; two replicas on the
  same node are better than one. It would also keep the autoscaler from adding replicas.
- **`matchLabelKeys: ["pod-template-hash"]`**: only the pods of the same version are counted.
  Otherwise, during a rollout, the old pods about to be removed attract the new ones to their
  node, and both new pods can end up on the same node.
- **Rebalancing after a start** (`scripts/rebalance.sh`, run by `make start`): the nodes of a
  starting cluster do not become ready at the same time, and every pod is recreated on the
  first one (observed: all 8 pods on one node). Kubernetes never moves a running pod, so the
  script waits for the API server and every node, then restarts (with a no-downtime rollout)
  each Deployment whose replicas share fewer nodes than they could. The Kubernetes
  [descheduler](https://github.com/kubernetes-sigs/descheduler) does this continuously, but it
  is one more component to run on the cluster.

Redis and PostgreSQL have no affinity: a single replica has nothing to spread, and the
PostgreSQL disk can follow its pod to any node (no availability zones). There is no
`nodeAffinity` either: the cluster has a single pool of identical nodes.

### Security

All containers run as non-root, with a read-only root filesystem, no privilege escalation,
all capabilities dropped and the `RuntimeDefault` seccomp profile. The only writable paths are
explicit volumes (e.g. the PostgreSQL data volume and an `emptyDir` for its Unix socket in
`/var/run/postgresql`).

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `make credentials` or `make start` fails with `ResourceGroupNotFound` or `AuthorizationFailed` | The Makefile defaults to our cluster: pass `AKS_RESOURCE_GROUP` and `AKS_CLUSTER`. |
| `kubectl` or `make deploy` fails with `no such host` on the API server | The cluster is stopped (`make start`), or has just started: its DNS name only resolves some of the time for a few minutes. `make start` waits for it (`scripts/rebalance.sh`); otherwise wait and retry. |
| `error: REDIS_PASSWORD is not set` (or `POSTGRES_PASSWORD`) | Create `.env` from `.env.example`, or export the variable. |
| `error: <service>:<tag> is not in the registry` | Run `make build-push` (or `make all`) first. |
| `error: ACR_NAME is not set and the subscription has N registries` | Set `ACR_NAME` in `.env`. |
| `error: the cluster of kubectl context '...' is unreachable` | The cluster is stopped (`make start`) or `kubectl` points to another one (`make credentials`). |
| Pods in `ImagePullBackOff` with `401 Unauthorized` | The cluster lost its `AcrPull` role on the registry: `az aks update --attach-acr <registry>` (see [Create the infrastructure](#create-the-infrastructure)). |
| An address shows `<pending>` | Azure is still creating the public IP: run `make addresses` again a minute later. |
| Worker and result not ready, `password authentication failed` in their logs (`kubectl logs -n bernstein deploy/worker`), after `POSTGRES_PASSWORD` changed | The password is only set when the database is created. Use the original one, or run `ALTER USER poll PASSWORD '...'` in the database (or delete the namespace to start over, which deletes the votes). |

To start over from an empty cluster (this **deletes the votes**, with the PostgreSQL disk):

```sh
kubectl delete namespace bernstein
make deploy
```

## Repository layout

```
Makefile                  entry points (make help)
.env.example              template of the local settings and secrets (.env is never committed)
scripts/
  lib.sh                  shared helpers (.env loading, registry name, image tags)
  build-push.sh           build and push the images to the registry
  deploy.sh               create the Secrets and apply the manifests
  watch.sh                request the pages continuously during an update
  rebalance.sh            spread the replicas over the nodes again (after a start)
k8s/                      Kustomize manifests, namespace `bernstein`, one directory per component
  kustomization.yaml      namespace, common label, list of the components
  namespace.yaml
  poll/ redis/ worker/ result/ postgres/
poll-application/         sources of the application (provided), with schema.sql
assets/                   original archive of the application sources (provided)
docs/
  technical-choices.md    why each choice was made, and what was not done
  subject/                the project subject
.github/workflows/        mirrors the repository (destination in the MIRROR_URL variable)
```

## Cost management

Stop the cluster when it is not used: `make stop` (and `make start` to resume). The vCPU quota
is 6 per region: 2 nodes use 4, which keeps room for the surge node AKS adds during upgrades.
