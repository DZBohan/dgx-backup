#!/usr/bin/env bash
# Restore a snapshot onto a machine.
#
#   restore.sh --target DIR [--snapshot NAME|latest] [--dest MOUNTPOINT] [--dry-run] [--force]
#
# This script is copied to the root of the drive by backup.sh, because on the day it is needed the
# repository may not be reachable. It must work with nothing but the drive and a shell.
#
# It never writes into a non-empty target without --force. The likely mistake on a bad day is
# pointing this at a live home directory and overwriting work that was fine.
#
# What it does NOT do, on purpose:
#   - install packages, drivers, CUDA, or Python dependencies. See docs/system-level.md.
#   - enable systemd services. The unit files are restored; starting them is a decision, and a
#     half-restored machine that starts a Telegram bridge would answer messages with the wrong
#     state. The script prints the commands instead.

set -uo pipefail

LABEL=${LABEL:-DGXBACKUP}
SNAPNAME=latest
TARGET=""
DEST=""
DRYRUN=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
    --target) TARGET=$2; shift ;;
    --snapshot) SNAPNAME=$2; shift ;;
    --dest) DEST=$2; shift ;;
    --dry-run) DRYRUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1"; exit 1 ;;
    esac
    shift
done

die() { echo "✗ $*" >&2; exit 1; }
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

[ -n "$TARGET" ] || die "--target is required. Use a fresh directory, not a home you care about."

# ---------- find the drive and the snapshot ----------
if [ -z "$DEST" ]; then
    # The script may be sitting on the drive itself; prefer that copy's location.
    SELF_DIR=$(cd "$(dirname "$0")" && pwd)
    if [ -d "$SELF_DIR/backups" ]; then
        DEST="$SELF_DIR"
    else
        DEV=$(lsblk -rno PATH,LABEL | awk -v l="$LABEL" '$2==l {print $1; exit}')
        [ -n "$DEV" ] || die "no partition labelled $LABEL and no backups/ next to this script"
        DEST=$(findmnt -n -o TARGET --source "$DEV" | head -1)
        [ -n "$DEST" ] || die "$DEV is present but not mounted"
    fi
fi

HOSTS=$(ls -1 "$DEST/backups" 2>/dev/null) || die "no backups/ under $DEST"
COUNT=$(echo "$HOSTS" | grep -c . || true)
if [ "$COUNT" -eq 0 ]; then
    die "no host directories under $DEST/backups"
elif [ "$COUNT" -gt 1 ]; then
    # More than one machine has been backed up here, so the choice is not obvious and guessing
    # would silently restore the wrong machine.
    echo "several hosts are backed up on this drive:"
    echo "$HOSTS" | sed 's/^/  /'
    die "pick one with HOST=<name> $0 ..."
fi
HOSTNAME_S=${HOST:-$HOSTS}
ROOT="$DEST/backups/$HOSTNAME_S"

if [ "$SNAPNAME" = latest ]; then
    SNAP=$(readlink -f "$ROOT/latest" 2>/dev/null) || die "no latest symlink under $ROOT"
else
    SNAP="$ROOT/snapshots/$SNAPNAME"
fi
[ -d "$SNAP/home" ] || die "not a snapshot: $SNAP"
MAN="$SNAP/MANIFEST.json"
[ -f "$MAN" ] || die "snapshot has no MANIFEST.json, refusing to guess what is in it"

# ---------- read the manifest rather than guessing ----------
# Everything below comes out of the manifest: which machine, when, what was excluded, and whether
# the copy finished. A restore that guesses is how you end up half-restoring an aborted snapshot.
eval "$(python3 - "$MAN" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
def q(k, v): print("%s=%s" % (k, shlex.quote(str(v))))
q("M_STATUS", m.get("status"))
q("M_SNAP", m.get("snapshot"))
q("M_HOST", m.get("host"))
q("M_FIN", m.get("finished_local"))
q("M_ARCH", m.get("machine", {}).get("arch"))
q("M_OS", m.get("machine", {}).get("os"))
q("M_TZ", m.get("machine", {}).get("timezone"))
q("M_CODEX", m.get("versions", {}).get("codex"))
q("M_FILES", sum(v.get("files", 0) for v in (m.get("top_level") or {}).values()))
q("M_BYTES", sum(v.get("bytes", 0) for v in (m.get("top_level") or {}).values()))
PY
)"

echo "snapshot   : $M_SNAP  ($M_STATUS)"
echo "from host  : $M_HOST, finished $M_FIN"
echo "source was : $M_OS on $M_ARCH, timezone $M_TZ"
echo "codex was  : $M_CODEX"
echo "contains   : $M_FILES files, $(numfmt --to=iec "$M_BYTES" 2>/dev/null || echo "$M_BYTES bytes")"
echo "restore to : $TARGET"
echo

[ "$M_STATUS" = complete ] || die "this snapshot is marked '$M_STATUS'. Pick a complete one: ls $ROOT/snapshots"

if [ "$M_ARCH" != "$(uname -m)" ]; then
    # Not fatal: the data is portable. The warning matters because anything compiled, and the
    # codex binaries in ~/.local/bin in particular, will be for the wrong architecture.
    echo "⚠️  this snapshot came from $M_ARCH and you are on $(uname -m)."
    echo "    Data and configuration are fine. Compiled binaries under ~/.local/bin are not;"
    echo "    reinstall those per docs/system-level.md."
    echo
fi

if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ] && [ "$FORCE" -eq 0 ]; then
    die "$TARGET is not empty. Use a fresh directory, or pass --force if you really mean to write into it."
fi

RSYNC=(rsync -aHAX --numeric-ids --info=progress2 --no-inc-recursive "$SNAP/home/" "$TARGET/")
if [ "$DRYRUN" -eq 1 ]; then
    RSYNC=(rsync -aHAXn --numeric-ids --stats "$SNAP/home/" "$TARGET/")
    log "dry run, nothing will be written"
    "${RSYNC[@]}" | tail -12
    exit 0
fi

mkdir -p "$TARGET" || die "cannot create $TARGET"
log "restoring $M_SNAP into $TARGET"
START=$(date +%s)
"${RSYNC[@]}"
RC=$?
[ $RC -eq 0 ] || [ $RC -eq 24 ] || die "rsync failed, rc=$RC"
log "restored in $(( ($(date +%s) - START) / 60 )) min"

# ---------- report what the operator still has to do ----------
# Restoring files is the easy half. These are the steps that files alone do not accomplish, and
# leaving them implicit is how a restore looks finished while the machine does not work.
cat <<EOF

Files are back. What is not done yet:

1. System packages and drivers are not restored. See docs/system-level.md in the
   dgx-backup repository, a copy of which is under $TARGET/Projects/GitHub/dgx-backup.
2. Services are restored but not enabled. When the machine is otherwise ready:
     systemctl --user daemon-reload
     systemctl --user enable --now claude-tg.service claude-tg-watchdog.service codex-tg.service stt-api.service
   Start them only after checking the paths inside each unit still exist.
3. Credentials in the snapshot may have expired: the Claude OAuth refresh token lasts
   30 days, so \`claude\` will likely need /login. Telegram bot tokens do not expire.
4. If this is a different machine, \`~/.local/bin/codex\` and \`codex-code-mode-host\`
   are architecture-specific. Re-download them for this architecture.
5. Check that ~/.ssh/id_ed25519 kept mode 600; git over SSH refuses a world-readable key.

EOF
ls -ld "$TARGET"/.ssh 2>/dev/null && stat -c '  ~/.ssh/id_ed25519 mode: %a' "$TARGET/.ssh/id_ed25519" 2>/dev/null
