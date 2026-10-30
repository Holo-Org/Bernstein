# Technical choices

The decisions behind the deployment, and the ones we deliberately did not make.
The README describes how to deploy; this document explains why it is done this way.

Status: all the components (Poll, Redis, worker, PostgreSQL, Result) are deployed.

## 1. Azure infrastructure

| Choice | Why |
|---|---|
| AKS (managed Kubernetes) and ACR (managed registry) | Recommended by the subject, and covered by the Azure for Students credits. Azure runs the control plane and the registry: nothing to install or maintain ourselves. |
| Region `denmarkeast` | The subscription policy only allows 5 regions, and this is the only one offering B-series VMs for AKS. |
| AKS Free tier | No cost for the control plane. The trade-off is no SLA, acceptable for this project. |
| 2 × `Standard_B2s_v2` nodes, `maxSurge: 1` | The quota is 6 vCPUs per region. During an AKS upgrade, 2 nodes plus 1 surge node use 6 vCPUs; 3 nodes would need 8 and the upgrade would fail. 2 nodes are enough to spread the replicas. |
| ACR Basic, private, attached to the cluster with `AcrPull` | The nodes pull the images with their managed identity: no registry password and no image pull Secret to manage. |
| `make start` and `make stop` | Cost management: the cluster is stopped whenever it is not used. |

## 2. Building and pushing the images

| Choice | Why |
|---|---|
| Image tag = hash of the service sources | Immutable and reproducible: the same sources always give the same tag. Only a service whose sources changed gets a new tag, so only that one is rolled out. `latest` is avoided: it is ambiguous and does not trigger a rollout. |
| An image already in the registry is not rebuilt | Faster builds and deployments; `FORCE=1` forces a rebuild. |
| Built for `linux/amd64` | The node architecture, whatever the machine running the build. |
| `deploy.sh` checks before touching the cluster | It checks that the cluster answers and that every image is in the registry, rather than leaving pods stuck in `ImagePullBackOff`. |

## 3. Deployment method

| Choice | Why |
|---|---|
| Kustomize rather than Helm | No templating needed, built into `kubectl`, and the manifests stay plain, readable Kubernetes YAML. |
| Temporary overlay for the images | The committed manifests never change: the script injects the registry and the tag. |
| `kubectl apply`, declarative and idempotent | The same script handles the initial deployment and the updates. |
| The script waits for the rollouts | It only ends once the deployment is actually ready. |
| A `bernstein` namespace | The application is isolated from the rest of the cluster and easy to remove. |
| Secrets read from the environment or `.env`, passed to `kubectl` through stdin | The subject forbids delivering `POSTGRES_PASSWORD`. Passwords appear neither in git, nor in the manifests, nor on a command line; the README says where to set them. |
| `--load-restrictor LoadRestrictionsNone` | Reads `schema.sql` straight from the application sources, rather than keeping a copy that could drift. |

## 4. Poll

| Choice | Why |
|---|---|
| 2 replicas spread over the nodes | Poll stays available when a node is lost or drained. |
| `RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1` | **No-downtime updates**: a new pod must be ready before an old one is removed. |
| Readiness probe on `/readyz`, which checks Redis | A pod only receives traffic when it can actually record a vote. |
| `preStop: sleep 5` | A terminating pod keeps serving while the load balancer stops sending it traffic. Without it, a few requests would fail during an update. |
| PDB `minAvailable: 1` | A `kubectl drain` cannot stop both replicas at once. |
| `LoadBalancer` Service rather than an Ingress | The simplest option: one public IP per exposed application, no extra controller to install. |
| Threaded gunicorn workers (`GUNICORN_CMD_ARGS="--workers 2 --threads 4"`) | The image runs one synchronous worker, blocked by any connection that does not send its request at once (Azure load balancer TCP probes, scanners, browser preconnects). The probes then timed out and restarted the pods. Measured: up to 5 s on `/healthz` before, at most 11 ms after. Set through the environment, so the application sources stay untouched. |

## 5. Result

| Choice | Why |
|---|---|
| 2 replicas spread over the nodes, `RollingUpdate` (`maxUnavailable: 0`, `maxSurge: 1`), readiness on `/readyz`, `preStop` delay, PDB | Same no-downtime setup as Poll. `/readyz` checks PostgreSQL. |
| `sessionAffinity: ClientIP` on the `LoadBalancer` Service | The browser uses Socket.IO with HTTP long-polling only: each request carries a session id known by a single pod. AKS turns the setting into a `SourceIP` rule on the Azure load balancer, and kube-proxy keeps each client IP on the same pod. Measured: without it, 26 of 45 polling requests were rejected (`Session ID unknown`); with it, none. |
| `externalTrafficPolicy: Cluster` (the default) | With `Local`, a node left without a ready result pod during a rollout would keep receiving traffic until the Azure probe marks it down. |
| `terminationGracePeriodSeconds: 15` | node runs as PID 1 without a SIGTERM handler: it ignores SIGTERM and is only stopped by the final SIGKILL. A short period keeps rollouts fast; the pod has already left the load balancer by then. |
| Image's `node` user (uid 1000) | A dedicated unprivileged user, without extra groups. |

## 6. Redis

