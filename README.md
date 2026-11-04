# Bernstein

Deployment process of the Poll application, from its sources to a Kubernetes cluster:
build the images, push them to a private registry and deploy them with no-downtime updates.
This file says how; the reasons behind each choice are indexed in
[docs/technical-choices.md](docs/technical-choices.md).

Everything runs in the `bernstein` namespace:

| Workload   | Image                                 | Kubernetes resources                            | Replicas | Reachable from        |
| ---------- | ------------------------------------- | ----------------------------------------------- | -------- | --------------------- |
| Poll       | built from `poll-application/poll`    | `Deployment`, `LoadBalancer` Service, PDB, HPA  | 2 to 4   | the Internet, port 80 |
| Result     | built from `poll-application/result`  | `Deployment`, `LoadBalancer` Service, PDB, HPA  | 2 to 4   | the Internet, port 80 |
| Worker     | built from `poll-application/worker`  | `Deployment`, PDB                               | 2        | nowhere (no Service)  |
| Redis      | `redis:8.2-alpine`                    | `Deployment`, `ClusterIP` Service               | 1        | the cluster, port 6379 |
| PostgreSQL | `postgres:18`                         | `StatefulSet`, headless Service, PVC            | 1        | the cluster, port 5432 |

## Quick start (deploy from scratch on your own cluster)

