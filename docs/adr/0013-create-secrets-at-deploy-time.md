# Create the Secrets at deploy time from the environment

The subject forbids delivering `POSTGRES_PASSWORD`, so passwords come from the environment or `.env` and reach the cluster as Secrets created by the deployment. The Redis password is optional for the application; it keeps access authenticated even inside the cluster.

## Considered options

- Azure Key Vault with its CSI driver: out of proportion for two passwords.

## Consequences

`POSTGRES_PASSWORD` is only applied when the database is created: changing it later also needs `ALTER USER`, or the Worker and Result can no longer connect.
