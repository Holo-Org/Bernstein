# Use Redis as a transit queue, not a store

The Worker empties the queue continuously and the votes are persisted in PostgreSQL, so Redis runs as one pod with `Recreate`, no persistence, and `--maxmemory 100mb` with the default `noeviction` policy. Two Redis pods at once would be two separate queues.

## Consequences

- The votes waiting in the queue are lost if Redis restarts.
- If the Workers stop, the queue grows until new votes get an HTTP 500, rather than Redis being killed by its memory limit and losing the queued ones.
