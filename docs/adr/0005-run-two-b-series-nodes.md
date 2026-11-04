# Run two B-series nodes, off the documented path for system pools

The 6 vCPU quota must also hold the surge node of an upgrade, because a system pool cannot use `maxUnavailable`: that caps the pool at two 2-vCPU nodes. AKS documents system pools as needing 4 vCPUs and excludes the B-series, so this cluster runs but is outside the documented requirements; two compliant nodes would need 8 vCPUs.

## Consequences

- A `Standard_B2s_v2` guarantees 40 % of its CPUs: about 1.6 vCPUs for the pool once its credits are spent, enough for a demonstration but not for a sustained load.
- No cluster autoscaler and no third node without a quota increase.
- No availability zones, which is also what lets the PostgreSQL disk follow its pod to the other node.
