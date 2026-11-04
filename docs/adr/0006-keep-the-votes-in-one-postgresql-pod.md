# Keep the votes in one PostgreSQL pod on an Azure disk

The subject requires persistent votes, so PostgreSQL runs as a single-replica StatefulSet on a 1 GiB disk. PostgreSQL has no built-in multi-writer replication, and a StatefulSet guarantees at most one pod per identity, so two pods never share the disk.

## Considered options

- An operator or Azure Database for PostgreSQL: the production answer for high availability, out of proportion here, and the second one costs credits.

## Consequences

- An update or a node drain interrupts the database. Votes wait in Redis meanwhile, but the Result page is unavailable.
- The disk survives the pod and the StatefulSet, not the namespace: the `default` StorageClass deletes it with its claim.
- No backup: the votes are demonstration data, and `kubectl exec --namespace bernstein postgres-0 -- pg_dump --username poll poll` is enough before a risky change.
- No schema migration: `schema.sql` is only applied when the database is created, and the application has a single table.
