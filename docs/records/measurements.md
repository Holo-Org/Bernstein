# Measurements

Every figure measured on the deployment, once. Unless stated otherwise, they come from the AKS cluster, on the date of the change they justified. The local ones come from a kind cluster with two workers on an Apple M5: they show behaviour, not the timings of Azure.

## No-downtime updates

| Date | Where | What | Requests | Errors |
|---|---|---|---|---|
| 2026-10-30 | AKS | Poll's sources changed, `make all`, `make watch` running | 688 on Poll, 687 on Result | 0 |
| 2026-10-30 | AKS | Rollout of Poll and Result together, `make watch` running | 898 | 0 |
| 2026-10-31 | AKS | Rebalance of Poll, `make watch` running | 369 on each page | 0 |
| 2026-10-31 | AKS | Autoscaling from 2 to 4 replicas, `make watch` running | 558 on each page | 0 |
| 2026-10-31 | AKS | Autoscalers back from 4 to 2 replicas | 454 on each page | 0 |
| 2026-11-04 | local | Poll's sources changed, `make all`, under `make load` | 618 496 | 0 |
| 2026-11-04 | local | Poll and Result rolled out together, under `make load` | 606 208 | 0 |

`make watch` makes about one request per second per page from a remote machine, so it only samples a rollout: the load run is what rules out short gaps.

## Losing Redis

Local, 2026-11-04, requesting both pages about 10 times a second.

| What | Result |
|---|---|
| Redis moved to the other node, image pulled there | Back in about 4 s, no failed request |
| `kubectl drain` of the node running Redis | 17 s for the whole node, 790 requests per page, no failed request |
| Redis away for 40 s | Poll out of the Service after 10 s; its page failed until 3 s after Redis was back; Result not affected |
| `kubectl drain` while Redis is away, with the default eviction policy | The budgets refused to evict Poll and the Worker, and the drain timed out |
| The same with `unhealthyPodEvictionPolicy: AlwaysAllow` | Every pod evicted on the first attempt |

On AKS, a change of the Redis configuration restarted it within seconds, before Poll's readiness probe failed: no page error.

## Resource usage

Idle, under `make load` (about 540 requests per second on each page) and under a vote load (about 100 votes per second). Peaks come from the containers' cgroup (`memory.peak`, `cpu.stat`), read with `kubectl exec`, as `kubectl top` only gives averages over about a minute.

| Container | Idle | Under load (memory: peak) |
|---|---|---|
| poll | 2m, 86Mi | 300m, 97Mi |
| result | 2m, 25Mi | 210m, 28Mi |
| worker | 2m, 45Mi | 20m, 58Mi |
| redis | 12m, 5Mi | 45m, 9Mi |
| postgres | 18m, 37Mi | 43m, 49Mi |

At 100 votes per second, the Redis queue stayed below 8 votes. Poll uses about 0.8m of CPU per request per second.

## Autoscaling

Under `make load`, both autoscalers went from 2 to 4 replicas within about 70 s (Poll at 436 % of its request, Result at 209 %), placed 2 + 2 on the nodes. After a restart without load, they went back to 3, then to 2 a minute later, still one per node.

## Other tests

| What | Result |
|---|---|
| Threaded gunicorn | `/healthz` answered in at most 11 ms, against up to 5 s with one synchronous worker |
| Sticky sessions, with a Socket.IO polling client | 26 of 45 requests rejected (`Session ID unknown`) without them, none with them |
| Redis `maxmemory`, lowered, with the Workers stopped | New votes got an HTTP 500, the 469 queued votes were kept and processed once the Workers were back |
| Two votes in a row from each of 3000 voters, pushed straight into the queue (local) | With 2 Workers, 35 voters ended on their first vote; with 1 Worker, none |
| Votes cast one after the other during an update of the Worker (local) | 38 counted by Result, none lost |
| Cluster start | All 8 pods landed on the first ready node, until the rebalance |
| PostgreSQL restart | The Workers and Result restarted and reconnected without any action |
