# TODOS

## Port-based dev server health check for /setup

**What:** After Phase 5 starts the dev server, detect the port it's listening on from the log output and write it to `harness/workspace/.dev-server.port`. On subsequent `/setup` runs, Phase 5 can skip restart if the port is still responding (`curl -s -o /dev/null http://localhost:<port>`).

**Why:** Currently Phase 5 always restarts the dev server when re-running `/setup`. For projects with slow startup (>30s), this wastes time on reruns.

**Pros:** Faster reruns, avoids duplicate server processes.

**Cons:** Port detection is fragile — depends on log output format varying by project. Adds complexity to an otherwise simple phase.

**Context:** Deferred from the initial setup skill design review. The skip condition was intentionally simplified to "always start" because per-project log formats make port detection unreliable. Revisit when the harness has been used on 3+ real projects and patterns emerge.

**Depends on:** Nothing. Can be added incrementally to `harness/skills/setup.md` Phase 5.
