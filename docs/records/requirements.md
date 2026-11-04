# Requirements

What the [subject](../subject/bernstein-project.pdf) asks for, and where the deployment meets it.

## Constraint

The project is to deploy this exact application: `poll-application/` stays identical to `assets/project-applications.zip`, Dockerfiles included. Whatever the application lacks is handled by the deployment, in the manifests.

| Limit of the application | Handled by |
|---|---|
| One synchronous gunicorn worker, blocked by idle connections | `GUNICORN_CMD_ARGS` on Poll |
| gunicorn writes under `$HOME`, and the user has none | `HOME=/tmp` on Poll |
| The Worker never reconnects a lost PostgreSQL connection by itself | Its liveness probe on `/readyz` ([ADR-0012](../adr/0012-let-readiness-follow-dependencies.md)) |
| Result ignores `SIGTERM` (node runs as PID 1) | A 15 s grace period |
| Result's page only uses Socket.IO long-polling | `sessionAffinity: ClientIP` ([ADR-0010](../adr/0010-pin-result-clients-with-clientip-affinity.md)) |
| The Worker hardcodes port 6379, in its main connection and in its health check | Redis stays on its default port |

## What is asked

| Requirement | Where it is met |
|---|---|
| Build the images, push them to a private registry, deploy them, in that order | `make all` |
| Poll and Result reachable from outside | One `LoadBalancer` Service each ([ADR-0009](../adr/0009-give-each-page-its-own-load-balancer.md)) |
| Deliver everything except the cloud credentials and `POSTGRES_PASSWORD`, and document how to set them | `.env.example`, [README](../../README.md#credentials-and-secrets) |
| An evaluator with a ready cluster on the same platform can deploy from scratch | [Quick start](../../README.md#quick-start-deploy-from-scratch-on-your-own-cluster); `make registry` provides the registry |
| On a fresh cluster, a vote reaches the Result page | `make check-vote`, or by hand on the two pages |
| An update of one application causes no failed request | `make watch` during `make all` ([measurements](measurements.md#no-downtime-updates)) |
| Decisions made and not made are justified | [Index of the technical choices](../technical-choices.md) |
| Questions on what would happen, and how to do something | [Failure modes](failure-modes.md) |
