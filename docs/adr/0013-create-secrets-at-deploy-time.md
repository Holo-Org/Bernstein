# Create the Secrets at deploy time from the environment

The subject forbids delivering `POSTGRES_PASSWORD`, so passwords come from the environment or `.env` and `scripts/render.sh` turns them into Secrets, with fixed names, in the same render as the rest of the manifests. The Redis password is optional for the application; it keeps access authenticated even inside the cluster.

## Considered options

- Azure Key Vault with its CSI driver: out of proportion for two passwords.
- Names with a content hash, as for the ConfigMap: a new password would roll out the pods by itself, but old Secrets would pile up, and each one keeps an old password.

## Consequences

`POSTGRES_PASSWORD` is only applied when the database is created: changing it later also needs `ALTER USER`, or the Worker and Result can no longer connect.
