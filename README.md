# dgx-backup

Back up irreplaceable data from spark-5f4a to an external drive and restore it on
another Linux machine.

**Status: design agreed; scripts have not been written.** The 6 TB hard drive is
ready: ext4, label `DGXBACKUP`, mounted at `/media/dzbohan/DGXBACKUP`.
All workflows below are planned, not deployed or tested.

The recovery target is a clean Ubuntu ARM64 machine with four services running,
both agents' memories and instructions restored, and `~/Projects` back in place
within one hour. That duration is an estimate pending a restore drill.

This document records decisions and their reasons so recovery does not depend on
reconstructing a Telegram conversation.

## Scope

**Everything under `$HOME`, minus an explicit exclusion list.**

This was originally written the other way round: a list of directories to include. Vivian read
that draft and pointed out that `~/.ssh` and `~/.local/bin` were missing from it, even though the
SSH key is named elsewhere in this document. Sweeping the home directory afterwards turned up more
that the list had dropped: `~/.claude.json`, `~/.gnupg`, `~/.deepcell`, `~/Documents`, `~/.bun`.

That is the argument for inverting the rule. **An include list fails silently**: whatever you
forget is simply absent, and nothing reports it until the day you restore. **An exclusion list
fails cheaply**: whatever you forget is copied, and it costs disk space. Backups should be wrong
in the second direction.

What the home directory holds, and why the irreplaceable parts matter:

| Content | Paths | Approximate size | Why preserve it |
|---|---|---|---|
| Research data | `~/Projects` | 1.3 TB | Patient-derived images cannot be collected again |
| Lucia (Claude) | `~/.claude`, `~/Claude`, `~/.claude.json` | 13 GB | Configuration, memory, all conversations, CLAUDE.md |
| Vivian (codex) | `~/.codex`, `~/Codex`, `~/codex-assistant` | 290 MB | Instructions, long-term memory, bridge, supporting kit |
| Credentials | `~/.ssh`, `~/.gnupg` | Small | Without the SSH key a restored machine cannot reach GitHub |
| Model cache | `~/.deepcell` | 3.7 GB | Normally regenerable, but this network blocks the Hugging Face CDN, so re-downloading may not be possible. Bohan decided on 2026-09-16 to keep it |
| Operational scripts | `~/Scripts` | Small | Required by services |
| Operational logs | `~/logs` | Small | Incident history and decision records |
| Shared environment facts | `~/Shared` | Small | SERVER.md |
| User service definitions | `~/.config/systemd/user` | Small | Four services |
| Tool links | `~/.local/bin` | Small | Symlinks to the codex-assistant tools; the codex binaries there are re-downloadable |
| System setup inventory | `docs/system-level.md` (planned) | Small | How to reinstall software and recreate settings, not the binaries themselves |

This table documents what is worth knowing about the contents. **It is not the selection rule.**
The selection rule is the exclusion list below.

### Exclusions and tradeoffs

- **No bootable whole-disk clone.** It requires root, which Lucia does not have.
  DGX Spark's ARM64/NVIDIA drivers, UUIDs, and boot configuration also make a clone
  unreliable for booting different hardware. Portable data and configuration
  recovery is the goal.
- **No reinstallable binaries:** system packages, CUDA, or virtual-environment
  dependencies. Record installation inventories instead.
- **No encryption**, as agreed by Bohan on 2026-09-16, conditional on both machine
  and drive remaining locked in the office. The stated exposure includes both
  bots' tokens, Lucia's login credentials, SSH private keys, and patient-derived
  data. Reconsider encryption before the drive leaves that room or the physical
  security assumption changes.

## Why ext4

The design requires ext4 rather than exFAT for three reasons:

1. exFAT does not preserve Unix permissions. Losing them can prevent services
   from starting or make `.env` files readable by everyone.
2. exFAT does not support symbolic links. The four tools under `~/.local/bin`
   use symlinks; their link structure must survive recovery.
3. exFAT does not support hard links, required by this incremental snapshot
   design. Weekly full copies of about 1.4 TB would leave room for only about
   four copies on a 6 TB drive.

Formatting erases existing contents, and macOS and Windows cannot read ext4
natively. Bohan accepted these tradeoffs on 2026-09-16.

## Why snapshots rather than a mirror

A plain rsync mirror can propagate accidental deletions and corrupted files to
the backup, replacing the last good copy at the next synchronization.

The plan uses weekly `rsync --link-dest` snapshots. Unchanged files share storage
through hard links to the previous snapshot; historical versions remain
available after source files change or disappear. Of roughly 1.4 TB, about 1.3 TB
is mostly static research data, so a dozen or more snapshots may add only tens
of GB. This is an estimate, not a measured storage budget.

Connecting the drive once a week is sufficient for the planned schedule; it
need not remain connected continuously.

## Drive layout and snapshot identification

The drive will carry its own recovery instructions and script, independent of
this repository. The restore script will read manifests rather than guess.

```text
/media/dzbohan/DGXBACKUP/
  README-RESTORE.md
  restore.sh
  backups/
    spark-5f4a/
      snapshots/
        2026-09-16T18-30-00/
          MANIFEST.json
          home/
        2026-09-23T18-30-00/
        ...
      latest -> snapshots/2026-09-23T18-30-00
      verify/
      backup.log
```

Snapshot names will use local time (`America/Los_Angeles`). `home/` will preserve
the original home-directory structure. Host directories separate machines, dated
directories retain history, and `latest` selects the default restore snapshot.
`verify/` will hold checksum history.

Each `MANIFEST.json` must record:

- Hostname, snapshot time in both local time and UTC, and backup script version.
- Included paths and the literal exclusion rules for that run, not a reference
  to documentation that may later change.
