# Run no network policy engine and no monitoring stack

The cluster has no network policy engine, so NetworkPolicy objects would not be enforced: Redis and PostgreSQL rely on staying inside the cluster behind a password, in a namespace that only runs this application. Observability stops at `kubectl top`, `kubectl logs` and cgroup readings, which were enough to size the pods and follow the updates.

## Considered options

- Enabling an engine with `az aks update --network-policy`, and one policy per backing store: the next step with other workloads around. Azure Network Policy Manager retires in 2028, so Cilium would be the engine to pick.
- Azure Monitor: costs credits.
- A Prometheus stack: more to run than the application itself.
