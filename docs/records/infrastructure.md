# Infrastructure

The Azure facts the deployment rests on. The commands to create it are in the [README](../../README.md#create-the-infrastructure).

## Current setup

- **Subscription**: Azure for Students, 6 vCPUs per region, 5 regions allowed by policy.
- **Region**: `denmarkeast`, resource group `bernstein-rg`.
- **Registry**: Azure Container Registry `bernsteindcacr` (Basic), private.
- **Cluster**: AKS `bernstein-aks`, Free tier, Azure CNI Overlay, one system node pool of 2 × `Standard_B2s_v2` (2 vCPUs, 8 GiB), attached to the registry with the `AcrPull` role.

Why this shape: [ADR-0004](../adr/0004-run-on-aks-free-tier-with-acr-basic.md) and [ADR-0005](../adr/0005-run-two-b-series-nodes.md).

## Upgrades

A system node pool cannot use `maxUnavailable`, so an AKS upgrade always adds a surge node, which is the default (`maxSurge: 1`). It is ready before an old node is drained, so 2 schedulable nodes remain at all times.

- With 2 nodes, an upgrade peaks at 3 nodes, 6 vCPUs: within the quota.
- With 3 nodes, the surge node would need 8 vCPUs and the upgrade would fail.

The `NodeImage` channel replaces the nodes every week, which drains them. The `aksManagedNodeOSUpgradeSchedule` window keeps this to Sunday night; AKS treats it as best effort.

## Costs

Stopping the cluster (`make stop`) saves the compute. The cluster state is kept for up to 12 months, and the API server's address may change on start.

What stays allocated keeps costing, at list price in `denmarkeast`:

| Resource | Price |
|---|---|
| ACR Basic | 0.1666 USD a day |
| Standard public IPv4 (one per page, one outbound) | 0.005 USD an hour each |
| PostgreSQL disk (1 GiB, billed as E1) | 0.30 USD a month |

Together, about 16 USD a month. The actual bill may differ.
