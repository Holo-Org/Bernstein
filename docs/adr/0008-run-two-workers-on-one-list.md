# Run two Workers on one Redis list

Two Workers keep votes flowing while a node is drained or lost, and `BLPOP` hands each vote to a single Worker, so there are no duplicates.

## Consequences

- Nothing orders the two Workers: two votes from one voter that sit next to each other in the queue can be stored in either order, and the first one then wins ([measured](../records/measurements.md#other-tests)). A person voting twice on an empty queue is not affected; a backlog is what brings their votes together.
- A vote is lost if a Worker is killed between taking it from Redis and writing it, a window of a few milliseconds, because the application has no acknowledgement mechanism.
