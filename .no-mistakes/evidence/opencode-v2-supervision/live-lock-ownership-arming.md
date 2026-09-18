# Live: V2 watch-arm proves session-lock ownership before arming

Product: shuvcode v2.0.8-shuv.1, `shuvcode serve --port 4977` (private server, isolated XDG dirs), server pid 3773062.
Primary: isolated clone of target commit 0f78827 with `.opencode/plugins` + effect installed, `state/demo.meta` present (arming needed).
`bin/fm-watch-arm.sh` in the clone was replaced by a recorder so an arm attempt is observable; everything else is real.
One root session at the clone location; each step sent a real prompt and `session.execution.succeeded` was observed on `/api/event`.

| step | state/.lock | terminal event seen | fm-watch-arm.sh spawned |
|---|---|---|---|
| 1 | absent | yes | no |
| 2 | 3777742 (live unrelated `sleep 900`) | yes | no |
| 3 | malformed (two pids, my driver typo) | yes | no |
| 4 | 3773062 (the session's own server) | yes | **yes** |

Recorder log (step 4 only):

    13:41:13 fm-watch-arm.sh --restart (ppid=3773062)

The arm child's parent is the lock pid, i.e. the plugin host process is the process the lock names.
The lead agent later ran the real `bin/fm-session-start.sh`, which printed `lock acquired: harness pid 3773062` - the same pid.
Stopping the server removed the arm child (plugin cleanup).
