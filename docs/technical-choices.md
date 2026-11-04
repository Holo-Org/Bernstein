# Technical choices

Index of the decisions behind the deployment, and of the facts they rest on. The [README](../README.md) describes how to deploy.

## Decisions

Each one had real alternatives and would be costly to reverse.

| Topic | Decision |
|---|---|
| Build | [Build the images on the operator's machine](adr/0001-build-images-on-the-operator-machine.md) (proposed) |
| Images | [Tag each image with a hash of its sources](adr/0002-tag-images-with-a-hash-of-their-sources.md) |
| Tooling | [Deploy with Make, bash and Kustomize](adr/0003-deploy-with-make-bash-and-kustomize.md) |
| Platform | [Run on AKS Free tier with ACR Basic in denmarkeast](adr/0004-run-on-aks-free-tier-with-acr-basic.md) |
| Nodes | [Run two B-series nodes, off the documented path for system pools](adr/0005-run-two-b-series-nodes.md) |
| Votes | [Keep the votes in one PostgreSQL pod on an Azure disk](adr/0006-keep-the-votes-in-one-postgresql-pod.md) |
| Queue | [Use Redis as a transit queue, not a store](adr/0007-use-redis-as-a-transit-queue.md) |
| Worker | [Run two Workers on one Redis list](adr/0008-run-two-workers-on-one-list.md) |
| Exposure | [Give each page its own LoadBalancer Service](adr/0009-give-each-page-its-own-load-balancer.md) |
| Sessions | [Pin Result clients to a pod with ClientIP affinity](adr/0010-pin-result-clients-with-clientip-affinity.md) |
| Scheduling | [Prefer spreading the replicas, then repair it](adr/0011-prefer-spreading-then-repair-it.md) |
| Probes | [Let readiness follow the dependencies, and liveness only the process](adr/0012-let-readiness-follow-dependencies.md) |
| Secrets | [Create the Secrets at deploy time from the environment](adr/0013-create-secrets-at-deploy-time.md) |
| Left out | [Run no network policy engine and no monitoring stack](adr/0014-run-no-network-policy-engine-or-monitoring-stack.md) |

## Records

Facts rather than decisions: they change without anyone reconsidering anything.

| Record | What it holds |
|---|---|
| [Requirements](records/requirements.md) | What the subject asks for, where it is met, and what the supplied application imposes |
| [Failure modes](records/failure-modes.md) | What happens if something goes away, draining a node, restarts, probes, the fate of the data |
| [Sizing](records/sizing.md) | Requests, limits, replicas and autoscaling, with how each number was reached |
| [Measurements](records/measurements.md) | Every figure measured, once, with where and how |
| [Security baseline](records/security-baseline.md) | What every pod runs with, and the known gaps |
| [Infrastructure](records/infrastructure.md) | The Azure setup, upgrades and costs |

The vocabulary used everywhere is in the [glossary](../CONTEXT.md).
