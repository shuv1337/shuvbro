# Native Shuvcode supervisor

The explicit native path uses Shuvcode's supervisor for durable work, delivery, decisions and execution.
ShuvBro supplies the tracked orchestration profile and optional Herdr presentation.
Use it only with a new home; existing legacy homes are neither migrated nor taken over.
Do not run a legacy fleet watcher or controller against a native home.

The executable [`fm-native.mjs`](../bin/fm-native.mjs) header and `--help` own exact arguments and operations.
It requires Node.js, a managed Shuvcode supervisor with native profile and presentation support, and a named non-default Herdr instance advertising all four runtime attachment methods.
Initialize a new home with an explicit project, socket, session and parent workspace, then explicitly run `up` to start the supervisor and lead.
Initialization records the ShuvBro profile into the native home.
External supervisor endpoints are unsupported for this profile.

**Keep `watch` running to maintain display status.**
`up` and `sync` each reconcile once; `watch` reconciles every two seconds with a five-second status lease.
Stopping or losing the adapter changes expired display observations to unknown and leaves native execution running.
Restarting the adapter reads its exact home-local journal and current bindings.
Use `control` with typed native supervisor arguments for work operations; it prints the native command's result.
The adapter never admits durable prompts through pane input.

Herdr creates views without changing focus and records exact home, Session, attachment, pane, tab and workspace identities in `native-display.json`.
Lead and secondmate views remain persistent; each worker gets a disposable workspace.
Labels are presentation only and never authorize cleanup.
A closed view remains closed until explicit `reopen`, which creates a new binding generation for the same available Session.
Unavailable or retired entries are not automatically recreated.

Use explicit `cleanup` only after the runtime positively reports settlement for the exact recorded attachment.
A done label alone does not establish settlement.
Cleanup closes the exact owned pane and never issues a workspace close or runtime cancellation.
Other panes and ambiguous bindings are retained.

An uncertain creation remains pending rather than allocating a duplicate.
Inspect the journal and Herdr topology to resolve such a lost reply; this initial path does not automatically adopt an unbound orphan by its label.
Lost binding and report replies reconcile through exact readback and retained sequence numbers.
Lost attach launch replies are adopted only when the exact foreground argv is observable; otherwise they remain uncertain.
Initial attach input requires a positively idle shell, and restored views are never submitted a second attach command.

Presentation is owned on the destination host.
Run a separate native entrypoint there with its local socket and home; this path does not provision remote hosts or replace unreachable remote work locally.
The regression entrypoint is [`fm-native-supervisor.test.sh`](../tests/fm-native-supervisor.test.sh).
