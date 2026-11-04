# Run on AKS Free tier with ACR Basic in denmarkeast

The subject recommends a managed cluster and the school's Azure credits cover one, so the platform is AKS with a Basic private registry. The Free tier costs nothing for the control plane and gives no SLA, and `denmarkeast` is the only region the subscription policy allows with B-series VMs for AKS.

## Consequences

`az` is wired into the Makefile and the scripts, so another platform means rewriting them. The evaluator's cluster must be on Azure too; `make registry` creates the registry and attaches it, which needs `Owner` on it.
