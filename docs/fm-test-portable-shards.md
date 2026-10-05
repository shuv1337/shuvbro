# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The original candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The 2026-08-20 proof table above is the original candidate measurement.
It is not the current lane balance.
On CI run [35393983258](https://github.com/shuv1337/shuvbro/actions/runs/35393983258) (2026-09-18) shard 1 took about 7.4 minutes and still passed.
Slower runners hit the 10-minute job cap while `tests/fm-lint.test.sh` was still passing.
`tests/fm-captain-hold-lifecycle.test.sh` alone was 184710 ms on that green run and 318156 ms on a later run that the cap cancelled.
The lanes below are longest-processing-time assignment from that green run's per-script `duration_ms` values, which is what `list_portable_parallel_1` and `list_portable_parallel_2` now execute.

| duration_ms | script |
|---:|---|
| 184710 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 127226 | `tests/fm-lint.test.sh` |
| 101373 | `tests/fm-pr-merge.test.sh` |
| 74627 | `tests/fm-test-run.test.sh` |
| 25076 | `tests/fm-arm-pretool-check.test.sh` |
| 19341 | `tests/fm-x-mode.test.sh` |
| 18798 | `tests/fm-backend-herdr.test.sh` |
| 10291 | `tests/fm-crew-state.test.sh` |
| 10222 | `tests/fm-cd-pretool-check.test.sh` |
| 6675 | `tests/fm-herdr-lab.test.sh` |
| 5182 | `tests/fm-grok-harness.test.sh` |
| 4983 | `tests/fm-send-popup-settle.test.sh` |
| 4178 | `tests/fm-composer-lib.test.sh` |
| 3874 | `tests/fm-send-strict.test.sh` |
| 3744 | `tests/fm-pi-primary-types.test.sh` |
| 2320 | `tests/fm-spawn-batch.test.sh` |
| 2284 | `tests/fm-tmux-submit-busy.test.sh` |
| 2031 | `tests/fm-send-settle.test.sh` |
| 1732 | `tests/fm-review-diff.test.sh` |
| 1413 | `tests/fm-composer-ghost.test.sh` |
| 1151 | `tests/fm-brief.test.sh` |
| 741 | `tests/fm-ensure-agents-md.test.sh` |
| 351 | `tests/fm-supervision-instructions.test.sh` |
| 58 | `tests/fm-transition-lib.test.sh` |

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 306114 ms (~5.10 min) |
| `portable-parallel-2` | 13 | 306267 ms (~5.10 min) |
| imbalance | | 153 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI jobs.
Each shard is still strictly serial in itself.
Jobs do not run two of these stateful scripts at once, and each job starts on a fresh GitHub-hosted VM, so no job reuses another job's workspace.
The split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The current 185 hints come from all five `fm-test-timing-portable-serial-*` artifacts of green CI run [37275041412](https://github.com/shuv1337/shuvbro/actions/runs/37275041412), started 2026-10-04 at 23:57 PDT.
The 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` is retained separately because Linux skips that script.
These hints total 6128642 ms of assignment weight; no current serial script is unmeasured.
A new script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of10` | 14 | 612959 ms (~10.22 min) |
| `portable-serial-2of10` | 16 | 612850 ms (~10.21 min) |
| `portable-serial-3of10` | 19 | 612817 ms (~10.21 min) |
| `portable-serial-4of10` | 20 | 612839 ms (~10.21 min) |
| `portable-serial-5of10` | 19 | 612866 ms (~10.21 min) |
| `portable-serial-6of10` | 19 | 612882 ms (~10.21 min) |
| `portable-serial-7of10` | 19 | 612818 ms (~10.21 min) |
| `portable-serial-8of10` | 19 | 612817 ms (~10.21 min) |
| `portable-serial-9of10` | 20 | 612936 ms (~10.22 min) |
| `portable-serial-10of10` | 20 | 612858 ms (~10.21 min) |
| imbalance | | 142 ms |

The current table is generated from the runner's measured hints and its public `--list --lane` interface.
These are estimated script sums, not measured wall times for the new jobs; setup and runner-speed spread require margin beyond them.
The 20-minute job cap remains a hang tripwire.

The single longest script, `tests/fm-watch-triage.test.sh` at 548389 ms, is the floor for any shard count.
It does not bound the ten-shard partition: the balanced script sums are about 613 seconds, above its 548 seconds, so splitting its assertions is not needed for this partition.
Revisit splitting it if measured CI results show it setting the critical path rather than the accumulated work in a shard.

Refresh the CI-derived hints by downloading all per-shard timing artifacts from a recent green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with measured `duration_ms` per `path`, and updating the table above.
When using several comparable recent runs, retain the slowest measurement per path:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R shuv1337/shuvbro --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 15` | The measured shard sums are about five minutes, with headroom for slower runners. |
| portable serial 1-10 | job `timeout-minutes: 20` | Estimated script sums are about ten minutes; the cap remains a hang tripwire with setup and runner-speed margin. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
