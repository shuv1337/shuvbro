# Shuvcode (OpenCode V2 fork)

Native shared-service qualification is pending; [runtime verification](../../../../../docs/verification/runtime-backends.md#native-shared-service-qualification-status) owns the actual isolated v2.0.22-shuv.1 evidence and remaining live matrix.
This is a fork of OpenCode V2 distributed as `shuvcode`, never sloppy-matched as V1 `opencode` and never claimed as the upstream `opencode2` beta.

## Identity

Adapter id is `opencode-v2`.
`../../../bin/fm-harness.sh` prints `opencode-v2` for a shuvcode process tree and `opencode` only for a real V1 `opencode` binary.
`../../../bin/fm-session-lock-lib.sh` recognizes the shuvcode process as the home's harness for the fleet lock, so a shuvcode primary can acquire `state/.lock` from a tool subprocess.

## Process shape (verified)

| Fact | Value |
|---|---|
| Launcher | `~/.local/bin/shuvcode` is a node script (`#!/usr/bin/env node`) installed from the `shuvcode` npm package. |
| Binary | The npm tree's `.../shuvcode-linux-x64/bin/shuvcode`, whose process name is `shuvcode`. |
| Process tree | The launcher reports as node (comm `node-MainThread` on modern Node on Linux) with `node <launcher> ...` arguments; it runs the `shuvcode` binary. Tool subprocesses are children of the session service, not of a TUI named `opencode`. |
| Session service | Native primary and worker launches use the normal shared service. Its `serve --service` process is an ancestry barrier, never a home-lock owner; a primary model shell requires the supplemental exact TUI/session proof. |
| Environment | Harness processes carry `OPENCODE_CONFIG_DIR=/home/shuv/.config/shuvcode`; tool subprocesses additionally carry `OPENCODE_TERMINAL=1`. |

## Detection evidence

Ancestry is the reliable path: an exact `shuvcode` process name, or a node interpreter whose argument string or argv[0] references the shuvcode launcher or install path.
The published `OPENCODE_*` env signals share the upstream opencode namespace and can survive a stored terminal environment, so they are corroborating evidence only and drive no verdict.
Process detection is structural; it never executes a stranger binary during an ancestry walk.

## Guard runtime

The historical private-server observations are not qualification of the native shared-service route.
Shuvcode resolves a project plugin's bare imports natively and shares none of its own modules, so `import("effect")` from `.opencode/plugins/` fails until the dependency pinned in `.opencode/plugins/package.json` is installed.
Run `npm ci --prefix .opencode/plugins` in the primary checkout before starting a shuvcode lead.
A shuvcode primary whose checkout lacks that install gets a `MISSING: opencode-v2-runtime` line from `../../../bin/fm-bootstrap.sh`.
Without it the native registered lead cannot safely judge shell calls; unrelated workers stay outside lead-only policy.
That blanket denial rides `permission.evaluate`, which shuvcode never raises for a command made only of `cd`, so it stops the lead's work but is not the cd-guard.
A project plugin cannot import shuvcode's own `Tool.Error` class; shuvcode matches the rejection on the `Tool.Error` tag, so the guards fail `execute.before` with a locally tagged error and the model receives the helper's reason as an ordinary tool failure.

## Dispatch

Before dispatch publishes task runtime state or acquires an isolated copy, `bin/fm-opencode-v2-capability.mjs` checks the qualified installed version, native launch flags and pinned Effect guard runtime.
Unsupported builds or missing runtime capabilities refuse with installation/qualification instructions; the probe never discovers or starts a managed service.
Ship and scout launches use `bin/fm-opencode-v2-launch.sh` for both default and explicit models.
Its header owns the shared-service creation, exact recorded session, unattended permissions and queued admission mechanics.
The root command accepts only `--standalone`, `--server`, `--auto`, `--continue`, `--session`, `--prompt`, and a directory.
It rejects `--model` and `--effort` with usage text and exit 1.
A requested model is validated against the same shared service catalog before creating its worker; an unspecified variant resolves to native `default`.
The worker's native busy plugin matches the exact recorded session rather than adopting the first root event at that location.
That helper's header owns the CLI/API mechanics; it does not change project configuration, saved preferences, or permission policy.
Firstmate maps its supported effort levels onto the requested model's variant.
An effort with no `provider/model` stays in task metadata and leaves the default root launch unchanged.
Launch admits the brief through the native API before attaching its exact `--auto` TUI.
`bin/fm-spawn.sh` accepts current-generation exact-worker execution events as submission proof, including a short turn that already finished.
`tests/fm-opencode-v2-worker-live-e2e.test.sh` is an opt-in isolated-XDG/shared-service worker probe, pending a new live run; its former private-server result is not evidence for the current launcher.
Under `--auto` the composer footer reads `Build auto · <model> · <effort>` with the `auto` word and `·` separators in muted truecolor, so the classifier recognises that footer from the plain row rather than the ghost-stripped one.
The worker wiring writes `.opencode/plugins/package.json` only when the project has none, so a project that tracks that file keeps its own copy.
Secondmate launches are refused until that role is qualified.
Busy state comes from the Firstmate-owned worker plugin's `session.execution.started` (busy) and its `session.execution.succeeded`, `failed`, or `interrupted` terminal event (idle), latched to the worker's own root session; shuvcode publishes no `session.status` or `session.idle` event to plugins.
`bin/fm-opencode-v2-session.mjs` reconciles the exact recorded worker through native `session.get` and `session.active`, and interrupts that exact session before pane lifecycle actions or explicitly approved discard.
Teardown refuses active or unverifiable native execution; a dead pane is not evidence that the worker stopped.
The fork resumes durable in-flight claims at boot with at-least-once replay risk, including repeated side effects.
After restart, cleanup requires exact-session successor cancellation or the conservative settled-idle proof owned by the [V2 supervision protocol](../../../../../docs/supervision-protocols/opencode-v2.md).
Unproven successors remain visibly unproven; confirmed cancellation or settlement records the successor binding.
`--force` discard without proof accepts that a later service start may resume work in a removed isolated copy; it never reports confirmed cancellation.
Portable regressions and isolated installed-fork probes cover these lifecycle paths; combined shared-service/Herdr qualification remains pending.
Unattended wildcard permission is scoped to the recorded worker session and is inherited by its native child sessions, never a global service policy.
