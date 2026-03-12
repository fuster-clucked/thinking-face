# TODO

## MVP

- [ ] Finish GPU provisioning: Docker, NVIDIA Container Toolkit, Dev Container CLI, and a GPU smoke test.
- [ ] Add a unique `workspace_id`; isolate names, tags, keys, credentials, and network ranges per workspace.
- [ ] Make launch, start, stop, terminate, and destroy idempotent and safe when resources are missing or duplicated.
- [ ] Wait for full workspace readiness, support graceful shutdown, and report clear status/errors.
- [ ] Store workspace data on encrypted persistent storage and test recovery after stop and instance replacement.
- [ ] Support explicit VPC, subnet, and public/private networking configuration.
- [ ] Harden access: unique WireGuard keys, split tunneling, restricted ingress, per-workspace TLS, and per-workspace authentication.
- [ ] Tighten IAM/OIDC permissions; remove hard-coded account values; pin actions, AMIs, and installers; minimize GitHub token exposure.

## Spot resilience

- [ ] Select from multiple compatible instance types and Availability Zones with Spot and On-Demand fallback.
- [ ] Handle rebalance and interruption notices with configurable checkpoint hooks.
- [ ] Replace interrupted instances, reattach storage, restore services, and preserve a stable endpoint.
- [ ] Test interruption recovery with AWS Fault Injection Service.

## Operations and product

- [ ] Add idle shutdown, maximum runtime, budget limits, quota checks, and cost-allocation tags.
- [ ] Move orchestration from workflow shell scripts into a reusable, tested CLI or core library.
- [ ] Add status, repair, repository sync, devcontainer rebuild, logs, and diagnostics.
- [ ] Add CI, unit tests, AWS integration tests, security tests, and concise setup/troubleshooting documentation.
- [ ] Validate the GitHub-native Spot GPU use case, evaluate a DevPod provider, and define go/no-go criteria.
