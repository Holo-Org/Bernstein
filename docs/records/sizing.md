# Sizing

CPU, memory, replicas and autoscaling, with how each number was reached. The raw figures are in the [measurements](measurements.md#resource-usage).

## Requests and limits

| Container | Requests | Limits | Limit over the memory peak |
|---|---|---|---|
| poll | 50m, 128Mi | 500m, 192Mi | 2.0 |
| result | 50m, 64Mi | 500m, 128Mi | 4.6 |
| worker | 50m, 128Mi | 500m, 256Mi | 4.4 |
| redis | 50m, 64Mi | 500m, 128Mi | 14.2 |
| postgres | 100m, 256Mi | 500m, 512Mi | 10.4 |

- **Requests and limits on every container**: predictable scheduling, and no pod can starve the others. Ephemeral storage is not covered ([known gap](security-baseline.md#known-gaps)).
- **Memory requests above the measured peak**: memory cannot be taken back from a running process, and a pod above its request is the first one evicted when a node runs short. Poll's went from 96Mi to 128Mi after its 97Mi peak. The Worker's covers the heap the JVM may grow to (sized from the limit: at most 126Mi with 256Mi), and PostgreSQL's its 128MB of `shared_buffers` once the data outgrows them.
- **Memory limits at least twice the peak**: room for spikes, while a leak only gets its own container killed (`OOMKilled`, then restarted in place) instead of starving the node. Poll's is twice its peak; the Worker's is sized for the JVM heap, Redis's for its `maxmemory`, PostgreSQL's for `shared_buffers`, and Result's is a round 128Mi.
- **CPU requests are tuning values**: they are what the scheduler reserves and the base of the autoscalers' target, not the observed usage (Poll idles at 2m and peaks at 300m). Under load, pods use the idle CPU of the node, and the autoscalers add pods rather than make them bigger.
- **CPU limits kept**: they cap a runaway container on 2-vCPU nodes shared with the AKS system pods. Above them, a container is throttled, not killed: `cpu.stat` showed it for the JVM's startup and in short bursts under load.
- **Redis CPU limit raised from 250m to 500m**: it was throttled in bursts, while it is single-threaded and on the path of every vote.
- **Redis `--maxmemory 100mb`**: see [ADR-0007](../adr/0007-use-redis-as-a-transit-queue.md). About a million votes by estimate, not by measurement.
- **Burstable QoS** (requests below limits): `Guaranteed` would reserve the peak at all times, which 2 nodes cannot afford with 4 replicas of Poll and Result.

## It fits

At the autoscalers' maximum, the application requests 650m of CPU and 1.3Gi of memory (1344Mi), out of 3.8 CPUs and 11Gi allocatable on the 2 nodes; with the AKS system pods, 1.9 CPUs were requested in total. The 3.8 CPUs are burst capacity: a `Standard_B2s_v2` guarantees 40 %, about 1.6 vCPUs for the pool ([ADR-0005](../adr/0005-run-two-b-series-nodes.md)).

## Replicas

| Workload | Replicas | Why |
|---|---|---|
| Poll, Result | 2 to 4, by HPA | Stateless: at least one per node, more under load. |
| Worker | 2 | [ADR-0008](../adr/0008-run-two-workers-on-one-list.md) |
| Redis | 1 | [ADR-0007](../adr/0007-use-redis-as-a-transit-queue.md) |
| PostgreSQL | 1 | [ADR-0006](../adr/0006-keep-the-votes-in-one-postgresql-pod.md) |

- **PodDisruptionBudgets `minAvailable: 1`** on Poll, Result and the Worker: a drain or an AKS upgrade cannot stop both replicas at once. `unhealthyPodEvictionPolicy: AlwaysAllow` keeps a dependency outage from stalling the drain ([ADR-0012](../adr/0012-let-readiness-follow-dependencies.md)).
- **No budget on Redis and PostgreSQL**: with one replica, `minAvailable: 1` would block every drain and every AKS upgrade.

## Autoscaling

- **An HPA on Poll and Result, on CPU**: they receive the public traffic and are stateless, so more pods means more capacity. CPU needs nothing beyond the metrics-server AKS already runs.
- **2 to 4 replicas**: 2 is one per node, as the budgets expect. 4 still fits on 2 nodes next to the other pods and the AKS system pods, and the spread constraints place them 2 + 2.
- **Target: 70 % of the 50m request**, about 35m per pod: it leaves room to absorb a rise while new pods start. At about 0.8m of CPU per request per second on Poll, it scales beyond about 45 requests per second per pod.
- **No `replicas` in the Poll and Result Deployments**: a value would bring the count back on every deployment, even under load. It costs a one-time drop to 1 replica when the field is first removed, a few seconds until the autoscaler restores the minimum.
- **Scale-down at one pod per minute**: a short dip does not remove capacity, and the Socket.IO clients of a removed Result pod reconnect a few at a time. The 5-minute window is the Kubernetes default; the policy is what was added.
- **No autoscaling for the Worker**: 2 keep up (see the [measurements](measurements.md#resource-usage)), and their CPU would not show a backlog anyway. The right metric, the length of the Redis list, needs an external metrics adapter such as KEDA.
- **No cluster autoscaler**: the vCPU quota fixes the cluster at 2 nodes ([ADR-0005](../adr/0005-run-two-b-series-nodes.md)).

Two effects of a single load source, as `make load` is: its connections stay open, so they stay on the pods they reached first; and Result keeps each client IP on one pod, so all the load goes to one replica ([ADR-0010](../adr/0010-pin-result-clients-with-clientip-affinity.md)). The average still rises and the autoscaler adds pods for other clients.
