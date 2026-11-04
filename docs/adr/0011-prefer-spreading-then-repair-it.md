# Prefer spreading the replicas, then repair it

Replicas use a `topologySpreadConstraint` with `ScheduleAnyway`, because a hard rule on two nodes leaves a replica `Pending` during a drain or a node loss and stops the autoscaler from adding pods. `matchLabelKeys: ["pod-template-hash"]` counts one version at a time, so a rollout does not stack the new pods. Kubernetes never moves a running pod, so `make rebalance` restarts what ended up on one node, after a cluster start, a drain or an upgrade.

## Considered options

- `DoNotSchedule` or a required `podAntiAffinity`: see above.
- The descheduler: it rebalances continuously, for one more component to install and run.

## Consequences

Redis and PostgreSQL have nothing to spread and no affinity of their own, so they can share a node, and one drain can then interrupt the queue and the database together. There is no `nodeAffinity` either: the cluster has a single pool of identical nodes.
