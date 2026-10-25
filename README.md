# Bernstein

Deployment process of the Poll application, from its sources to a Kubernetes cluster:
build the images, push them to a private registry and deploy them with no-downtime updates.

| Component | Source                    | Image                     | Status       |
| --------- | ------------------------- | ------------------------- | ------------ |
| Poll      | `poll-application/poll`   | built, pushed to ACR      | deployed     |
| Redis     | -                         | `redis:8.2-alpine`        | deployed     |
| Worker    | `poll-application/worker` | built, pushed to ACR      | not deployed yet |
| Result    | `poll-application/result` | built, pushed to ACR      | not deployed yet |
| PostgreSQL| -                         | -                         | not deployed yet |

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

During a drain, the 2 Poll replicas (one per node) and their `PodDisruptionBudget` keep the
application available.

## Requirements

- `az` (Azure CLI), logged in, `kubectl`, `docker`, `make` and `bash` 4+.
- An AKS cluster attached to an ACR (`az aks update --attach-acr <acr>`).

## Credentials and secrets

Nothing secret is committed. Two kinds of credentials are needed:

1. **Azure credentials**: they are those of the Azure CLI. Log in once with `az login`
   (or `az login --service-principal ...` in a CI), and select the subscription with
   `az account set --subscription <id>`. The scripts use them to push to the registry and
   to fetch the cluster credentials.
2. **Application secrets**: read from the environment, or from a `.env` file at the root of
   the repository (ignored by git). Variables already set in the environment take precedence.

   ```sh
   cp .env.example .env   # then fill it in
   ```

   | Variable         | Required | Description                                                            |
   | ---------------- | -------- | ---------------------------------------------------------------------- |
   | `ACR_NAME`       | no       | Registry name (without `.azurecr.io`). Detected if the subscription has only one. |
   | `REDIS_PASSWORD` | yes      | Password of the Redis queue, stored in the `redis` Kubernetes Secret.  |

   The deploy script creates the Kubernetes Secrets from these variables: passwords never
   appear in the manifests nor on a command line.

## Deployment

```sh
make start        # start the cluster (if stopped) and point kubectl to it
make all          # build and push the images, then deploy
make addresses    # show the external addresses
```

The cluster defaults to ours; for another one: `make start AKS_RESOURCE_GROUP=<rg> AKS_CLUSTER=<name>`.
`deploy.sh` itself targets the current `kubectl` context.

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
4. Waits for the rollouts and prints the external addresses.

## Kubernetes resources

Everything lives in the `bernstein` namespace (`k8s/`).

### Poll

- `Deployment` with 2 replicas spread over the nodes, exposed by a `LoadBalancer` Service.
- **No-downtime updates**: `RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1`, a
  readiness probe (`/readyz`, which checks Redis) so a pod only receives traffic once ready,
  and a `preStop` delay so a terminating pod keeps serving while the load balancer forgets it.
- A `PodDisruptionBudget` (`minAvailable: 1`) keeps one replica up during a `kubectl drain`.
- Liveness probe on `/healthz`, CPU and memory requests and limits.

### Redis

- `Deployment` with 1 replica and the `Recreate` strategy: two Redis pods at once would be
  two separate queues. Exposed inside the cluster only (`ClusterIP`).
- Password protected (`--requirepass`, from the `redis` Secret).
- No persistence: it is only a transit queue, emptied continuously by the worker.

### Security

All containers run as non-root, with a read-only root filesystem, no privilege escalation,
all capabilities dropped and the `RuntimeDefault` seccomp profile.

## Cost management

Stop the cluster when it is not used: `make stop` (and `make start` to resume). The vCPU quota
is 6 per region: 2 nodes use 4, which keeps room for the surge node AKS adds during upgrades.
