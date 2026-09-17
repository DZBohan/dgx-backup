# Restore drill results

`scripts/drill.sh` rehearses a restore without a second machine. What it does and does not establish
is described in the README under "Restore validation". This file records what actually happened when
it ran.

## 2026-09-17, snapshot `2026-09-16T17-40-14`

First run against a real snapshot. **29 of 30 checks passed.** The failure was in the drill, not the
backup.

| Check | Result |
|---|---|
| 1. Dependency files present in the snapshot | 15/15 |
| 2. Restore (everything except `Projects`) | rsync exit 0 |
| 3. Modes | `.ssh` 700, private key 600, both `.env` 600, watchdog executable |
| 3. Symlinks | **failed**, see below |
| 4. Unit `ExecStart` paths resolvable | 6/6, including `ExecStartPre` |
| 5. Configuration parses | 4/4 |
| 6. Manifest counts match the drive | matched, including `Projects` at 105,418 |

### The one failure, and why it was the drill's fault

The symlink check reported 37 broken relative symlinks, all under
`.local/share/mamba/pkgs/`. Checking the same links on the source machine showed they were
**already broken there**: conda package caches routinely contain links to siblings that were never
unpacked. The backup had reproduced them exactly.

The check was asking "is this symlink broken", when the question a restore drill needs answered is
"**did the restore break it**". Those are the same question on a synthetic snapshot containing only
working links, which is what the check had been developed against. On real data they differ by 37
entries of noise, and noise at that volume would hide the single broken link that mattered.

Rewritten to resolve each broken link against the snapshot as well, splitting three cases:

- broken in the snapshot too: already broken when the backup ran, not the backup's doing
- resolves in the snapshot but not the restore: the drill's own `Projects` exclusion
- neither: the restore lost something, and this is the only case that fails

Re-run after the fix: **30 of 30 passed**, with 38 links classified as pre-existing and **0 lost by
the restore**.

### What this run did not establish

Unchanged from the README: it did not call `restore.sh`, did not boot a machine, did not rebuild
system-level dependencies, did not restore the 1.3 TB of `~/Projects`, and did not measure the
one-hour recovery target. It establishes that the snapshot is complete and internally coherent, and
that a restore of it reproduces modes, symlinks and referenced paths.
