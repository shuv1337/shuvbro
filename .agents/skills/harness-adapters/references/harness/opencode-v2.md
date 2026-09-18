# Shuvcode (OpenCode V2 fork)

Verified on 2026-09-10 with shuvcode v2.0.0-alpha-20 on Linux.
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
| Session service | A qualified session uses `--standalone`; its leased child server runs as `shuvcode serve --stdio --port 0`, exits with the owning client, and parents tool subprocesses. The persistent `shuvcode serve --service` process is shared infrastructure; any process whose arguments carry a whole `--service` token, in any position, is never accepted as session or lock identity. |
| Environment | Harness processes carry `OPENCODE_CONFIG_DIR=/home/shuv/.config/shuvcode`; tool subprocesses additionally carry `OPENCODE_TERMINAL=1`. |

## Detection evidence

Ancestry is the reliable path: an exact `shuvcode` process name, or a node interpreter whose argument string or argv[0] references the shuvcode launcher or install path.
The published `OPENCODE_*` env signals share the upstream opencode namespace and can survive a stored terminal environment, so they are corroborating evidence only and drive no verdict.
Process detection is structural; it never executes a stranger binary during an ancestry walk.

## Guard runtime

Verified on 2026-09-18 with shuvcode v2.0.3-shuv.4 on Linux.
Shuvcode resolves a project plugin's bare imports natively and shares none of its own modules, so `import("effect")` from `.opencode/plugins/` fails until the dependency pinned in `.opencode/plugins/package.json` is installed.
Run `npm ci --prefix .opencode/plugins` in the primary checkout before starting a shuvcode lead.
A shuvcode primary whose checkout lacks that install gets a `MISSING: OpenCode V2 plugin runtime` line from `../../../bin/fm-bootstrap.sh`.
Without it the guards cannot judge a command, so in the primary checkout both plugins instead deny every `shell` permission with that install command as the reason; a worker worktree stays unaffected.
That blanket denial rides `permission.evaluate`, which shuvcode never raises for a command made only of `cd`, so it stops the lead's work but is not the cd-guard.
A project plugin cannot import shuvcode's own `Tool.Error` class; shuvcode matches the rejection on the `Tool.Error` tag, so the guards fail `execute.before` with a locally tagged error and the model receives the helper's reason as an ordinary tool failure.

## Dispatch

Ship and scout launches use `shuvcode --standalone --auto --prompt`; `--standalone` gives each worker a leased server whose lifetime matches the session, while `--auto` auto-approves permissions that are not explicitly denied so an unattended worker never parks on a permission dialog.
The root command accepts only `--standalone`, `--server`, `--auto`, `--continue`, `--session`, `--prompt`, and a directory; it rejects `--model` with usage text and exit 1, so a requested model is not passed and the worker runs on the host's configured model.
The interactive root command's `--prompt` only pre-fills the TUI composer and never submits it (verified live on shuvcode v2.0.3-shuv.4), so `bin/fm-spawn.sh` waits for the pre-filled left-bar composer and then submits it with Enter, retrying Enter only, until the shared composer classifier reads empty; a brief that never shows or never submits fails the spawn and closes the endpoint.
Under `--auto` the composer footer reads `Build auto · <model> · <effort>` with the `auto` word and `·` separators in muted truecolor, so the classifier recognises that footer from the plain row rather than the ghost-stripped one.
The worker wiring writes `.opencode/plugins/package.json` only when the project has none, so a project that tracks that file keeps its own copy.
Secondmate launches are refused until that role is qualified.
Busy state comes from the Firstmate-owned worker plugin's `session.execution.started` (busy) and its `session.execution.succeeded`, `failed`, or `interrupted` terminal event (idle), latched to the worker's own root session; shuvcode publishes no `session.status` or `session.idle` event to plugins.
Exit command, interrupt, resume, model selection, and effort flags for this adapter have no verified facts yet; verify them before a control plan relies on them.
