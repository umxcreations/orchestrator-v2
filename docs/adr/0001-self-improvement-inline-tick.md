# Self-improvement runs inline in the tick, not as a separate subagent or cron

The self-improvement loop fires as step 5 of the normal `/loop` tick rather than as a separate subagent dispatch or independent cron job. This keeps orchestration in one place (the tick sequence), avoids competing tick lock acquisition, and means no additional scheduling mechanism is needed. The trade-off is that a slow improvement run delays the session in which it runs — acceptable because it fires only when the harness is already idle and `ScheduleWakeup` is called before step 5, so the next tick's 270s clock is unaffected.

## Considered Options

- **Separate subagent** (rejected): cleaner isolation but requires session lifecycle management for a maintenance task, and adds risk of an improvement session blocking dispatch on the next tick.
- **Independent cron** (rejected): clean separation but introduces a second orchestration mechanism that competes with the tick lock and has no natural idle gate.
