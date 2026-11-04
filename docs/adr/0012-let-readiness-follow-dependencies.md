# Let readiness follow the dependencies, and liveness only the process

Poll and Result use the supplied `/readyz`, so they leave the load balancer when Redis or PostgreSQL does not answer. They are not restarted, which would not help and would send them into `CrashLoopBackOff`. The Worker is the exception: its liveness probe also uses `/readyz`, because it never reconnects a lost PostgreSQL connection by itself.

## Considered options

- `/healthz` for Poll's readiness: `GET /` needs no Redis, so the page would survive an outage and only the votes would fail. We keep `/readyz`, so that a replica only receives traffic when it can record a vote, and accept the consequence below.

## Consequences

- Replicas share their dependency, so they leave together: an outage longer than about 10 s empties the Service. A move of Redis to the other node is shorter than that ([measured](../records/measurements.md#losing-redis)).
- If the node of Redis is lost, the Poll page stays down until Redis is rescheduled, about 5 minutes later.
- Pods that are NotReady because of a dependency would make the PodDisruptionBudgets refuse their eviction and stall a drain, hence `unhealthyPodEvictionPolicy: AlwaysAllow`.
- On a fresh deployment, the Worker's liveness can restart it after about 90 s if PostgreSQL is not up yet. It is harmless: it waits for its dependencies on startup.
