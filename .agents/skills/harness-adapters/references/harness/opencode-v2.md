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
| Session service | A qualified session uses `--standalone`; its leased child server runs as `shuvcode serve --stdio --port 0`, exits with the owning client, and parents tool subprocesses. The persistent `shuvcode serve --service` process is shared infrastructure and is never accepted as session or lock identity. |
| Environment | Harness processes carry `OPENCODE_CONFIG_DIR=/home/shuv/.config/shuvcode`; tool subprocesses additionally carry `OPENCODE_TERMINAL=1`. |

## Detection evidence

Ancestry is the reliable path: an exact `shuvcode` process name, or a node interpreter whose argument string or argv[0] references the shuvcode launcher or install path.
The published `OPENCODE_*` env signals share the upstream opencode namespace and can survive a stored terminal environment, so they are corroborating evidence only and drive no verdict.
Process detection is structural; it never executes a stranger binary during an ancestry walk.

## Dispatch

Ship and scout launches use `shuvcode --standalone --auto --prompt`; `--standalone` gives each worker a leased server whose lifetime matches the session, while `--auto` auto-approves permissions that are not explicitly denied so an unattended worker never parks on a permission dialog.
The root command accepts only `--standalone`, `--server`, `--auto`, `--continue`, `--session`, `--prompt`, and a directory; it rejects `--model` with usage text and exit 1, so a requested model is not passed and the worker runs on the host's configured model.
The worker wiring writes `.opencode/plugins/package.json` only when the project has none, so a project that tracks that file keeps its own copy.
Secondmate launches are refused until that role is qualified.
Busy state, exit command, interrupt, resume, model selection, and effort flags for this adapter have no verified facts yet; verify them before a control plan relies on them.
