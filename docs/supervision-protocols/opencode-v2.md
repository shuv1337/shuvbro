Mode: Native OpenCode V2 TUI-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/fm-native-v2/tui.js` reconcile the explicit lead claim and arm after canonical session startup acquires the home lock.
3. Explicit activation uses `bin/fm-opencode-v2-primary.sh`; its help owns launch mechanics.
   The installed Linux native executable is required, rather than the npm wrapper that forks a different PID.
   Install the pinned runtime with `npm ci --prefix .opencode/plugins` before activation.
4. Ownership is one immutable TUI process/start token, exact root session, frozen home/state/config tuple and verified execution-service incarnation.
   Ordinary clients, observers, workers and children never acquire authority from event arrival or directory equality.
   A linked primary copy requires the same explicit activation; it is inert by default.
   A live competing claim refuses replacement; dead-owner takeover requires a new explicit activation.
   Ambient server environment and another client's session-environment replacement cannot change the frozen claim.
   The proven owner refreshes its complete filtered helper environment during reconciliation, so a stock observer's tab navigation cannot silently remove the owner's routing.
   A model helper verifies a native running shell PID/session association as well as the service incarnation; exporting a lead session ID in another worker's shell is not authority.
   The session-lock library's supplemental owner implementation is `bin/fm-opencode-v2-owner.mjs`.
5. After a genuine actionable close, the coordinator durably saves the logical admission ID/text, verifies its singleton successor and confirms the handoff before native queued admission; `docs/watcher-continuity.md` owns that handoff ordering.
   Rejected or unknown acknowledgements retry the same ID/text; admission never acknowledges wake rows.
   An exhausted admission remains pending and produces a bounded diagnostic, not an unguarded recovery-marker reopen.
   Subsequent attempts continue with capped backoff while ownership remains valid; confirmed canonical queue acknowledgement retires the obsolete transport obligation without reporting it as admitted.
6. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
7. Unexpected child close enters bounded exponential retry; failure remains visible in the TUI and the home-owned adapter diagnostic.
   An interrupted model turn alone never schedules continuation; a later durable fleet wake may resume supervision.
8. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
9. Never use shell `&` for watcher supervision.
   The arm mechanism above is TUI-owned, not a model tool call; the native package invokes the existing command classifiers only for the exact registered lead.
10. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

Herdr detach preserves a surviving TUI owner.
TUI cleanup retires its arm and registration without stopping shared execution; abrupt exit is detected through process-birth checks.
The installed TUI can finish process exit before asynchronous plugin disposal, so the same coordinator also owns a synchronous same-claim exit tombstone; it is not another supervision loop.
The server retains protective refusal for stale exact registered leads, including after restart; unrelated and inherited child markers remain inert.
If a surviving owner reconnects to a restarted service, invoke its native `/firstmate-rebind` command to verify and republish that service incarnation explicitly.
Observers cannot invoke this owner command; an unreachable old endpoint requires an explicit same-session relaunch after the old TUI exits, not passive takeover.
The periodic reconciliation is the turn-end backstop: restore the one watcher mechanically, not by emitting an interruption-only continuation.
It also bounds event-stream gaps; the adapter does not depend on stream reconnection for continuity.
Only Linux process-birth qualification is implemented.
The fixed user registry ignores XDG relocation; disposable probes must use an explicit token-only namespace and the owner's `cleanup-test-namespace` command, never the operator's default namespace.
V2 secondmates are not qualified; refuse that launch before creating a worker.