Prerequisites: the tools of [Requirements](#requirements), and an AKS cluster (see
[Create the infrastructure](#create-the-infrastructure) to create one). `make registry` creates
the private registry it needs. The cluster needs:

- **x86_64 (`amd64`) nodes**: the images are built for `linux/amd64`, an ARM node pool cannot run
  them.
- **Kubernetes 1.27 or later** (`matchLabelKeys`): every supported AKS version qualifies. The
  default AKS StorageClass and `LoadBalancer` Services are used as is.
- **Room for the application**: up to 650m of CPU and 1.3Gi of memory requested, with the
  autoscalers at their maximum (see [Sizing](docs/records/sizing.md)).

```sh
git clone https://github.com/Holo-Org/Bernstein.git bernstein && cd bernstein
az login                                    # your Azure account (see Credentials and secrets)
az account set --subscription <subscription-id>
cp .env.example .env                        # choose ACR_NAME, REDIS_PASSWORD and POSTGRES_PASSWORD
export AKS_RESOURCE_GROUP=<your-resource-group> AKS_CLUSTER=<your-cluster>
make credentials                            # or `make start` if the cluster is stopped
make registry                               # create the registry and attach it to the cluster
make all                                    # build and push the images, then deploy
make addresses                              # poll: http://<ip>, result: http://<ip>
```

- **The Makefile defaults to our cluster** (`bernstein-rg` / `bernstein-aks`): export
  `AKS_RESOURCE_GROUP` and `AKS_CLUSTER` (or pass them to each command) for the targets that use
  Azure (`start`, `stop`, `credentials`, `registry`, `status`), or they fail on a resource group
  you cannot access. `make build-push`, `make deploy` and `make all` need no cluster name: they
  use the registry of `.env` (or the only one of the subscription) and the current `kubectl`
  context.
- If the cluster uses Microsoft Entra ID authentication, `kubectl` also needs `kubelogin`
  (`az aks install-cli`, then `kubelogin convert-kubeconfig -l azurecli`).
- If the cluster is stopped, run `make start` instead of `make credentials`: it starts the
  cluster, then fetches its credentials.
- `ACR_NAME` must be globally unique if `make registry` creates the registry. It can stay empty
  when the subscription has exactly one registry, which is then used. Attaching the registry
  needs `Owner` on it (see [Requirements](#requirements)); skip `make registry` if the cluster is
  already attached to one.
- The first deployment takes a few minutes: Azure creates the disk of PostgreSQL and the public
  IPs of poll and result. `make all` waits for every rollout, then prints the addresses.
- To check a no-downtime update: `make watch` in a terminal, change the sources of poll or
  result, then `make all` in another one (see [No-downtime update](#no-downtime-update-scriptswatchsh)).

## Infrastructure

- **Azure** (Azure for Students), region `denmarkeast`, resource group `bernstein-rg`.
- **Registry**: Azure Container Registry `bernsteindcacr` (Basic), private.
- **Cluster**: AKS `bernstein-aks` (Free tier, 2 × `Standard_B2s_v2`), attached to the registry
  with the `AcrPull` role, so the nodes pull the images without any pull secret.

More in [Infrastructure](docs/records/infrastructure.md).

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
az aks maintenanceconfiguration add --resource-group bernstein-rg --cluster-name bernstein-aks \
  --name aksManagedNodeOSUpgradeSchedule --schedule-type Weekly --day-of-week Sunday \
  --interval-weeks 1 --duration 4 --utc-offset +01:00 --start-time 02:00
```

`--attach-acr` gives the cluster nodes the `AcrPull` role on the registry. To check it, or to
restore it on an existing cluster:

```sh
az aks check-acr --resource-group bernstein-rg --name bernstein-aks --acr <registry>.azurecr.io
az aks update --resource-group bernstein-rg --name bernstein-aks --attach-acr <registry>
```

## Requirements

- `az` (Azure CLI), logged in, `kubectl`, `docker` with BuildKit (`docker buildx`), `make`,
  `bash` 4+, `curl` and GNU coreutils (`sha256sum`, `timeout`; `brew install coreutils` on
  macOS). On an ARM machine, building the `linux/amd64` images also needs QEMU emulation
  (included in Docker Desktop).
- An AKS cluster. `make registry` creates the registry if needed and attaches it to the cluster.
- **Azure permissions**: `Contributor` on the resource group of the cluster and the registry
  (to create the registry, push the images, fetch the cluster credentials, start and stop the
  cluster). Attaching the registry to the cluster (`make registry`) creates a role assignment,
  so it also needs `Owner` (or `User Access Administrator`) on the registry.

## Credentials and secrets

Nothing secret is committed. Two kinds of credentials are needed:

1. **Azure credentials**: they are those of the Azure CLI. Log in once with `az login`
   (or `az login --service-principal ...` in a CI), and select the subscription with
   `az account set --subscription <id>`. The scripts use them to push to the registry and
   to fetch the cluster credentials. There are no separate Kubernetes credentials to set:
   `make credentials` (or `make start`) writes them in `~/.kube/config` with
   `az aks get-credentials`, from the Azure login.
2. **Application secrets**: read from the environment, or from a `.env` file at the root of
   the repository (ignored by `.gitignore`). Variables already set in the environment take
   precedence.

   ```sh
   cp .env.example .env   # then fill it in
   ```

   | Variable         | Required | Description                                                            |
   | ---------------- | -------- | ---------------------------------------------------------------------- |
   | `ACR_NAME`       | no       | Registry name (without `.azurecr.io`). Detected if the subscription has only one. |
   | `REDIS_PASSWORD` | yes      | Password of the Redis queue, stored in the `redis` Kubernetes Secret.  |
   | `POSTGRES_PASSWORD` | yes   | Password of the PostgreSQL database, stored in the `postgres` Kubernetes Secret. |

   The deploy script creates the Kubernetes Secrets from these variables, so the passwords are
   neither committed nor in the manifests.

   `POSTGRES_PASSWORD` is only applied when the database is created (first start on an empty
   volume). To change it afterwards, also run `ALTER USER poll PASSWORD '...'` in the database.

   **To redeploy an existing installation**, reuse its passwords: a new `POSTGRES_PASSWORD`
   breaks the worker and result. With access to the cluster, create `.env` from the Secrets
   instead (the passwords are neither printed nor put on a command line):

   ```sh
   grep -v '_PASSWORD=' .env.example > .env
   for name in redis postgres; do
     printf '%s_PASSWORD=%s\n' "$(echo "$name" | tr a-z A-Z)" \
       "$(kubectl get secret "$name" --namespace bernstein -o jsonpath='{.data.password}' | base64 -d)" >> .env
   done
   ```

## Deployment

```sh
make start        # start the cluster (if stopped) and point kubectl to it
make all          # build and push the images, then deploy
make addresses    # show the external addresses
```

The cluster defaults to ours; for another one, pass its name to every Azure target, e.g.
`make start AKS_RESOURCE_GROUP=<rg> AKS_CLUSTER=<name>`. `deploy.sh` itself targets the current
`kubectl` context. Starting a stopped cluster takes about 5 minutes: `make start` then waits until
the API server answers reliably (its DNS name only resolves some of the time for a few minutes)
and every node is ready, and spreads the pods over the nodes again.

| Target       | Description                                                        |
| ------------ | ------------------------------------------------------------------ |
| `start`      | Start the AKS cluster and fetch its kubectl credentials            |
| `stop`       | Stop the AKS cluster, to save the cost of its nodes                |
| `credentials`| Point kubectl to the AKS cluster                                   |
| `registry`   | Create the registry (if missing) and attach it to the cluster      |
| `status`     | Show the cluster power state, the application pods and autoscalers |
| `build-push` | Build and push the images (`SERVICES="poll worker"` for a subset)  |
| `deploy`     | Deploy the application to the cluster                              |
| `all`        | `build-push` then `deploy`                                         |
| `addresses`  | Show the external addresses of the application                     |
| `watch`      | Request the pages continuously and count the errors                |
| `load`       | Load the pages to make the autoscalers add replicas                |
| `rebalance`  | Spread the replicas over the nodes again (run by `start`)          |

### Build and push (`scripts/build-push.sh`)

- Each image is tagged with a hash of its sources: the same sources always give the same tag,
  and an image already in the registry is not rebuilt (`FORCE=1` to override).
- `FORCE=1` rebuilds and pushes the same tag again: nodes that already have the image keep their
  cached copy (`imagePullPolicy: IfNotPresent`, the default for a fixed tag). It is only meant
  to show the build: the sources, hence the content, are the same.
- Images are built for `linux/amd64` (the node architecture), whatever the local machine.
- Older tags stay in the registry (a rollback only needs `kubectl rollout undo`). To list them,
  and delete one that no pod uses (the index, its image and its attestation go together):

  ```sh
  az acr manifest list-metadata --registry <registry> --name poll -o table
  az acr repository delete --name <registry> --image poll:<tag>
  ```

### Deploy (`scripts/deploy.sh`)

1. Checks that the cluster is reachable and that every image is in the registry, before
   touching anything.
2. Applies the namespace and creates or updates the Secrets.
3. Applies the manifests of `k8s/` (Kustomize) through a temporary overlay that points each
   image to the registry with the tag of its current sources. Only the services whose sources
   changed get a new tag, so only they are rolled out.
   The overlay also generates the `postgres-schema` ConfigMap from a copy of
   `poll-application/schema.sql`, as Kustomize only loads the files below the kustomization that
   names them (to render everything else by hand: `kubectl kustomize k8s`).
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

### Autoscaling (`scripts/load.sh`)

To see it work, run `kubectl get hpa,pods --namespace bernstein --watch` in a terminal, then
`make load` in another one (`DURATION` seconds, 180 by default, with `CONCURRENCY` requests at
a time per page, 20 by default). `scripts/load.sh` uses a single `curl` per page with parallel,
reused connections, so it needs no load-testing tool.

### Drain a node

```sh
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>
make rebalance
```

Both flags are needed: AKS runs DaemonSets on every node, and Poll, Redis and PostgreSQL use
`emptyDir` volumes, whose content is disposable. Without them, the drain refuses to start and
leaves the node cordoned, so `kubectl uncordon <node>` is needed either way. `make rebalance` then
spreads the replicas again, as nothing moves a running pod. See
[Failure modes](docs/records/failure-modes.md).

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `make credentials` or `make start` fails with `ResourceGroupNotFound` or `AuthorizationFailed` | The Makefile defaults to our cluster: pass `AKS_RESOURCE_GROUP` and `AKS_CLUSTER`. |
| `kubectl` or `make deploy` fails with `no such host` on the API server | The cluster is stopped (`make start`), or has just started: its DNS name only resolves some of the time for a few minutes. `make start` waits for it (`scripts/rebalance.sh`); otherwise wait and retry. |
| `error: REDIS_PASSWORD is not set` (or `POSTGRES_PASSWORD`) | Create `.env` from `.env.example`, or export the variable. |
| `error: <service>:<tag> is not in the registry` | Run `make build-push` (or `make all`) first. |
| `make deploy` reports `statefulset.apps/postgres` and the `poddisruptionbudget`s as `configured` although nothing changed | Harmless: client-side `kubectl apply` compares with the fields the API server fills in by default. Nothing is updated nor restarted (the `generation` of the objects does not change). |
| `error: ACR_NAME is not set and the subscription has N registries` | Set `ACR_NAME` in `.env`, then run `make registry` if it does not exist yet. |
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
.gitignore                ignores .env and the temporary overlay of deploy.sh
CONTEXT.md                glossary
scripts/
  lib.sh                  shared helpers (.env loading, registry name, image tags)
  registry.sh             create the registry and attach it to the cluster
  build-push.sh           build and push the images to the registry
  deploy.sh               create the Secrets and apply the manifests
  watch.sh                request the pages continuously during an update
  load.sh                 load the pages to make the autoscalers add replicas
  rebalance.sh            spread the replicas over the nodes again (after a start)
k8s/                      Kustomize manifests, namespace `bernstein`, one directory per component
  kustomization.yaml      namespace, common label, list of the components
  namespace.yaml
  poll/ redis/ worker/ result/ postgres/
poll-application/         sources of the application (provided), with schema.sql
assets/                   original archive of the application sources (provided)
docs/
  technical-choices.md    index of the decisions and records
  adr/                    one file per decision
  records/                requirements, failure modes, sizing, measurements, security, infrastructure
  subject/                the project subject
.github/workflows/        mirrors the repository (destination in the MIRROR_URL variable)
```

## Cost management

Stop the cluster when it is not used: `make stop` (and `make start` to resume). This saves the
compute; what stays allocated keeps costing (see [Infrastructure](docs/records/infrastructure.md#costs)).
