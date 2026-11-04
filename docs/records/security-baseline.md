# Security baseline

What every pod of the namespace runs with, and what is left out.

| Setting | Effect |
|---|---|
| `runAsNonRoot`, a fixed uid and gid | No container runs as root. Result uses the image's `node` user (1000); the Worker uses 10001, not the image's `ubuntu` user (1000), which belongs to the sudo and adm groups. |
| `capabilities: drop: ["ALL"]`, `allowPrivilegeEscalation: false` | A compromised process cannot gain privileges. |
| `seccompProfile: RuntimeDefault` | The runtime's default system call filter. |
| `readOnlyRootFilesystem: true` | Only declared volumes are writable: the PostgreSQL data and socket, and gunicorn's `/tmp`. |
| `automountServiceAccountToken: false` | No pod needs the Kubernetes API, so none holds a token for it. |
| `net.ipv4.ip_unprivileged_port_start=0` | A non-root process can bind port 80, without `NET_BIND_SERVICE`. It is a safe sysctl since Kubernetes 1.22, allowed by the Pod Security Standards. |
| `REDISCLI_AUTH` for the Redis probe | The probe's password stays off its command line. |

## Exposure

| Workload | Container port | Service | Exposed to |
|---|---|---|---|
| Poll | 80 (`http`) | `LoadBalancer`, port 80 | the Internet |
| Result | 80 (`http`) | `LoadBalancer`, port 80 | the Internet |
| Worker | 80 (`http`), health endpoints only | none | the kubelet's probes only |
| Redis | 6379 (`redis`) | `ClusterIP`, port 6379 | the pods of the cluster |
| PostgreSQL | 5432 (`postgres`) | headless, port 5432 | the pods of the cluster |

- Only the two pages are public: the queue and the database stay inside the cluster, in a namespace of their own.
- Port 80, plain HTTP, is what the applications listen on. TLS would need a domain and an Ingress ([ADR-0009](../adr/0009-give-each-page-its-own-load-balancer.md)).
- Services and probes refer to named ports, so the manifests declare each port once. The application itself hardcodes its ports.
- The Worker has no Service: it receives no traffic, it pulls the votes from Redis.
- The PostgreSQL Service is headless, as a StatefulSet expects: `postgres-0.postgres` is the stable name, and clients use `postgres`, which resolves to the pod once it is ready.

## Passwords

They are not in git nor in the manifests, and the scripts keep them off their command lines. `scripts/render.sh` writes them to a private temporary directory for the time of the build, as `.env` already holds them in clear on the same machine. Redis does receive its password as an argument (`--requirepass $(REDIS_PASSWORD)`): the kubelet expands it when it starts the container, so it stays visible in the container's configuration on the node.

## Known gaps

- Ephemeral storage has no requests or limits, and Poll's `/tmp` has no `sizeLimit`, unlike the volumes of Redis and PostgreSQL.
- Traffic inside the cluster is not restricted ([ADR-0014](../adr/0014-run-no-network-policy-engine-or-monitoring-stack.md)) nor encrypted.
- Secrets reach the applications through environment variables, because that is what the applications read.
