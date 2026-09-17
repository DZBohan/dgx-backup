#!/usr/bin/env bash
# Check a snapshot against recorded checksums, to catch silent corruption.
#
#   verify.sh [--snapshot NAME|latest] [--dest MOUNTPOINT] [--full]
#
# The problem this exists for: ext4 stores no per-block checksums for file data. A sector can
# degrade on the drive and nothing reports it. rsync compares size and mtime, so on the next run
# it sees "unchanged" and links the rotten copy forward into every future snapshot. By the time
# anyone opens the file, every snapshot holds the same damage.
#
# So checksums are recorded per snapshot, and a file whose checksum changed while its size and
# mtime did not is reported as corruption rather than as an edit. That distinction is the whole
# point: an edit changes mtime, rot does not.
#
# By default only files that the manifest says were newly written are hashed, plus a random
# sample of the rest; --full hashes everything, which on 1.4 TB takes hours.

set -uo pipefail

LABEL=${LABEL:-DGXBACKUP}
HOSTNAME_S=$(hostname -s)
SNAPNAME=latest
DEST=""
FULL=0
SAMPLE=${SAMPLE:-2000}

while [ $# -gt 0 ]; do
    case "$1" in
    --snapshot) SNAPNAME=$2; shift ;;
    --dest) DEST=$2; shift ;;
    --full) FULL=1 ;;
    *) echo "unknown argument: $1"; exit 1 ;;
    esac
    shift
done

die() { echo "✗ $*" >&2; exit 1; }
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

if [ -z "$DEST" ]; then
    DEV=$(lsblk -rno PATH,LABEL | awk -v l="$LABEL" '$2==l {print $1; exit}')
    [ -n "$DEV" ] || die "no partition labelled $LABEL. Is the drive plugged in?"
    DEST=$(findmnt -n -o TARGET --source "$DEV" | head -1)
    [ -n "$DEST" ] || die "$DEV is present but not mounted"
fi

ROOT="$DEST/backups/$HOSTNAME_S"
[ -d "$ROOT" ] || die "no backups for $HOSTNAME_S under $DEST"

if [ "$SNAPNAME" = latest ]; then
    SNAP=$(readlink -f "$ROOT/latest") || die "no latest symlink"
else
    SNAP="$ROOT/snapshots/$SNAPNAME"
fi
[ -d "$SNAP/home" ] || die "not a snapshot: $SNAP"

STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$SNAP/MANIFEST.json" 2>/dev/null)
[ "$STATUS" = complete ] || die "snapshot is marked '$STATUS', not 'complete'. Verifying a half-written copy proves nothing."

STAMP=$(basename "$SNAP")
VERIFY_DIR="$ROOT/verify"
mkdir -p "$VERIFY_DIR"
NOW="$VERIFY_DIR/$STAMP.sha256"
PREV=$(ls -1 "$VERIFY_DIR"/*.sha256 2>/dev/null | grep -v "/$STAMP.sha256$" | tail -1)

log "hashing $STAMP ($([ $FULL -eq 1 ] && echo "every file" || echo "changed files plus a $SAMPLE-file sample"))"

python3 - "$SNAP" "$NOW" "$PREV" "$FULL" "$SAMPLE" <<'PY'
import hashlib, json, os, random, sys

snap, out, prev_path, full, sample_n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", int(sys.argv[5])
home = os.path.join(snap, "home")

# Previous run's records: path -> (sha, size, mtime). Used both to decide what to re-hash and to
# tell rot from an ordinary edit.
prev = {}
if prev_path and os.path.exists(prev_path):
    for line in open(prev_path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4:
            sha, size, mtime, path = parts
            prev[path] = (sha, int(size), float(mtime))

files = []
for root, dirs, names in os.walk(home, onerror=lambda e: None):
    for n in names:
        p = os.path.join(root, n)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not os.path.isfile(p) or os.path.islink(p):
            continue            # symlink targets get hashed via their own entry, if present
        files.append((os.path.relpath(p, home), st.st_size, st.st_mtime))

# A file needs hashing if it is new, if it looks edited, or if it was picked for the sample.
# Everything else is only re-hashed under --full: re-reading 1.4 TB weekly would take hours and
# wear the drive for little gain, since rot is rare and the sample will find a widespread problem.
todo, unchanged = [], []
for rel, size, mtime in files:
    old = prev.get(rel)
    if full or old is None or old[1] != size or abs(old[2] - mtime) > 1:
        todo.append((rel, size, mtime))
    else:
        unchanged.append((rel, size, mtime))

if not full and unchanged:
    random.seed(0)          # deterministic: the same sample every week, so repeated rot is caught
    todo += random.sample(unchanged, min(sample_n, len(unchanged)))

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

corrupt, hashed, errors = [], 0, []
records = dict((rel, (sha, size, mtime)) for rel, (sha, size, mtime) in
               ((k, v) for k, v in prev.items()))      # carry forward what we did not re-hash

for rel, size, mtime in todo:
    p = os.path.join(home, rel)
    try:
        sha = sha256(p)
    except OSError as e:
        errors.append("%s: %s" % (rel, e))
        continue
    hashed += 1
    old = prev.get(rel)
    # The finding that matters: content changed while size and mtime did not. An edit moves mtime;
    # a decaying sector does not. Anything else is a normal change.
    if old and old[0] != sha and old[1] == size and abs(old[2] - mtime) <= 1:
        corrupt.append(rel)
    records[rel] = (sha, size, mtime)

present = set(rel for rel, _, _ in files)
with open(out, "w", encoding="utf-8") as f:
    for rel in sorted(records):
        if rel in present:
            sha, size, mtime = records[rel]
            f.write("%s\t%d\t%r\t%s\n" % (sha, size, mtime, rel))

print("files in snapshot : %d" % len(files))
print("hashed this run   : %d" % hashed)
print("carried forward   : %d" % (len(records) - hashed))
if errors:
    print("unreadable        : %d" % len(errors))
    for e in errors[:10]:
        print("   ", e)
if corrupt:
    print("")
    print("SILENT CORRUPTION: %d file(s) changed content while size and mtime stayed the same" % len(corrupt))
    for c in corrupt[:20]:
        print("   ", c)
    sys.exit(3)
print("no silent corruption found")
PY
RC=$?

if [ $RC -eq 3 ]; then
    echo "$(date '+%F %T')  CORRUPTION  $STAMP" >>"$ROOT/backup.log"
    die "verification found corruption in $STAMP; see the list above"
fi
[ $RC -ne 0 ] && die "verification failed, rc=$RC"

echo "$(date '+%F %T')  VERIFY OK  $STAMP" >>"$ROOT/backup.log"
log "checksums stored at $NOW"
