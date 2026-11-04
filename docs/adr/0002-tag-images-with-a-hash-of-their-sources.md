# Tag each image with a hash of its sources

The tag is a hash of the application's directory, and an image already in the registry is not rebuilt, so `make all` only rolls out the application whose sources changed. That is what makes updating one application safe to repeat; `latest` would be ambiguous and would not trigger a rollout.

## Consequences

- A base image fix only arrives with a source change: nothing rebuilds unchanged sources, and `FORCE=1` reuses a tag that the nodes keep in their cache.
- The tag identifies the sources, not the bytes of the image: the base images float, so two builds of the same sources can differ.
