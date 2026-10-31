# Technical choices

The decisions behind the deployment, and the ones we deliberately did not make.
The README describes how to deploy; this document explains why it is done this way.
Its sections follow the evaluation criteria of the project:

| Criterion | Section |
|---|---|
| Application working | [1. Application](#1-application) |
| Persistent data | [2. Persistent data](#2-persistent-data) |
| Private Docker registry | [3. Private registry](#3-private-registry) |
| No-downtime update | [4. No-downtime update](#4-no-downtime-update) |
| Replicas | [5. Replicas](#5-replicas) |
| Restart policies | [6. Restart policies](#6-restart-policies) |
| Resource limits | [7. Resource requests and limits](#7-resource-requests-and-limits) |
| Exposed ports | [8. Exposed ports](#8-exposed-ports) |
| Affinity policies | [9. Scheduling and affinity](#9-scheduling-and-affinity) |
| Number of nodes | [10. Number of nodes](#10-number-of-nodes) |
| Probes | [11. Probes](#11-probes) |
| Load balancers | [12. Load balancers](#12-load-balancers) |
| Auto-scaling | [13. Auto-scaling](#13-auto-scaling) |
| Documentation, repository structure | this document, the [README](../README.md), [14. Other choices](#14-other-choices) |

## 1. Application

All the components are deployed in the `bernstein` namespace, from the manifests of `k8s/`
(Kustomize, one directory per component):

| Component | Image | Kubernetes resources | Replicas | Reachable from |
|---|---|---|---|---|
| Poll | built from `poll-application/poll`, pushed to ACR | `Deployment`, `LoadBalancer` Service, PDB, HPA | 2 to 4 | the Internet, port 80 |
| Result | built from `poll-application/result`, pushed to ACR | `Deployment`, `LoadBalancer` Service, PDB, HPA | 2 to 4 | the Internet, port 80 |
| Worker | built from `poll-application/worker`, pushed to ACR | `Deployment`, PDB | 2 | nowhere (no Service) |
| Redis | `redis:8.2-alpine` | `Deployment`, `ClusterIP` Service | 1 | the cluster, port 6379 |
| PostgreSQL | `postgres:18` | `StatefulSet`, headless Service, PVC | 1 | the cluster, port 5432 |

| Choice | Why |
|---|---|
| A `bernstein` namespace | The application is isolated from the rest of the cluster and easy to remove. |
| Secrets read from the environment or `.env`, passed to `kubectl` through stdin | The subject forbids delivering `POSTGRES_PASSWORD`. Passwords appear neither in git, nor in the manifests, nor on a command line; the README says where to set them. |
| `postgres` ConfigMap shared by PostgreSQL, the worker and result | A single source for the connection settings. Its name has a content hash, so changing a value rolls out the pods that use it. |
| Threaded gunicorn workers for poll (`GUNICORN_CMD_ARGS="--workers 2 --threads 4"`) | The image runs one synchronous worker, blocked by any connection that does not send its request at once (Azure load balancer TCP probes, scanners, browser preconnects). The probes then timed out and restarted the pods. Measured: up to 5 s on `/healthz` before, at most 11 ms after. Set through the environment, so the application sources stay untouched. |

## 2. Persistent data

| Choice | Why |
|---|---|
| `StatefulSet` rather than `Deployment` | A stable identity (`postgres-0`) and its own disk. There are never two pods for the same disk, whereas a Deployment could start the new pod before the old one has released it. |
| A single replica | PostgreSQL has no built-in multi-writer replication. High availability would need an operator, out of proportion here. |
| 1 GiB PVC (Azure disk, `default` StorageClass), kept (`persistentVolumeClaimRetentionPolicy: Retain`) | The subject requires persistent votes. The disk survives the deletion of the pod and of the StatefulSet. |
| Volume mounted on `/var/lib/postgresql` | The new layout of the `postgres:18` image (`PGDATA` is `/var/lib/postgresql/18/docker`). |
| `schema.sql` applied on startup, from a ConfigMap mounted in `/docker-entrypoint-initdb.d` | The schema is applied automatically, once, when the database is created. This ConfigMap has no hash suffix, so changing the schema does not restart the database for nothing. |
| `--load-restrictor LoadRestrictionsNone` | Reads `schema.sql` straight from the application sources, rather than keeping a copy that could drift. |
| An update means a short interruption | Voting is not affected (votes wait in Redis, and the worker puts the current vote back). The result page is unavailable for a few seconds. |
| No Redis persistence | Redis is only a transit queue, emptied continuously by the worker: the votes are persisted in PostgreSQL. **Accepted consequence**: the votes waiting in the queue are lost if Redis restarts. |

What happens to the data:

| Action | Result |
|---|---|
| Delete the pod | The StatefulSet recreates `postgres-0` with the same PVC: data kept. |
| Delete the StatefulSet | The PVC is kept (`Retain`) and reused on the next deployment. |
| Delete the namespace or the PVC | The disk is deleted (`reclaimPolicy: Delete` of the `default` StorageClass): **data lost**. |
| `kubectl drain` the node | The pod is evicted, the disk is detached and attached to the node where the pod restarts: data kept, short interruption. The node pool has no availability zones, so the disk can follow the pod to any node. |

## 3. Private registry

| Choice | Why |
|---|---|
| Azure Container Registry (Basic), private | Recommended by the subject and covered by the Azure for Students credits; Azure runs it. |
| Attached to the cluster with `AcrPull` | The nodes pull the images with their managed identity: no registry password and no image pull Secret to manage. |
| Image tag = hash of the service sources | Immutable and reproducible: the same sources always give the same tag. Only a service whose sources changed gets a new tag, so only that one is rolled out. `latest` is avoided: it is ambiguous and does not trigger a rollout. |
| An image already in the registry is not rebuilt | Faster builds and deployments; `FORCE=1` forces a rebuild. |
| Built for `linux/amd64` | The node architecture, whatever the machine running the build. |
| `deploy.sh` checks the registry before touching the cluster | Every image must be in the registry, rather than leaving pods stuck in `ImagePullBackOff`. |
| Temporary Kustomize overlay for the images | The committed manifests never change: the script injects the registry and the tag. |

## 4. No-downtime update

| Choice | Why |
|---|---|
| `RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1` (poll, result, worker) | A new pod must be ready before an old one is removed. |
| Readiness probes on `/readyz` (section 11) | A new pod only receives traffic once it can serve it (poll: Redis answers; result: PostgreSQL answers), and a new worker only replaces an old one once connected to both. |
| `preStop: sleep 5` (poll, result) | A terminating pod keeps serving while the load balancer stops sending it traffic. Without it, a few requests would fail during an update. |
| `kubectl apply`, declarative and idempotent; the script waits for the rollouts | The same script handles the initial deployment and the updates, and only ends once the deployment is actually ready. |
| Only the changed services are rolled out | Their image tag is the hash of their sources (section 3). |
| `make watch` (`scripts/watch.sh`) | Requests both pages in a loop during an update and counts the failures. Measured during real updates: 688 requests on poll and 687 on result, 0 errors; during a rollout of both, 898 requests, 0 errors. |
| Redis (`Recreate`) and PostgreSQL (single replica) | They cannot be updated without a short interruption (sections 5 and 2). Measured when the Redis configuration changed: back within seconds, before poll's readiness probe failed, so no page error. |

## 5. Replicas

| Component | Replicas | Why |
|---|---|---|
| Poll, result | 2 to 4 (HPA, section 13) | Stateless: at least one per node, so that losing or draining a node keeps them up; more under load. |
| Worker | 2 | Several workers can pop the same Redis list without duplicates (`BLPOP` hands each vote to a single worker), so votes keep being processed during a drain. 2 keep up with the load (section 13). |
| Redis | 1, `Recreate` strategy | Two Redis pods at once would be two separate queues, and some votes would go to the one nobody reads. |
| PostgreSQL | 1 | No built-in multi-writer replication (section 2). |

| Choice | Why |
|---|---|
| PodDisruptionBudgets `minAvailable: 1` on poll, result and the worker | A `kubectl drain` (or an AKS upgrade) cannot stop both replicas at once. |
| No PodDisruptionBudget on Redis and PostgreSQL | With one replica, `minAvailable: 1` would block every drain and every AKS upgrade. |
| No `replicas` field in the poll and result Deployments | Their HPA sets it (section 13). |

## 6. Restart policies

| Choice | Why |
|---|---|
| `restartPolicy: Always` (the default) for every pod | The only value a `Deployment` or a `StatefulSet` accepts: these are long-running services, and a stopped container must come back. The kubelet restarts it in place, with an exponential back-off (10 s, then doubling up to 5 minutes: `CrashLoopBackOff`), reset after 10 minutes without a crash. |
| Restarting is how the application recovers from a lost dependency | Result exits when its PostgreSQL connection fails, and the worker exits on the next vote after losing it: `Always` restarts them, and they wait for the database on startup. Observed when PostgreSQL restarts: the workers and result restart and reconnect, without any action. |
| Liveness probes trigger the restarts of a stuck process (section 11) | poll and result on `/healthz` (the process answers), Redis on its TCP port, PostgreSQL with `pg_isready`. The worker's liveness probe checks its dependencies (`/readyz`), because it never reconnects to PostgreSQL by itself when no vote comes. |
| Readiness, not liveness, checks the dependencies of poll and result | When Redis or PostgreSQL is down, restarting poll or result would not help and would send them into `CrashLoopBackOff`: they only leave the load balancer until it is back. |
| A container over its memory limit is restarted in place (`OOMKilled`) | Only that container restarts, with the same pod and node (section 7). |
| No `Job`, no `OnFailure` or `Never` | There is no one-shot task: the schema is applied by the PostgreSQL entrypoint when the database is created (section 2). `Never` would leave a crashed service down. |
| Pods deleted or evicted are recreated by their controller | Unlike a container restart, the `Deployment` or `StatefulSet` creates a new pod, possibly on another node (a drain, a node loss). |
| `terminationGracePeriodSeconds`: 60 s for PostgreSQL, 15 s for result, 30 s (default) for the others | PostgreSQL gets the time to shut down cleanly (checkpoint). Result runs node as PID 1 without a SIGTERM handler: it ignores SIGTERM and is only stopped by the final SIGKILL, so a short period keeps rollouts fast; the pod has already left the load balancer by then. |

## 7. Resource requests and limits

Measured on AKS: idle, under `make load` (about 540 requests per second on each page) and under
a vote load (about 100 votes per second). Peaks from the containers' cgroup (`memory.peak`,
`cpu.stat`), as `kubectl top` only gives averages over about a minute.

| Container | Idle | Under load (memory: peak) | Requests | Limits |
|---|---|---|---|---|
| poll | 2m, 86Mi | 300m, 97Mi | 50m, 128Mi | 500m, 192Mi |
| result | 2m, 25Mi | 210m, 28Mi | 50m, 64Mi | 500m, 128Mi |
| worker | 2m, 45Mi | 20m, 58Mi | 50m, 128Mi | 500m, 256Mi |
| redis | 12m, 5Mi | 45m, 9Mi | 50m, 64Mi | 500m, 128Mi |
| postgres | 18m, 37Mi | 43m, 49Mi | 100m, 256Mi | 500m, 512Mi |

| Choice | Why |
|---|---|
| Requests and limits on every container | Predictable scheduling, and no pod can starve the others. |
| Memory requests above the measured peak | Memory cannot be taken back from a running process, and a pod above its request is the first one evicted when a node runs short. Poll's went from 96Mi to 128Mi after its 97Mi peak. The worker's covers the heap the JVM may grow to (sized from the limit: at most 126Mi), PostgreSQL's its 128MB of `shared_buffers`. |
| Memory limits at about twice the peak | Room for spikes, while a leak only gets its own container killed and restarted instead of starving the node. |
| CPU requests at the usual usage | What the scheduler reserves, and the base of the autoscalers' target. Under load, pods use the idle CPU of the node, and the autoscalers add pods rather than make them bigger. |
| CPU limits kept | They cap a runaway container on 2-vCPU nodes shared with the AKS system pods. Above them, a container is throttled, not killed (seen in `cpu.stat` for the JVM's startup and short bursts). |
| Redis CPU limit from 250m to 500m | Redis was throttled in bursts, while it is single-threaded and on the path of every vote. |
| Redis `--maxmemory 100mb` (default `noeviction` policy) | If the workers stop, the queue grows: once full (about a million votes), Redis refuses new votes instead of being killed by its memory limit and losing the queued ones. Tested: new votes got an HTTP 500, the 469 queued votes were kept and processed once the workers were back. |
| Burstable QoS (requests below limits) | `Guaranteed` would reserve the peak at all times, which 2 nodes cannot afford with 4 replicas of poll and result. |
| It fits | At the autoscalers' maximum, the application requests 650m of CPU and 1.3Gi of memory out of 3.8 CPUs and 11Gi allocatable (1.9 CPUs requested in total with the AKS system pods). |

## 8. Exposed ports

| Component | Container port | Service | Exposed to |
|---|---|---|---|
| Poll | 80 (`http`) | `LoadBalancer`, port 80 | the Internet |
| Result | 80 (`http`) | `LoadBalancer`, port 80 | the Internet |
| Worker | 80 (`http`), health endpoints only | none | the kubelet's probes only |
| Redis | 6379 (`redis`) | `ClusterIP`, port 6379 | the pods of the cluster |
| PostgreSQL | 5432 (`postgres`) | headless (`clusterIP: None`), port 5432 | the pods of the cluster |

| Choice | Why |
|---|---|
| Only the two web pages are public | They are what the users reach; the queue and the database stay inside the cluster. |
| Port 80, plain HTTP | What the applications listen on; TLS would need a domain and an Ingress (section 15). |
| Named ports (`http`, `redis`, `postgres`) | The Services and the probes refer to the name, so a port changes in one place. |
| Ports 80 without root | The sysctl `net.ipv4.ip_unprivileged_port_start=0` lets the non-root containers bind it, without the `NET_BIND_SERVICE` capability. |
| No Service for the worker | It receives no traffic: it pulls the votes from Redis. |
| Headless Service for PostgreSQL | The StatefulSet's stable DNS name (`postgres-0.postgres`); the clients use `postgres`, which resolves to the single pod. |
| Redis on its default port | The worker's readiness check hardcodes 6379. |

## 9. Scheduling and affinity

| Choice | Why |
|---|---|
| `topologySpreadConstraints` on `kubernetes.io/hostname`, `maxSkew: 1`, for poll, result and the worker | One replica per node: losing or draining a node keeps every service up. Also spreads more replicas evenly (2 + 2 for 4). |
| `ScheduleAnyway` rather than `DoNotSchedule` or a required `podAntiAffinity` | On 2 nodes, a hard rule leaves a replica `Pending` during a drain or a node loss (the other node already runs one), and keeps the autoscaler from adding replicas. Two replicas on one node are better than one. |
| `matchLabelKeys: ["pod-template-hash"]` | Only the pods of the same version are counted: otherwise, during a rollout, the old pods about to be removed attract the new ones to their node. |
| `make start` rebalances the pods (`scripts/rebalance.sh`) | When the cluster starts, its nodes are not ready at the same time and every pod lands on the first one (observed: all 8 pods on one node). Kubernetes never moves a running pod, so the script restarts, with a no-downtime rollout, each Deployment whose replicas share fewer nodes than they could. Measured during a rebalance of poll: 369 requests on each page, 0 errors. |
| No descheduler | It would rebalance continuously, but it is one more component to install and run; the cluster only becomes unbalanced when it starts. |
| No affinity for Redis and PostgreSQL | A single replica has nothing to spread, and the PostgreSQL disk can follow its pod to any node (no availability zones). |
| No `nodeAffinity`, taints or tolerations | The cluster has a single pool of identical nodes. |

## 10. Number of nodes

| Choice | Why |
|---|---|
| 2 × `Standard_B2s_v2` (2 vCPUs, 8 GiB each) | The quota is 6 vCPUs per region. A system node pool keeps `maxUnavailable: 0`, so an AKS upgrade adds a surge node (`maxSurge: 1`) before draining an old one: 2 nodes plus the surge node use 6 vCPUs; 3 nodes would need 8 and the upgrade would fail. |
| 2, not 1 | One node per replica: a drain, an upgrade or a node loss keeps every replicated service up. |
| Enough capacity | At the autoscalers' maximum, everything requested fits on the 2 nodes (section 7). |
| No cluster autoscaler | The quota leaves no room for a third node. |
| `make start` and `make stop` | Cost management: the cluster is stopped whenever it is not used. |

## 11. Probes

| Component | Startup | Readiness (traffic) | Liveness (restart) |
|---|---|---|---|
| Poll | - | `GET /readyz` (Redis answers), every 5 s, out after 2 failures | `GET /healthz`, every 10 s after 5 s |
| Result | - | `GET /readyz` (PostgreSQL answers), every 5 s, out after 2 failures | `GET /healthz`, every 10 s after 5 s |
| Worker | - | `GET /readyz` (Redis and PostgreSQL answer), every 5 s | `GET /readyz`, every 10 s after 30 s, restart after 6 failures (1 minute) |
| Redis | - | `redis-cli ping`, every 5 s | TCP on 6379, every 10 s after 10 s |
| PostgreSQL | `pg_isready` over TCP, up to 30 × 5 s | `pg_isready` over TCP, every 5 s | `pg_isready` over TCP, every 10 s, restart after 6 failures |

| Choice | Why |
|---|---|
| Readiness checks the dependencies | A pod only receives traffic when it can actually record a vote (poll) or show the results (result). |
| Liveness only checks the process for poll and result | A dependency outage must not restart them (section 6). |
| The worker's liveness checks its dependencies | Observed in tests: it never reconnects to PostgreSQL by itself. Restarting it after a minute without Redis or PostgreSQL makes it reconnect as soon as they are back; harmless, since on startup it waits for them. |
| `pg_isready` over TCP, not the local socket | During the first initialization, the image runs a temporary server that only listens on the local socket: it must not be seen as ready. |
| A startup probe for PostgreSQL only | `initdb` or a crash recovery may take a while: the liveness probe only starts once the database answers. The other components start within seconds. |
| `REDISCLI_AUTH` for the Redis probe | The password never appears on a command line. |

## 12. Load balancers

| Choice | Why |
|---|---|
| A `LoadBalancer` Service for poll and for result, rather than an Ingress | The simplest option: AKS creates the Azure load balancer rules and one public IP per page, with no extra controller to install and run. |
| `sessionAffinity: ClientIP` on result | The browser uses Socket.IO with HTTP long-polling only: each request carries a session id known by a single pod. AKS turns the setting into a `SourceIP` rule on the Azure load balancer, and kube-proxy keeps each client IP on the same pod. Measured: without it, 26 of 45 polling requests were rejected (`Session ID unknown`); with it, none. |
| No affinity on poll | Each vote is a single, independent request. |
| `externalTrafficPolicy: Cluster` (the default) | With `Local`, a node left without a ready result pod during a rollout would keep receiving traffic until the Azure probe marks it down. |
| Readiness probes and `preStop` delay | The load balancer only sends traffic to ready pods, and a terminating pod keeps serving while it is removed (section 4). |
| Threaded gunicorn workers | The Azure load balancer's TCP health probes blocked poll's single synchronous worker (section 1). |

## 13. Auto-scaling

| Choice | Why |
|---|---|
| A `HorizontalPodAutoscaler` on poll and result, on CPU | They receive the public traffic and are stateless, so more pods means more capacity. CPU needs nothing beyond the metrics-server AKS already runs. |
| 2 to 4 replicas | 2: one per node, as the PDBs expect. 4: the CPU requests still fit on 2 nodes next to the other pods and the AKS system pods, and the spread constraints place them 2 + 2. |
| Target: 70 % of the CPU request (50m) | Leaves room to absorb a rise while the new pods start. Measured: about 0.8m of CPU per request per second on poll, so it scales beyond about 45 requests per second per pod. |
| No `replicas` in the Deployments | A value would bring the count back to 2 on every deployment, even under load. On the first deployment, the count went to 1 for a few seconds until the autoscaler restored the minimum: 0 errors measured. |
| Scale-down after 5 minutes, one pod per minute | A short dip does not remove capacity, and the Socket.IO clients of a removed result pod reconnect a few at a time. |
| No autoscaling for the worker | Measured: at 100 votes per second, 2 workers used 20m of CPU each and the Redis queue stayed below 8 votes. Their CPU would not show a backlog anyway; the right metric, the length of the Redis list, needs an external metrics adapter (KEDA). |
| No cluster autoscaler | The vCPU quota fixes the cluster at 2 nodes (section 10). |
| `make load` (`scripts/load.sh`) | Shows the autoscaling with `curl` alone. Measured: 2 to 4 replicas within about 70 s, then (after a restart, without load) back to 2 one pod per minute, still one per node; `make watch` saw no error in either direction. |

## 14. Other choices

**Azure**

| Choice | Why |
|---|---|
| AKS (managed Kubernetes) | Recommended by the subject, and covered by the Azure for Students credits. Azure runs the control plane: nothing to install or maintain ourselves. |
| Region `denmarkeast` | The subscription policy only allows 5 regions, and this is the only one offering B-series VMs for AKS. |
| AKS Free tier | No cost for the control plane. The trade-off is no SLA, acceptable for this project. |

**Deployment method**

| Choice | Why |
|---|---|
| Kustomize rather than Helm | No templating needed, built into `kubectl`, and the manifests stay plain, readable Kubernetes YAML. |
| A Makefile over shell scripts | One entry point (`make help`); the scripts keep the logic readable and testable on their own. |
| `deploy.sh` checks that the cluster answers before touching it | A clear error instead of a half-applied deployment. |

**Security (all containers)**

| Choice | Why |
|---|---|
| Non-root, all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp | A compromised container can do as little as possible. |
| Read-only root filesystem | Only explicitly declared volumes are writable (PostgreSQL data and socket, gunicorn's `/tmp`). |
| Dedicated users | Result runs as the image's `node` user (uid 1000); the worker as uid 10001, not the image's `ubuntu` user (uid 1000), which belongs to the sudo and adm groups. |
| Password for Redis (`requirepass`) | Authenticated access, even inside the cluster. |

**Known limit**

A vote is lost if the worker is killed between taking it from Redis and writing it, a window of
a few milliseconds: the application has no acknowledgement mechanism.

## 15. What we chose not to do

| Not done | Why |
|---|---|
| Ingress and TLS | Two public IPs are enough for the subject; an Ingress controller would be one more component to run. |
| Redis persistence | Redis is a transit queue (section 2). |
| PostgreSQL high availability | An operator or a managed service (Azure Database for PostgreSQL) would be the production answer, but it is out of proportion here and costs credits. |
| Helm, CI/CD | The scripts and Kustomize are enough: clone the repository, fill in `.env`, run `make all`. |
| NetworkPolicies, monitoring | Not done. |
| Availability zones | Not enabled on the node pool, which is also what lets the PostgreSQL disk follow its pod to any node. |

## What happens if...

| Event | Effect |
|---|---|
| A node is drained | Poll, result and the worker keep one replica on the other node (PDBs). Redis restarts on the other node (queued votes lost). PostgreSQL restarts there with its disk (short interruption, data kept). |
| A node is lost | Same as a drain, without the PDBs' protection: the pods are rescheduled once Kubernetes declares the node down (about 5 minutes, the default `not-ready`/`unreachable` toleration). |
| Redis restarts | Poll is not ready until Redis is back; the votes waiting in the queue are lost. Measured when its configuration changed: back within seconds, before poll's readiness probe failed, so no page error. |
| The workers stop | Votes wait in Redis. Past 100MB (about a million votes), new votes are refused (HTTP 500) and the queued ones are kept. |
| PostgreSQL restarts | Votes wait in Redis; the workers and result restart and reconnect; the result page is briefly unavailable. |
| A container runs out of memory | It is killed and restarted in place (`OOMKilled`); the other containers are not affected. |
| The traffic rises | The autoscalers add poll and result pods (up to 4 each) within about a minute, and remove them one per minute once it is gone. |
| Poll's or result's sources change and `make all` runs | Only that service gets a new tag and is rolled out, one pod at a time, with no failed request. |
