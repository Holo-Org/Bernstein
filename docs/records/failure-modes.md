# Failure modes

What happens when something goes away, and what to run. Figures are in the [measurements](measurements.md).

## Updating an application

An update of Poll, Result or the Worker causes no failed request, through five mechanisms:

- The image tag is a hash of the sources, so only the changed application rolls out ([ADR-0002](../adr/0002-tag-images-with-a-hash-of-their-sources.md)).
- `RollingUpdate` with `maxUnavailable: 0` and `maxSurge: 1`: a new pod must be ready before an old one is removed.
- The readiness probe on `/readyz`: a new pod only receives traffic once it can serve it, and a new Worker only replaces an old one once connected to Redis and PostgreSQL.
- `preStop: sleep 5` on Poll and Result: a terminating pod keeps serving while the load balancer stops sending it traffic.
- `kubectl apply` then a wait for the rollouts: the same script handles the first deployment and the updates, and only ends once the deployment is ready.

Redis and PostgreSQL cannot be updated without a short interruption: a change to their manifests restarts them, and Result exits when it loses PostgreSQL, so its page fails for some seconds.

## Draining a node

```sh
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>
make rebalance
```

- Without both flags, the drain refuses to start and leaves the node cordoned: every node runs DaemonSet pods, and Poll, Redis and PostgreSQL use `emptyDir` volumes, whose content is disposable.
- Poll, Result and the Worker keep one replica on the other node, thanks to their PodDisruptionBudgets.
- Redis restarts on the other node, and the votes in the queue are lost. The move is shorter than Poll's readiness allows, so no page fails.
- PostgreSQL restarts there too, with its disk: the disk is detached and attached to the other node, and the Result page is unavailable meanwhile.
- The replicas stay stacked on the remaining node until `make rebalance`, as nothing moves a running pod. So does an AKS upgrade, which drains the nodes in turn.

## What happens if

| Event | Effect |
|---|---|
| A node is lost | Same as a drain, without the budgets' protection. The pods are rescheduled once Kubernetes declares the node down, after about 5 minutes (the default `not-ready` and `unreachable` tolerations). If Redis was there, the Poll page is down until then. |
| Redis restarts | Under about 10 s, nothing shows. Beyond, both Poll replicas leave the Service together and the Poll page fails until Redis is back. The Workers exit on the lost connection and are restarted. The queued votes are lost. |
| The Workers stop | Votes wait in Redis. Past 100MB, new votes get an HTTP 500 and the queued ones are kept. |
| A Worker is killed while it holds a vote | That vote is lost if its `INSERT` has not reached PostgreSQL: `BLPOP` took it from Redis, and the Worker only puts it back on a SQL error. It comes from the application, whose sources are fixed. |
| PostgreSQL restarts | Votes wait in Redis, the current one being put back by the Worker. The Workers and Result exit, are restarted and reconnect. The Result page is briefly unavailable. |
| A container exceeds its memory limit | It is killed and restarted in place (`OOMKilled`), on the same pod and node. The others are not affected. |
| The traffic rises | The autoscalers add Poll and Result pods, up to 4 each, within about a minute, and remove them one per minute once it is gone. |
| The sources of one application change and `make all` runs | Only that application gets a new tag and rolls out, one pod at a time. |
| `POSTGRES_PASSWORD`, `POSTGRES_USER` or `POSTGRES_DB` changes | The Worker and Result can no longer connect, as these are only applied when the database is created. Use the original values, or change them in the database (`ALTER USER` for the password). |

## Restarts

Every pod keeps `restartPolicy: Always`, the only value a Deployment or a StatefulSet accepts. The kubelet restarts a stopped container in place with an exponential back-off: 10 s, doubling up to 5 minutes (`CrashLoopBackOff`), reset after 10 minutes without a crash. A pod that is deleted or evicted is recreated by its controller, possibly on another node.

This is how the application recovers from a lost backing store: Result exits when its PostgreSQL connection fails, the Worker exits on the next vote or through its liveness probe, and both wait for the store on startup. No `Job` is involved: the schema is applied by the PostgreSQL entrypoint.

| Grace period | Why |
|---|---|
| 60 s for PostgreSQL | A clean shutdown, with a checkpoint. The image stops with `SIGINT`, a fast shutdown. |
| 15 s for Result | node runs as PID 1 without a `SIGTERM` handler: it ignores `SIGTERM` and only stops on the final `SIGKILL`. The pod has already left the load balancer by then. |
| 30 s (default) for the others | |

## What happens to the data

| Action | Result |
|---|---|
| Delete the pod | The StatefulSet recreates `postgres-0` with the same claim: data kept. |
| Delete the StatefulSet | The claim is kept and reused on the next deployment. |
| Delete the namespace or the claim | The disk is deleted (`reclaimPolicy: Delete` of the `default` StorageClass): **data lost**. |
| Drain the node | The disk follows the pod to the other node, as the node pool has no availability zones: data kept. |

To keep a copy before a risky change:

```sh
kubectl exec --namespace bernstein postgres-0 -- pg_dump --username poll poll > votes.sql
```

## Probes

| Workload | Startup | Readiness (traffic) | Liveness (restart) |
|---|---|---|---|
| Poll | - | `GET /readyz` (Redis answers), every 5 s, out after 2 failures | `GET /healthz`, every 10 s after 5 s |
| Result | - | `GET /readyz` (PostgreSQL answers), every 5 s, out after 2 failures | `GET /healthz`, every 10 s after 5 s |
| Worker | - | `GET /readyz` (Redis and PostgreSQL answer), every 5 s | `GET /readyz`, every 10 s after 30 s, restart after 6 failures |
| Redis | - | `redis-cli ping`, every 5 s | TCP on 6379, every 10 s after 10 s |
| PostgreSQL | `pg_isready`, up to 30 × 5 s | `pg_isready`, every 5 s | `pg_isready`, every 10 s, restart after 6 failures |

`pg_isready` goes through TCP, because during the first initialization the image runs a temporary server that only listens on its Unix socket, and that one must not be seen as ready. Why readiness and liveness differ: [ADR-0012](../adr/0012-let-readiness-follow-dependencies.md).
