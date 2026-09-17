#!/usr/bin/env bash
# Take one hard-linked snapshot of $HOME onto the backup drive.
#
#   backup.sh [--dry-run] [--source DIR] [--dest MOUNTPOINT]
#
# Why hard links: a plain mirror propagates mistakes. Delete something by accident and the next
# sync deletes it from the backup too, so the good copy is gone. --link-dest keeps every previous
# snapshot while sharing the blocks of files that did not change, which is almost all of ~/Projects.
#
# The drive is found by filesystem LABEL, never by /dev/sdX: the letter moves when devices are
# plugged in a different order, and writing 1.4 TB to the wrong disk is not recoverable.

set -uo pipefail

LABEL=${LABEL:-DGXBACKUP}
SRC=${SRC:-$HOME}
HOSTNAME_S=$(hostname -s)
DRYRUN=0
DEST=""

while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRYRUN=1 ;;
    --source) SRC=$2; shift ;;
    --dest) DEST=$2; shift ;;
    *) echo "unknown argument: $1"; exit 1 ;;
    esac
    shift
done

die() { echo "✗ $*" >&2; exit 1; }
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

# ---------- locate the drive ----------
if [ -z "$DEST" ]; then
    DEV=$(lsblk -rno PATH,LABEL | awk -v l="$LABEL" '$2==l {print $1; exit}')
    [ -n "$DEV" ] || die "no partition labelled $LABEL. Is the drive plugged in?"
    DEST=$(findmnt -n -o TARGET --source "$DEV" | head -1)
    [ -n "$DEST" ] || die "$DEV is present but not mounted. Run: udisksctl mount -b $DEV"
fi
[ -d "$DEST" ] || die "destination is not a directory: $DEST"
[ -w "$DEST" ] || die "cannot write to $DEST. Run: sudo ~/Scripts/prep-backup-drive.sh"

# ext4 is not cosmetic here. Without hard links every snapshot is a full 1.4 TB copy, and without
# permissions and symlinks a restore produces a home directory that does not work.
FSTYPE=$(findmnt -n -o FSTYPE --target "$DEST" | head -1)
[ "$FSTYPE" = "ext4" ] || die "$DEST is $FSTYPE, expected ext4. Snapshots need hard links."

ROOT="$DEST/backups/$HOSTNAME_S"
SNAPS="$ROOT/snapshots"
# Local calendar day, not UTC: the system timezone is America/Los_Angeles as of 2026-09-15, so
# `date` is already local. Snapshot names must line up with the log files, which use the same rule.
STAMP=$(date '+%FT%H-%M-%S')
NEW="$SNAPS/$STAMP"
LATEST="$ROOT/latest"
LOG="$ROOT/backup.log"

mkdir -p "$SNAPS" "$ROOT/verify" || die "cannot create $SNAPS"

