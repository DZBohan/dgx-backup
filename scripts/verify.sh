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
# A snapshot's own record is the right baseline when it already has one. A snapshot never changes
# after it is written, so re-hashing it and comparing against what was recorded is exactly the
# question "has this decayed on disk since", which is what rot detection means.
#
# This used to exclude the snapshot's own record, so re-running verify on one snapshot re-hashed
# everything, compared against nothing, and then overwrote the record with the fresh hashes. If rot
# had occurred, that run would have quietly adopted the rotted hashes as the new truth and erased
# the only evidence. README-RESTORE.md tells the operator to run exactly that command when a file
# looks corrupt, so the documented response to suspected corruption destroyed the proof of it.
if [ -f "$NOW" ]; then
    PREV="$NOW"
    SELF_CHECK=1
else
    PREV=$(ls -1 "$VERIFY_DIR"/*.sha256 2>/dev/null | tail -1)
    SELF_CHECK=0
fi

if [ "$SELF_CHECK" = "1" ]; then
    log "re-checking $STAMP against its own record from $(date -r "$NOW" '+%F %H:%M')"
else
    log "hashing $STAMP ($([ $FULL -eq 1 ] && echo "every file" || echo "changed files plus a $SAMPLE-file sample"))"
fi

python3 - "$SNAP" "$NOW" "$PREV" "$FULL" "$SAMPLE" <<'PY'
import hashlib, json, os, random, sys, time

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

# Unchanged files are sampled rather than all re-read: hashing 1.4 TB weekly would take hours and
# wear the drive for little gain. Which files get sampled is the part that matters.
#
# This used to be random.sample under a fixed seed, which drew the same 2,000 files every week
# forever. The other 224,000 were never re-read, and those are exactly the ones at risk: research
# data in ~/Projects sits untouched for years, which is when rot happens and when nothing else
# would notice. Weekly "verification" was covering 1% of the data permanently.
#
# Reseeding randomly each week does not fix it either. Independent draws are a coupon-collector
# problem, so covering 226,660 files at 2,000 a week would take about 1,400 weeks, not 113.
#
# So the sample rotates instead: the list is walked in path order, resuming where the last run
# stopped, which reaches every file in ceil(N / sample) runs with no repeats. The cursor stores the
# last path rather than an index, so files added or deleted in between shift nothing.
#
# A byte budget caps the work as well, because a window can land entirely on large files. Whichever
# limit is reached first ends the window, and the cursor keeps the position either way, so progress
# is made every run regardless.
if not full and unchanged:
    unchanged.sort(key=lambda t: t[0])
    cursor_path = os.path.join(os.path.dirname(out), ".sample-cursor")
    try:
        last = open(cursor_path, encoding="utf-8").read().strip()
    except OSError:
        last = ""

    start = 0
    if last:
        lo, hi = 0, len(unchanged)
        while lo < hi:                       # first entry strictly after the last one checked
            mid = (lo + hi) // 2
            if unchanged[mid][0] <= last:
                lo = mid + 1
            else:
                hi = mid
        start = lo
    if start >= len(unchanged):
        start = 0                            # wrapped: begin another pass over the whole tree

    budget = int(os.environ.get("VERIFY_SAMPLE_BYTES", str(20 * 1024**3)))
    picked, used = [], 0
    for i in range(len(unchanged)):
        rel, size, mtime = unchanged[(start + i) % len(unchanged)]
        if len(picked) >= sample_n or (picked and used + size > budget):
            break
        picked.append((rel, size, mtime))
        used += size
    if picked:
        todo += picked
        try:
            tmp = cursor_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(picked[-1][0])
            os.replace(tmp, cursor_path)     # same atomic write as everything else that persists
        except OSError as e:
            print("  could not save the sample cursor, next run will repeat this window: %s" % e)
        pos = start + len(picked)
        print("  sampling %d unchanged files (%.1f GB), %d-%d of %d in path order"
              % (len(picked), used / 1e9, start + 1, min(pos, len(unchanged)), len(unchanged)))

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

corrupt, hashed, errors = [], 0, []
records = dict((rel, (sha, size, mtime)) for rel, (sha, size, mtime) in
               ((k, v) for k, v in prev.items()))      # carry forward what we did not re-hash

# A first verify has no previous record, so every file is hashed: 1.3 TB read from a mechanical
# drive, which took 4h56m on 2026-09-16 and printed nothing at all until it was done. Anyone
# checking on it had to read sector counters out of /proc/diskstats to tell work from a hang.
# Anything that can run for hours has to say so itself.
#
# Progress is timed rather than counted: one line per N files would be silent through a few huge
# files and a flood through many small ones, and this snapshot contains both.
todo_bytes = sum(sz for _, sz, _ in todo)
done_bytes = 0
started = last_report = time.time()
REPORT_EVERY = float(os.environ.get("VERIFY_REPORT_SECONDS", "60"))

def progress(force=False):
    global last_report
    now = time.time()
    if not force and now - last_report < REPORT_EVERY:
        return
    last_report = now
    el = now - started
    rate = done_bytes / el if el > 0 else 0
    pct = 100.0 * done_bytes / todo_bytes if todo_bytes else 100.0
    # Remaining is derived from bytes still to read at the average rate so far. It is a rough
    # figure: this tree mixes 1.4 TB of large files with ~125,000 small ones, and those hash at
    # very different speeds, so the estimate moves around. Printed anyway, because an approximate
    # number that is visibly moving is what distinguishes slow work from a hang.
    eta = (todo_bytes - done_bytes) / rate if rate > 0 else 0
    print("  %5.1f%%  %s/%s files  %.0f/%.0f GB  %.0f MB/s  ~%s left"
          % (pct, f"{hashed:,}", f"{len(todo):,}", done_bytes / 1e9, todo_bytes / 1e9,
             rate / 1e6, time.strftime("%H:%M:%S", time.gmtime(eta))), flush=True)

for rel, size, mtime in todo:
    p = os.path.join(home, rel)
    try:
        sha = sha256(p)
    except OSError as e:
        errors.append("%s: %s" % (rel, e))
        done_bytes += size
        progress()
        continue
    hashed += 1
    done_bytes += size
    progress()
    old = prev.get(rel)
    # The finding that matters: content changed while size and mtime did not. An edit moves mtime;
    # a decaying sector does not. Anything else is a normal change.
    if old and old[0] != sha and old[1] == size and abs(old[2] - mtime) <= 1:
        corrupt.append(rel)
    records[rel] = (sha, size, mtime)

if todo:
    progress(force=True)

present = set(rel for rel, _, _ in files)
# Writing the record is skipped entirely when corruption was found: see the exit below. The old
# record is the evidence, and a run that discovers rot must not replace it with the rotted hashes.
with open(out if not corrupt else out + ".suspect", "w", encoding="utf-8") as f:
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
    print("")
    print("the existing record was left untouched; the new hashes are in %s" % (out + ".suspect"))
    print("an earlier snapshot may still hold a good copy of these files")
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
