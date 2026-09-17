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

| Risk | Planned response |
|---|---|
| The backup drive fails when the source machine is already unavailable | A single drive cannot solve this; see open issues |
| Silent corruption | Store checksums after backup in `verify/` and compare on later runs; alert if checksums change despite neither side having an expected change |
| Synchronization propagates source mistakes | Retain historical hard-link snapshots |

ext4 does not checksum file data, and ordinary rsync synchronization alone does
not establish that unchanged data remains intact. Each backup will also read
SMART reallocated sectors, pending sectors, power-on hours, and start/stop counts
to flag signs of drive failure early.

## Restore validation

Once written, `restore.sh` must be exercised in a temporary directory to verify
that it restores usable configuration. Results and measured duration will be
recorded in `docs/restore-drill.md`. The one-hour recovery target remains
unverified until tested.

## Planned automation

- A weekly systemd user timer. If the drive is absent, skip and log the run
  without treating it as a failure.
- A Telegram reminder after more than two weeks without a successful backup,
  using the existing watchdog notification route.
- Results written to the drive's `backup.log` and `~/logs/` after each run.

## Open issues

- **Both copies remain in one room.** Fire, theft, flooding, or another shared
  incident could destroy both. An off-site copy is outside this design. Bohan
  must confirm whether institutional storage holds another copy of the 1.3 TB
  of patient-derived data in `~/Projects`.
- **The drive is unencrypted.** This remains conditional on keeping it locked
  in the office; reconsider before that assumption changes.
- **No restore drill has been performed.** The one-hour target is an estimate.
- Exclusion rules are not final, particularly retention of codex session rollouts.
- The scope table does not explicitly include `~/.local/bin` or `~/.ssh`,
  despite the symlink rationale and private-key exposure described above.
  Their inclusion or reconstruction needs to be specified before implementation.

## Related records

- Operational logs: `~/logs/`, named by Bohan's local calendar date.
- Shared environment facts: `~/Shared/SERVER.md`.
