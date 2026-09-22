# dgx-backup

Back up irreplaceable data from spark-5f4a to an external drive and restore it on
another Linux machine.

**Status: running weekly.** The 6 TB drive is ext4, labelled `DGXBACKUP`, mounted
at `/media/dzbohan/DGXBACKUP` when connected. The first full snapshot completed on
2026-09-17. The scheduled run on 2026-09-18 took 5m35s, left 5 snapshots on the
drive with 4.2 TB free, and passed the restore drill, 30 checks, 0 failed.

`backup.sh`, `verify.sh` and `drill.sh` now run weekly against real snapshots.
Two limits remain: `restore.sh` has never been run on a second machine, so the
one-hour recovery target below is still an estimate, and the drive is not
permanently attached, so a run finds it only if it is plugged in by Thursday
night.

The recovery target is a clean Ubuntu ARM64 machine with four services running,
both agents' memories and instructions restored, and `~/Projects` back in place
within one hour. That duration is an estimate. Nothing here has measured it.

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
| A site-wide incident destroys machine and backup together | Partly addressed: the drive is stored away from the machine rather than beside it |
| Silent corruption | `verify.sh` records checksums in `verify/` and compares checked files with earlier records, reporting content changes when size and modification time remain unchanged within its tolerance |
| Synchronization propagates source mistakes | Retain historical hard-link snapshots |

ext4 does not checksum file data, and rsync alone does not verify unchanged file
contents. By default, `verify.sh` hashes new or changed files and a sample of
unchanged files; `--full` hashes all files. Sampled verification does not check
every unchanged file on every run.

**The sample rotates.** It walks the file list in path order, resuming where the
last run stopped, so every file is reached in `ceil(N / sample)` runs: about 114
weeks for this machine's 226,660 files at 2,000 a week. A byte budget (20 GB by
default, `VERIFY_SAMPLE_BYTES`) ends a window early when it lands on large files,
so a weekly run stays bounded.

This replaced a fixed random seed that drew the same 2,000 files every week
forever, leaving 224,000 never re-read. Those are the ones that matter: research
data in `~/Projects` sits untouched for years, which is exactly where silent
corruption happens and where nothing else would notice it.

Reseeding randomly each week would not have fixed it. Independent weekly draws
are a coupon-collector problem, so full coverage would take roughly 1,400 weeks
rather than 114.

**What sampling does and does not establish.** A clean weekly sample does not mean
the drive is clean. It means there is no *widespread* corruption. With 2,000 of
226,701 files sampled, corruption affecting 0.1% of files is caught with 86%
probability in one week and 99.97% within four; at 0.5% it is effectively
certain. That is the realistic failure, since a degrading drive damages sectors in
quantity rather than one file in isolation. A single rotted file has a 0.88%
chance of being sampled in a given week and is otherwise found when the rotation
reaches it, which can take up to 114 weeks.

**And a rotted file usually cannot be recovered from an older snapshot**, contrary
to what is intuitive about keeping history. Hard links mean a file unchanged
between snapshots is one set of blocks, not one per snapshot: an unchanged file in
`~/Projects` carries the same inode in every snapshot that lists it, verified on
this drive. Snapshots
protect against deletion and mistaken edits, which give the new version its own
blocks. They do not protect against media decay. That protection would need a
second physical copy, which this design does not have.

**Where the decay happens changes what the system does**, and not in the obvious
way. rsync decides a file is unchanged from its size and modification time,
without reading it, which produces three different outcomes:

| Where | What happens |
|---|---|
| The source decays silently (size and mtime unchanged) | rsync sees no change and hard-links the previous backup forward, so **the backup keeps the pre-decay copy**. Verified experimentally: same inode, old contents. Nobody detects the source decay, because verification reads the drive, not the source |
| A program rewrites the file, correctly or not | mtime moves, rsync copies it, and the backup faithfully holds the new content. This is right: nothing can distinguish a legitimate edit from a bad write, and a backup should not try |
| The backup drive decays | The source is fine and the copy is wrong. This is what `verify.sh` exists to find, and the one case with no second copy to recover from |

The first row is an accidental property of `--link-dest` rather than a designed
one, but it is real: for silent media decay on the source, the backup is cleaner
than the machine. It is not a safeguard to rely on, since nothing reports it.