- Size and file count for each top-level entry.
- Source OS version, architecture, timezone, and key software versions, including codex.
- Whether the snapshot completed or failed partway through.

The host directory, `latest`, and manifest will identify the source, default
recovery point, contents, exclusions, and completion status.

## Exclusion rules

`docs/exclude.md` and the script must agree. Every change to this list records its date and
reason. **Exclude something only when the way to rebuild it is written down.**

Measured on 2026-09-16:

| Excluded | Size | Reason |
|---|---|---|
| `**/.venv/`, `**/venv/`, `**/node_modules/`, `**/__pycache__/` | 25.2 GB across 3,896 directories | Dependencies and generated files. Rebuilt from the inventories in `docs/system-level.md` |
| `~/.cache/` | 6.9 GB | Cache |
| `~/codex-upgrade-0.154/` | 389 MB | Download staging for one upgrade; the tarballs are re-fetchable and their sha256 are recorded in the upgrade guide |
| `~/snap/` | 345 MB | Snap per-user state, regenerated on install |
| `~/.nv/` | 236 MB | NVIDIA shader cache |
| `~/.bun/` | 117 MB | Bun runtime, reinstallable |
| `~/codex-assistant-test/` | 1 MB | Scratch copy, recreated by `cp -r ~/codex-assistant` whenever a patch is tested |
| The drive's own mount point | — | Otherwise the backup backs up the backup |

Decided to keep, against the usual instinct:

- **`~/.deepcell` (3.7 GB)** is a model cache and would normally be excluded. This network blocks
  the Hugging Face CDN, so re-downloading may be impossible without carrying files in from another
  network. Bohan decided on 2026-09-16 to keep it. **Size is not the reason; retrievability is.**
- **`~/.codex/sessions` (28 MB)** holds codex session rollouts. They carry `turn_context`, which is
  how model and reasoning effort were verified on 2026-09-14. Small and diagnostic; keep.

## Integrity and drive health

| Risk | Response |
|---|---|
| The backup drive fails when the source machine is already unavailable | A single drive cannot solve this; see open issues |
| Silent corruption | `verify.sh` stores checksums in `verify/` and compares them on later runs, reporting any file whose contents changed while its size and modification time did not |
| Synchronization propagates source mistakes | Retain historical hard-link snapshots |

ext4 does not checksum file data, and rsync alone does not establish that
unchanged data stayed intact. Each run reads SMART reallocated sectors, pending
sectors and power-on hours before writing, so a drive that is starting to fail
is flagged while it can still be replaced rather than discovered from a failed
restore.

## Restore validation

`scripts/drill.sh` rehearses a restore without a second machine. There is no
spare Linux box here, and waiting for one would mean the restore path is first
exercised on the day it is needed.

The drill is built around what actually goes wrong. A restore rarely fails
because rsync cannot copy a file. It fails because something the machine refers
to was never in scope, nobody noticed, and it is missing when it matters. That
question is answerable on this machine today. The drill:

1. checks that a concrete list of files the running system depends on is present
   in the snapshot, each entry paired with what breaks without it
2. restores everything except `~/Projects` into a temporary directory
3. checks modes and symlinks survived, because a private key restored at 644
   means no git over SSH and no error that says so
4. checks every `ExecStart=` path in the restored unit files exists inside the
   restored tree, since a unit whose binary is missing fails with a message that
   does not name the cause
5. parses the JSON and TOML configuration out of the snapshot, which catches a
   file torn by being copied while it was being rewritten
6. compares the manifest's own counts against what is really on the drive

`~/Projects` is excluded because it is 1.3 TB travelling the same rsync path as
everything else. Excluding it makes the drill cheap enough to run every week,
which is worth more than testing one invocation against larger files.

What the drill does not establish: that a bare machine boots, that the packages
in `docs/system-level.md` install cleanly on hardware nobody has tested, or that
the whole path fits in an hour. Those need a real second machine. The drill
covers the failure mode that a second machine would mostly be idle waiting for.

## Automation

A weekly systemd user timer, `dgx-backup.timer`, runs Sunday at 02:00 local.

- If the drive is absent the run exits 75, which the unit counts as success. A
  drive left at home is not a broken backup, and conflating the two would make
  the staleness alarm meaningless.
- SMART is read before writing, so a failing drive is not handed 1.4 TB.
- After more than 14 days without a successful run, a Telegram message goes out
  over `sendMessage` only. It opens no `getUpdates` poller, so it cannot steal
  inbound messages from either assistant's bridge.
- Each run appends one line to the drive's `backup.log`.

## Open issues

- **Both copies remain in one room.** Fire, theft, flooding, or another shared
  incident could destroy both. An off-site copy is outside this design. Bohan
  must confirm whether institutional storage holds another copy of the 1.3 TB
  of patient-derived data in `~/Projects`.
- **The drive is unencrypted.** This remains conditional on keeping it locked
  in the office; reconsider before that assumption changes.
- **The one-hour recovery target is unverified.** `drill.sh` checks that a
  restore is complete and coherent; it does not measure the walk from bare
  hardware to a working machine. That number stays an estimate until someone
  does it on real hardware.
- **Retention is unbounded.** Nothing prunes old snapshots yet. Hard links make
  each one cheap, but 5.4 TB of free space is not infinite, and the policy
  should be written before the drive is the thing that decides it.
- **`~/.codex/telegram/state.json` is written in place, not atomically.** Every
  other state file in the bridge is written to a temporary file and renamed,
  which rsync cannot tear. This one can in principle be copied mid-rewrite. The
  window is milliseconds on a small file, so the risk is low, but the failure is
  silent until a restore. Drill check 5 would detect it; the fix belongs in the
  bridge.

## Related records

- Operational logs: `~/logs/`, named by Bohan's local calendar date.
- Shared environment facts: `~/Shared/SERVER.md`.
