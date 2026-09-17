# This drive holds backups of spark-5f4a

If you are reading this, you are probably standing in front of a machine that is gone, broken, or
new. Everything you need is on this drive. You do not need the internet, the original machine, or
the git repository this came from.

**Read this page first, then run `./restore.sh --target <a fresh directory>`.**

---

## What this drive is

A weekly history of one Linux user's home directory, taken with `rsync --link-dest`, so each
snapshot looks like a complete copy while sharing unchanged files with the snapshots around it.

```
backups/<hostname>/
  snapshots/2026-09-16T18-30-00/   one dated snapshot
      MANIFEST.json                what is in it, and whether it finished
      home/                        the home directory, as it was
  latest -> snapshots/...          the one to restore unless you have a reason not to
  verify/                          checksum records, used to detect silent corruption
  backup.log                       one line per run
```

**It is not a bootable system image.** The operating system, drivers, CUDA, and installed packages
are not here. Restoring gives you back data, configuration, and the state of two assistants. It
does not give you a machine that boots into the old system.

## What to do

```bash
# 1. See what is here. This reads the manifest and prints the source machine and date.
./restore.sh --target /tmp/inspect --dry-run

# 2. Restore into an empty directory. Never point this at a home directory you still care about;
#    it refuses a non-empty target unless you pass --force, and that refusal is there for a reason.
./restore.sh --target /home/<user>
```

Pick a different snapshot with `--snapshot 2026-09-09T02-00-00`. List them with
`ls backups/*/snapshots`.

The script refuses any snapshot whose manifest says `incomplete`. That marking means the drive was
unplugged or the run was interrupted part-way, and such a copy is missing files without saying which.

## After the files are back

Restoring files is the easy half. `restore.sh` prints this list too, because a restore that stops
at the files looks finished while the machine still does not work:

1. **Install the system-level software.** See `docs/system-level.md` in the `dgx-backup`
   repository, restored at `~/Projects/GitHub/dgx-backup`.
2. **Services come back disabled, on purpose.** A partly restored machine that starts a Telegram
   bridge will answer messages using stale state. Enable them only when the rest is ready:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now claude-tg.service claude-tg-watchdog.service codex-tg.service stt-api.service
   ```
3. **Some credentials expire.** The Claude OAuth refresh token lasts 30 days, so `claude` will
   likely ask for `/login`. Telegram bot tokens do not expire.
4. **Different architecture, different binaries.** `~/.local/bin/codex` and `codex-code-mode-host`
   are built for one architecture. Check `MANIFEST.json` for what the source machine was, and
   re-download them if it differs from yours.
5. **Check the SSH key kept mode 600.** Git over SSH refuses a world-readable private key.

## If something looks wrong

- **`restore.sh` says the snapshot is incomplete.** Use an earlier one: `ls backups/*/snapshots`.
  Every completed snapshot is independently restorable; they share storage but not fate.
- **A file is corrupt.** Run `verify.sh --snapshot <name> --full`. It re-reads the snapshot and
  compares against the checksums recorded when the backup ran, reporting any file whose contents
  changed while size and modification time did not, which is what disk rot looks like. It does not
  overwrite the recorded checksums when it finds something: the old record is the evidence, and the
  new hashes go to a `.suspect` file beside it. An earlier snapshot may still hold a good copy.
- **The drive will not mount.** It is ext4. A Mac or Windows machine cannot read it without extra
  software; use a Linux machine.

## What this drive does not protect against

Stated plainly, because a backup that is trusted for more than it does is worse than none:

- **It is not encrypted.** A deliberate decision by the drive's owner, who keeps it physically
  secured and judges that sufficient. Handle it accordingly: it contains SSH private keys, API
  tokens, and patient-derived research data. That inventory is stated as a fact about what is on
  the drive, not as an argument against the decision.
- **It is one drive.** Drives fail, and the day you need this one is the day the other copy is
  already gone, so the two failures are not independent.
- **It holds one machine's home directory, not a bootable system.** See "What this drive is".