The earliest signal for media decay is therefore SMART, read before each run, not
the checksum sample. Active since 2026-09-18; the drive's baseline at that point
was 39 power-on hours with zero reallocated, pending and uncorrectable sectors,
which is what makes later comparisons meaningful.

Installing `smartmontools` is not sufficient by itself: `smartctl` sits in
`/usr/sbin`, off a normal user's PATH, and reading a raw block device needs root
that the backup does not have. `~/Scripts/setup-smart-monitoring.sh` handles both.
The script validates its sudoers rule with `visudo -c` before installing it and
removes it again if the whole set fails to validate, because a malformed file
there disables `sudo` and repairing that needs `sudo`.

`scripts/selftest.sh` checks that the corruption detector actually detects
corruption. It builds a small snapshot, rots a file the way a disk does (content
changes while size and modification time do not), and asserts that the failure is
caught, that the file is named, and that the run does not overwrite the record it
should be comparing against. A detector never fed a known positive reports
success whether or not it works, and on 2026-09-17 this one did not work.

When a run finds corruption it leaves the existing record in place and writes the
new hashes to a `.suspect` file beside it, because the old record is the evidence.

Each backup run reads SMART reallocated sectors, pending sectors, and power-on
hours before writing, to identify signs of drive failure. SMART cannot predict
every failure.

## Restore validation

`scripts/drill.sh` copies a snapshot into a temporary directory and checks selected
recovery requirements without sudo or a spare Linux machine. This allows regular
checks before a second machine is available.

The six checks are:

1. Check a fixed list of required snapshot paths. Each entry records why it is needed.
2. Copy the snapshot into a temporary directory, excluding `~/Projects`.
3. Check selected permissions, the watchdog's executable bit, and broken relative
   symlinks. Absolute symlink targets are not checked.
4. Check the first token of `ExecStart` entries in restored service files. Map
   `%h` and `/home/dzbohan` into the restored tree. Paths under `/usr/bin/`,
   `/bin/`, and `/usr/local/bin/` are accepted without checking their existence.
5. Parse four selected JSON and TOML files from the restored copy. This can detect
   malformed files, including some incomplete writes, but does not validate their
   settings or consistency with other files.
6. Compare file counts for entries listed in the manifest with the snapshot.
   This checks counts, not file contents or entries omitted from the manifest.

`~/Projects` contains 1.3 TB and uses the same rsync copy mechanism. Excluding it
keeps the copy small enough to run every week, which it does: since 2026-09-17
`backup-if-present.sh` runs the drill after backup and verify. The manifest check still counts
its snapshot files, but the drill does not test copying or reading all of its data.

The drill invokes rsync directly, not `restore.sh`. It does not prove that a clean
machine boots, dependencies install, services start, or recovery finishes within
one hour. Those outcomes require a full recovery exercise on a suitable machine.

## Automation

The `dgx-backup.timer` systemd user timer runs Friday at 00:00 local, which is
Thursday night. It was Sunday 02:00 until 2026-09-17; the drive travels home at
weekends, so a weekend schedule would have found it unplugged and skipped quietly
most weeks.

Each run is backup, then verify, then drill.

- If the drive is absent, the run exits with code 75, which the unit treats as
  success. This distinguishes a skipped run from an error; the staleness check
  tracks how long it has been since a successful backup.
- SMART is read before writing to check for signs of drive failure.
- After more than 14 days without a successful backup, a Telegram reminder is
  sent using `sendMessage`. No `getUpdates` poller is started, so the reminder
  does not compete with either assistant's bridge for incoming messages.
- After backup and verify, the run rehearses a restore with `drill.sh`, needing
  ~17 GB of scratch space. Duration depends almost entirely on the page cache:
  measured at about 15 minutes cold and 12 seconds when the snapshot's non-
  `Projects` files are still resident, which on a 121 GB machine they often are.
  The first scheduled midnight run, 2026-09-18, took 270 seconds, between the two.
  It is skipped with a warning when `/tmp`
  has under 40 GB free, because a drill that dies for lack of space says nothing
  about the backup. `SKIP_DRILL=1` skips it deliberately.
