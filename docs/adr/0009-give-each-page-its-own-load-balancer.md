# Give each page its own LoadBalancer Service

Poll and Result each get a `LoadBalancer` Service and a public IP on port 80, the simplest way to reach them from outside: AKS creates the rules, with no controller to install and run. `externalTrafficPolicy` stays `Cluster`, because with `Local` a node left without a ready pod during a rollout would keep receiving traffic until the Azure probe marks it down.

## Considered options

- An Ingress: one IP and TLS, for one more controller to run, a domain to find, and a sticky setup for Result ([ADR-0010](0010-pin-result-clients-with-clientip-affinity.md)) to redo.
