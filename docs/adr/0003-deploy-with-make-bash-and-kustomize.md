# Deploy with Make, bash and Kustomize

One Makefile drives a few bash scripts and plain Kustomize renders the manifests, with a temporary overlay for what varies per deployment, so the committed manifests never change. Anyone can clone the repository, fill in `.env` and run `make all` with tools they already have.

## Considered options

- Helm: templating we do not need, and the manifests would stop being plain Kubernetes YAML.
- Skaffold: its `inputDigest` tagger and Kustomize deployer would replace `build-push.sh` and `deploy.sh`, but not the Secrets, `watch`, `load` or `rebalance`: one more tool for the same result.
- A deployment pipeline: the process is run by hand from a clone, so there is nothing for it to trigger.

## Consequences

`kubectl apply` is idempotent but deletes nothing: a manifest removed from `k8s/` stays on the cluster, and old hashed ConfigMaps pile up. `--prune` is still alpha in both of its modes, so it is not used.