# Keep the restore path and its instructions on the drive itself, refreshed every run. On the day
# this is needed the repository may be unreachable, so the drive has to be self-sufficient.
REPO=$(cd "$(dirname "$0")/.." && pwd)
for f in "$REPO/drive/README-RESTORE.md:README-RESTORE.md" "$REPO/scripts/restore.sh:restore.sh" \
         "$REPO/scripts/verify.sh:verify.sh"; do
    src=${f%%:*}; dst=${f##*:}
    [ -f "$src" ] && cp -p "$src" "$DEST/$dst"
done
chmod +x "$DEST/restore.sh" "$DEST/verify.sh" 2>/dev/null

# ---------- exclusions ----------
# Rebuildable content only, and only where the rebuild method is written down (see README).
# Forgetting to exclude something costs disk space. Forgetting to *include* something loses it
# silently, which is why this is an exclusion list and not an inclusion list.
EXCLUDES=(
    "--exclude=.cache/"
    "--exclude=.nv/"
    "--exclude=.bun/"
    "--exclude=snap/"
    "--exclude=codex-upgrade-0.154/"
    "--exclude=codex-assistant-test/"
    "--exclude=**/.venv/"
    "--exclude=**/venv/"
    "--exclude=**/node_modules/"
    "--exclude=**/__pycache__/"
    "--exclude=*.pyc"
    # Never descend into the drive itself, however it happens to be mounted.
    "--exclude=$DEST"
    "--exclude=/media/"
    "--exclude=/mnt/"
)

# ---------- pick the previous snapshot to link against ----------
PREV=""
if [ -L "$LATEST" ] && [ -d "$LATEST" ]; then
    PREV=$(readlink -f "$LATEST")
    log "linking unchanged files against $(basename "$PREV")"
else
    log "no previous snapshot: this run copies everything"
fi

RSYNC=(rsync -aHAX --numeric-ids --info=progress2 --no-inc-recursive)
[ -n "$PREV" ] && RSYNC+=(--link-dest="$PREV/home")
RSYNC+=("${EXCLUDES[@]}" "$SRC/" "$NEW/home/")

if [ "$DRYRUN" -eq 1 ]; then
    echo "would write to : $NEW"
    echo "would link from: ${PREV:-（none）}"
    echo "command        : ${RSYNC[*]}"
    exit 0
fi

# ---------- run ----------
mkdir -p "$NEW/home" || die "cannot create $NEW"
log "snapshot $STAMP starting"
START=$(date +%s)

# The manifest is written twice: once now marked incomplete, once at the end marked complete.
# If the drive is unplugged mid-run the leftover directory still says what it is, so a later
# restore does not mistake a half-finished copy for a good one.
write_manifest() {  # $1 = status, $2 = elapsed seconds or empty
    python3 - "$NEW/MANIFEST.json" "$1" "${2:-}" "$STAMP" "$HOSTNAME_S" "$SRC" "${PREV:-}" \
             "$(printf '%s\n' "${EXCLUDES[@]}")" <<'PY'
import json, os, platform, subprocess, sys, time
out, status, elapsed, stamp, host, src, prev, excludes = sys.argv[1:9]

def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ""

top = {}
if status == "complete":
    home = os.path.join(os.path.dirname(out), "home")
    for name in sorted(os.listdir(home)):
        p = os.path.join(home, name)
        n = size = 0
        if os.path.isdir(p) and not os.path.islink(p):
            for r, _, fs in os.walk(p, onerror=lambda e: None):
                for f in fs:
                    n += 1
                    try:
                        size += os.lstat(os.path.join(r, f)).st_size
                    except OSError:
                        pass
        else:
            # A plain file or symlink directly under the home directory. os.walk yields nothing for
            # these, so an earlier version reported "0 files" for a snapshot that clearly had some.
            # ~/.claude.json is exactly this case, and restore.sh prints these counts to the operator.
            n = 1
            try:
                size = os.lstat(p).st_size
            except OSError:
                pass
        top[name] = {"files": n, "bytes": size}

json.dump({
    "schema": 1,
    "status": status,                      # complete | incomplete
    "snapshot": stamp,
    "finished_local": time.strftime("%F %T %Z"),
    "finished_utc": time.strftime("%F %T UTC", time.gmtime()),
    "elapsed_seconds": int(elapsed) if elapsed else None,
    "host": host,
    "source": src,
    "linked_against": os.path.basename(prev) if prev else None,
    "exclude_rules": [e for e in excludes.splitlines() if e],
    "machine": {
        "arch": platform.machine(),
        "os": sh("grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '\"'"),
        "kernel": platform.release(),
        "timezone": sh("timedatectl show -p Timezone --value"),
    },
    "versions": {
        "codex": sh("~/.local/bin/codex --version"),
        "python": platform.python_version(),
        "rsync": sh("rsync --version | head -1"),
    },
    "top_level": top,
}, open(out, "w"), indent=2, ensure_ascii=False)
PY
}

write_manifest incomplete
"${RSYNC[@]}"
RC=$?

# rsync 24 means "some files vanished while copying", which is normal on a live home directory
# (logs rotating, sockets, editor temp files). Treating it as failure would fail almost every run.
if [ $RC -ne 0 ] && [ $RC -ne 24 ]; then
    write_manifest incomplete
    log "rsync failed with $RC; snapshot left as incomplete at $NEW"
    echo "$(date '+%F %T')  FAILED rc=$RC  $STAMP" >>"$LOG"
    die "backup failed, rc=$RC"
fi
[ $RC -eq 24 ] && log "rsync reported 24 (files vanished during copy); this is expected on a live home"

ELAPSED=$(( $(date +%s) - START ))
write_manifest complete "$ELAPSED"
ln -sfn "snapshots/$STAMP" "$LATEST"

SIZE=$(du -sh "$NEW" 2>/dev/null | cut -f1)
log "snapshot $STAMP complete in $((ELAPSED/60)) min, apparent size $SIZE"
echo "$(date '+%F %T')  OK  $STAMP  ${ELAPSED}s  $SIZE  linked=${PREV:+$(basename "$PREV")}" >>"$LOG"

df -h "$DEST" | tail -1
