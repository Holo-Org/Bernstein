# Pin Result clients to a pod with ClientIP affinity

The supplied page uses Socket.IO with HTTP long-polling only, and each request carries a session id known by a single pod, so a client must always reach the same pod. `sessionAffinity: ClientIP` does it with no change to the application: AKS turns it into a `SourceIP` rule on the Azure load balancer, and kube-proxy keeps each client IP on the same pod.

## Consequences

Clients behind one NAT land on a single pod, so a room full of people, or one load generator, only exercises one replica of Result.
