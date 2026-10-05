Your scout task has been promoted to a ship task, mode=local-only. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Install the tool locally.

## Firstmate spec
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/install-tool`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. These ship instructions supersede the scout delivery rules and report-based Definition of done. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule.
Your scout brief allowed writes to named paths outside the worktree. That allowance was scout-only and is revoked now: stay inside this worktree; modify nothing outside it.

7. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or ship-time instructions.

# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/install-tool`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/install-tool` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