- A failing drill sends a Telegram message and makes the unit fail, but does not
  undo the recorded backup success. The backup succeeding and the snapshot being
  restorable are different questions, and treating a drill failure as a missing
  backup would fire the staleness alarm on a drive that is fine.
- Each run appends a result line to the drive's `backup.log`.

## Retention

**Policy: keep every snapshot. Nothing is pruned automatically.**

Decided by measurement rather than convention, because the usual advice (keep N
weeklies, M monthlies) assumes snapshots cost something.

Measured 2026-09-17, over the backup's own scope:

| | Files | Size |
|---|---|---|
| Everything | 235,845 | 1427.4 GB |
| Changed in the last 7 days | 1,966 | **1.2 GB** |
| Changed in the last 30 days | 22,184 | 7.3 GB |

A `--link-dest` snapshot allocates blocks only for files that changed, so after
the 1.3 TB baseline each weekly snapshot costs roughly **1.2 GB**.

Measured for real on 2026-09-17, with a second snapshot taken 19 hours after the
first: **0.34 GB added, in 4 seconds**, against an apparent size of 1.3 TB. The
copy was smaller than the 7-day projection above because less than a day had
passed, and the run confirms the mechanism rather than the weekly figure. Against 4.2 TB
free, that is decades of weekly history. Inodes are not a constraint either:
193,364 used of 183 million, and a snapshot adds about one inode per directory
rather than one per file.

Pruning would also recover far less than it appears to. Hard links mean an old
snapshot shares blocks with every later snapshot still holding the same file, so
deleting the oldest frees only what changed after it, not its apparent size.
Deleting a 1.3 TB snapshot would return on the order of 1.2 GB.

**An independent copy: `backup.sh --full`.** Ordinary snapshots share blocks, so
they do not protect against the media decaying under them. A `--full` run writes
every file again and shares nothing with the existing chain, which is the only way
to hold two physical copies of data that never changes. It costs another 1.3 TB;
the drive fits about three more. Bohan's plan as of 2026-09-17 is to take one
roughly annually.

It protects against localised decay, not against the drive failing, since both
copies live on the same disk. The run refuses to start if free space is short,
rather than filling the drive overnight.

**What would overturn this.** These figures describe a home directory whose bulk
is static research data. A week that reprocesses or reorganises `~/Projects`
would write a delta in the hundreds of gigabytes. If that becomes common,
re-measure rather than assume these numbers still hold.

**If pruning is ever needed**, it is a deliberate manual act, not a scheduled
one. Snapshots share storage but not fate, so any complete snapshot can be
removed without harming the others:

```bash
ls backups/<host>/snapshots                      # choose one, oldest first
head -5 backups/<host>/snapshots/<name>/MANIFEST.json
rm -rf backups/<host>/snapshots/<name>           # never the target of `latest`
rm -f  backups/<host>/verify/<name>.sha256       # and its checksum record
```

Confirm `latest` does not point at what you are deleting. `backup.sh` links each
new snapshot against `latest`, so removing that one costs the next run its
sharing and makes it a full 1.3 TB copy.


## Open issues

- **The drive is unencrypted, by decision.** Bohan chose this and reaffirmed it
  on 2026-09-16 knowing the drive holds SSH private keys, bot tokens and
  patient-derived research data, on the basis that he keeps it physically
  secured. Recorded here so that whoever handles the drive knows what is on it,
  not as an open question.
- **The one-hour recovery target is unverified.** `drill.sh` checks selected
  files and metadata. It does not measure recovery from bare hardware to a
  working machine. The target remains an estimate until a full recovery is timed.
- **Cross-file consistency is not guaranteed.** `~/.codex/telegram/state.json`
  was rewritten in place until 2026-09-17 and is now written to a temporary file
  and renamed, so a backup can no longer catch it mid-replacement. That closes
  the torn-file case for one file. It does not make a snapshot a consistent
  point in time across files: the backup reads a live home directory over
  several hours, and two files written minutes apart can land in the snapshot on
  either side of a change.

## Related records

- Operational logs: `~/logs/`, named by Bohan's local calendar date.
- Shared environment facts: `~/Shared/SERVER.md`.
