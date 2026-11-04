---
status: proposed
---

# Build the images on the operator's machine

`make build-push` builds with the local Docker and pushes to ACR, because ACR Tasks are reported as paused on subscriptions funded by free credits, which Azure for Students is. Whoever deploys therefore needs Docker, and QEMU emulation on an ARM machine, since the nodes are `linux/amd64`.

## Considered options

- `az acr build`: no local Docker and no emulation, the build runs next to the registry. The pause comes from Microsoft Q&A answers rather than from the documentation: one run on our subscription would settle it, and accept or supersede this decision.