| Choice | Why |
|---|---|
| 1 replica, `Recreate` strategy | Two Redis pods at once would be two separate queues, and some votes would go to the one nobody reads. |
| No persistence | Redis is only a transit queue, emptied continuously by the worker. **Accepted consequence**: the votes waiting in the queue are lost if Redis restarts. |
| Password (`requirepass`) and `REDISCLI_AUTH` for the probes | Authenticated access, and the password never appears on a command line. |
| `ClusterIP` Service | Redis is only reachable from inside the cluster. |

## 7. PostgreSQL

| Choice | Why |
|---|---|
| `StatefulSet` rather than `Deployment` | A stable identity (`postgres-0`) and its own disk. There are never two pods for the same disk, whereas a Deployment could start the new pod before the old one has released it. |
| A single replica | PostgreSQL has no built-in multi-writer replication. High availability would need an operator, out of proportion here. |
| 1 GiB PVC, kept (`Retain`) | The subject requires persistent votes. The disk survives the deletion of the pod and of the StatefulSet. |
| Volume mounted on `/var/lib/postgresql` | The new layout of the `postgres:18` image (`PGDATA` is `/var/lib/postgresql/18/docker`). |
| `schema.sql` applied on startup, from a ConfigMap mounted in `/docker-entrypoint-initdb.d` | The schema is applied automatically, once, when the database is created. This ConfigMap has no hash suffix, so changing the schema does not restart the database for nothing. |
| `postgres` ConfigMap shared with the worker and result | A single source for the connection settings. Its name has a content hash, so changing a value rolls out the pods that use it. |
| `pg_isready` probes over TCP | During the first initialization, the image runs a temporary server that only listens on a local socket: it must not be seen as ready. |
| No PodDisruptionBudget | With one replica, `minAvailable: 1` would block every drain and every AKS upgrade. |
| An update means a short interruption | Voting is not affected, and the worker puts the current vote back in Redis. The result page is unavailable for a few seconds. |
| Draining a node | The Azure disk is detached, then attached to the node where the pod restarts. The node pool has no availability zones, so the disk can follow the pod to any node. |

What happens to the data:

| Action | Result |
|---|---|
| Delete the pod | The StatefulSet recreates `postgres-0` with the same PVC: data kept. |
| Delete the StatefulSet | The PVC is kept (`Retain`) and reused on the next deployment. |
| Delete the namespace or the PVC | The disk is deleted (`reclaimPolicy: Delete` of the `default` StorageClass): **data lost**. |
| `kubectl drain` the node | The pod is evicted, the disk is detached and attached elsewhere: data kept, short interruption. |

## 8. Worker

| Choice | Why |
|---|---|
| 2 replicas spread over the nodes, with a PDB | Several workers can pop the same Redis list without duplicates (`BLPOP` hands each vote to a single worker). Votes keep being processed during a drain. |
| No Service | The worker receives no traffic: its port 80 only serves the probes. |
| `maxUnavailable: 0` and readiness on `/readyz` | An old worker is only stopped once the new one is connected to Redis and PostgreSQL. |
| Liveness on `/readyz` rather than `/healthz` | Observed in tests: the worker never reconnects to PostgreSQL by itself. The probe restarts it, and it reconnects as soon as the database is back. Harmless, since on startup it waits for its dependencies. |
| uid 10001, not the image's `ubuntu` user | The `ubuntu` user (uid 1000) belongs to the sudo and adm groups. |
| Known limit | A vote is lost if the worker is killed between taking it from Redis and writing it, a window of a few milliseconds. The application has no acknowledgement mechanism. |

## 9. Security (all containers)

| Choice | Why |
|---|---|
| Non-root, all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp | A compromised container can do as little as possible. |
| Read-only root filesystem | Only explicitly declared volumes are writable (PostgreSQL data and socket, gunicorn's `/tmp`). |
| Sysctl `net.ipv4.ip_unprivileged_port_start=0` | The applications listen on port 80 without root and without the `NET_BIND_SERVICE` capability. |
| Requests and limits everywhere | Predictable scheduling, and no pod can starve the others. It is also how the CPU of Redis is limited. |

## 10. What we chose not to do

| Not done | Why |
|---|---|
| Ingress and TLS | Two public IPs are enough for the subject; an Ingress controller would be one more component to run. |
| Horizontal Pod Autoscaler | Low load and a tight vCPU quota. It can be added if needed. |
| Redis persistence | Redis is a transit queue (see above). |
| PostgreSQL high availability | An operator or a managed service (Azure Database for PostgreSQL) would be the production answer, but it is out of proportion here and costs credits. |
| Helm, CI/CD | The scripts and Kustomize are enough: clone the repository, fill in `.env`, run `make all`. |
| NetworkPolicies, monitoring | Not done yet. |
| Availability zones | Not enabled on the node pool, which is also what lets the PostgreSQL disk follow its pod to any node. |

## What happens if...

| Event | Effect |
|---|---|
| A node is drained | Poll, result and the worker keep one replica on the other node (PDBs). Redis restarts on the other node (queued votes lost). PostgreSQL restarts there with its disk (short interruption, data kept). |
| A node is lost | Same as a drain, without the PDBs' protection: the pods are rescheduled once Kubernetes declares the node down (about 5 minutes, the default `not-ready`/`unreachable` toleration). |
| Redis restarts | Poll is not ready until Redis is back; the votes waiting in the queue are lost. |
| PostgreSQL restarts | Votes wait in Redis; the workers restart and reconnect; the result page is briefly unavailable. |
| Poll's or result's sources change and `make all` runs | Only that service gets a new tag and is rolled out, one pod at a time. Measured during a rollout of both: 898 requests, 0 errors. |
