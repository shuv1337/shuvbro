Mode: OpenCode V2 plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/fm-primary-watch-arm.js` arm supervision after this location's lead session reports idle.
3. The plugin listens for `session.status` idle and the deprecated `session.idle` event, spawns `bin/fm-watch-arm.sh --restart` without awaiting it in the idle handler, and owns every later successor launch.
4. Ownership is the plugin instance location plus a bound lead session id.
   The plugin serves only sessions whose location matches this instance and that are not child sessions.
   If that ownership cannot be proved, the plugin stays inert and never arms.
   Shared-service process ancestry is not lock proof.
5. After an actionable child close, the plugin verifies one singleton successor before it calls `ctx.session.prompt` with `delivery` set to `queue`; its bounded fallback is defined in `docs/watcher-continuity.md`.
6. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
7. An unexpected child close enters bounded exponential retry, and an exhausted retry or unbound session is surfaced as a watcher failure instead of disappearing.
8. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
9. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
10. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode V2's persistent plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and stays silent in child crewmate and scout worktrees.
V2 secondmates are not qualified; refuse that launch before creating a worker.
