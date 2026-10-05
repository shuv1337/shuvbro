Mode: Native OpenCode V2 TUI-owned supervision.

Qualification is pending for the combined shared-service/Herdr/two-worker matrix; [runtime verification](../verification/runtime-backends.md#native-shared-service-qualification-status) distinguishes actual isolated evidence from unqualified cases.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/fm-native-v2/tui.js` reconcile the explicit lead claim and arm after canonical session startup acquires the home lock.
3. Explicit activation uses `bin/fm-opencode-v2-primary.sh`; its help owns launch mechanics, and `bin/fm-opencode-v2-lead.sh` is the default launcher that resolves the session and native executable for it.
   A plain `shuvcode` launch is never activated, so its session start refuses the fleet lock and names this relaunch, or the live lead that already holds the lock.
   The installed Linux native executable is required, rather than the npm wrapper that forks a different PID.
   Install the pinned runtime with `npm ci --prefix .opencode/plugins` before activation.
4. Ownership is one immutable TUI process/start token, exact root session, frozen home/state/config tuple and verified execution-service incarnation.
   Ordinary clients, observers, workers and children never acquire authority from event arrival or directory equality.
   A linked primary copy requires the same explicit activation; it is inert by default.
   A live competing claim refuses replacement; dead-owner takeover requires a new explicit activation.
   Ambient server environment and another client's session-environment replacement cannot change the frozen claim.
   The proven owner refreshes its complete filtered helper environment during reconciliation, so a stock observer's tab navigation cannot silently remove the owner's routing.
    A model helper verifies service ancestry and a running shell PID/cwd with same-user server-attributed session metadata, against the immutable registered service endpoint and incarnation.
    Kernel process evidence does not authenticate the session metadata: a deliberate same-user native API client can mint a lead-attributed shell, so this is an agent-mistake boundary, not a security sandbox against the execution user.
    Merely exporting a lead session ID from an ordinary worker shell is refused, and lead subagents must not perform `fm-*` mutations on the lead's behalf.
    Observer environment replacement can briefly refuse a shell until the next owner reconciliation; that refusal does not transfer ownership.
   The session-lock library's supplemental owner implementation is `bin/fm-opencode-v2-owner.mjs`.
5. After a genuine actionable close, the coordinator durably saves the logical admission ID/text, verifies its singleton successor and confirms the handoff before native steer admission; `docs/watcher-continuity.md` owns that handoff ordering.
   Lead journal prompts (wakes, startup nudges and repair notices) use `delivery: "steer"`: an idle session starts execution, and a busy turn receives the prompt at its next model step boundary, after any active model response or tool execution finishes.
   Worker briefs remain queued through the separate worker launch path.
   Rejected or unknown acknowledgements retry the same ID/text; admission never acknowledges wake rows.
   The wake doorbell contains only a generic instruction to drain and acknowledge the durable queue; authoritative reasons come from that drain.
   While an admitted wake doorbell is still undrained, later wakes from the same claim stay journaled behind that outstanding steer without handoff confirmation.
   If the lead's turn ends (an execution terminal event for the exact lead session) with no drain recorded since a doorbell's admission, that doorbell stops holding the slot, so parked or later wakes admit exactly one new doorbell; a later drain still retires both.
   The exact-ID native inbox acceptance event also binds a turn end that arrives before the prompt receipt, including lost-receipt retries; an idle event before acceptance never releases a fresh doorbell.
   Every main `bin/fm-wake-drain.sh` presentation advances a monotonic sequence in `state/.wake-drain-presented` with the recovery generation and highest row sequence it presented.
   An admitted doorbell is handled once a drain is recorded after its admission, even if rows remain queued; a confirmed no-row recovery, or an unadmitted row wake whose every row that drain presented, is also covered by a drain recorded after its preparation.
   A later wake names only the rows that arrived after the latest drain, so a covered record cannot absorb them and they get exactly one doorbell; a wake captured only after a drain already presented all its rows is covered without a doorbell.
   Otherwise canonical row removal retires a row wake, and an acknowledged marker for a recovery's generation (or, once admitted, any later one) retires it; missing or malformed state retains a doorbell, and a doorbell admitted by an older claim never holds a new owner's slot.
   A record parked behind an undrained doorbell is healthy coalescing and stays out of the undelivered-admission stall notice; it counts toward that notice only when a drain is recorded that cannot be proven to precede its blocker's admission.
   A parked wake then admits if its obligation remains, or retires without another prompt if canonical handling already settled it; rows that arrived after the drain get their own doorbell, without a stale handoff confirmation once the episode is acknowledged.
   Only canonically retired wake records expire after seven days; outstanding recovery records remain retained.
   An exhausted admission remains pending and produces a bounded diagnostic, not an unguarded recovery-marker reopen.
   Subsequent attempts continue with capped backoff while ownership remains valid; confirmed canonical queue acknowledgement retires the obsolete transport obligation without reporting it as admitted.
6. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
7. Unexpected child close enters bounded exponential retry; transient failures immediately update the private diagnostic but do not request manual repair.
   A failure or retained admission unresolved for 30 seconds becomes eligible for a toast and operational prompt on the next two-second reconciliation tick; retry exhaustion, invalid ownership/service proof, inability to journal a wake, an unretried startup helper/nudge setup failure or a failed explicit `/firstmate-rebind` becomes eligible immediately, even after an earlier stall notice.
   Waiting for session start to acquire the lock is silent until this TUI first owns supervision, and a self-healed startup admission retry clears its episode; ownership lost after being held counts toward the 30-second bound.
   Notices are rate-limited to one per five seconds; distinct actionable reasons queue rather than being dropped, with exact-text deduplication scoped to the failure episode and no lifetime cap.
   An actionable presentation that could not be journaled remains a recovery obligation even with an empty journal; simultaneous restoration failure takes precedence, and a verified successor generation can repair preparation before confirmation and admission.
   A repair reason is deduplicated as surfaced only after exact-ID prompt admission succeeds; rejected, timed-out or temporarily unauthorized attempts retain their message identity and retry with the journal's capped backoff and the five-second notice rate limit.
   Retries show the toast once per reason and report delivery failure privately without generating recursive failure prompts; unresolved current-claim notices survive setup reload and cannot be cleared as healthy recovery.
   Verified recovery clears the episode only after its repair admissions are confirmed, without clearing the diagnostic or consuming canonical wake rows; a later failure can notify again with a fresh admission identity.
   Repair notices may reach the frozen lead session while its service proof is stale only if the canonical registration still proves this same TUI process, claim, paths and endpoint; this notice-only exception never rebinds ownership or admits a wake.
   Admitted repair records and abandoned records from older claims expire after seven days; unresolved current-claim records are retained.
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
The endpoint itself remains frozen and must have a local native managed registration; an unregistered `--server` or different endpoint cannot silently fall back to the default service.
Workers dispatched from a home with a V2 lead owner record use that record's frozen endpoint; a retired record means no V2 lead owns the home and keeps the default service, while any other stale or noncanonical record refuses the spawn before a window opens instead of falling back to the default service.
A failed worker spawn or fresh-dispatch rollback interrupts the exact admitted native session and reports any unproved cancellation.
The fork preserves in-flight execution claims across shutdown and resumes them at boot with at-least-once semantics: the model may repeat side-effecting commands.
Worker cleanup therefore refuses until exact-session cancellation on the live successor is proven, or an idle successor has been up at least 30 seconds, two execution samples at least one second apart are empty, and its newest message is a succeeded/failed/interrupted idle notice or a completed assistant response with `finish:stop`.
The terminal may predate the restart; newer user/restart messages, incomplete/tool-call responses or ambiguous evidence still refuse.
The fork [releases claims on terminal events](https://github.com/Latitudes-Dev/shuvcode/blob/5a22036b9e555fc1bade22361743603a5c930d31/packages/core/src/session/execution.ts#L123-L150) and [projects idle notices only for those terminals, not shutdown](https://github.com/Latitudes-Dev/shuvcode/blob/5a22036b9e555fc1bade22361743603a5c930d31/packages/core/src/session/message-updater.ts#L142-L147); [parked prompt admission does not wake execution](https://github.com/Latitudes-Dev/shuvcode/blob/5a22036b9e555fc1bade22361743603a5c930d31/packages/core/src/session/session.ts#L150-L175).
After restart, `--force` discard without that proof explicitly accepts possible later execution in a removed isolated copy; it is not confirmed cancellation.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/opencode-v2.md#dispatch) also documents the pre-dispatch capability gate.
Observers cannot invoke this owner command; an unreachable old endpoint requires an explicit same-session relaunch after the old TUI exits, not passive takeover.
The periodic reconciliation is the turn-end backstop: restore the one watcher mechanically, not by emitting an interruption-only continuation.
It also bounds event-stream gaps; the adapter does not depend on stream reconnection for continuity.
Only Linux process-birth qualification is implemented.
The fixed user registry ignores XDG relocation; disposable probes must use an explicit token-only namespace and the owner's `cleanup-test-namespace` command, never the operator's default namespace.
V2 secondmates are not qualified; refuse that launch before creating a worker.
