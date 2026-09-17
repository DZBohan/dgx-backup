#!/usr/bin/env bash
# Prove the corruption detector actually detects corruption.
#
# This exists because of a defect found on 2026-09-17: verify.sh excluded a snapshot's own record
# when choosing a baseline, so re-running it on one snapshot compared against nothing, found nothing,
# and overwrote the record with fresh hashes. Since README-RESTORE.md tells the operator to run
# exactly that when a file looks corrupt, the documented response to suspected rot destroyed the
# evidence of it and reported success.
#
# The lesson is not about that one line. A detector that is never fed a known positive will report
# success whether or not it works, and a backup system's detector is the last thing anyone checks.
# So this builds a small snapshot, rots a file the way a disk does (content changes, size and mtime
# do not), and asserts the failure is caught.
#
#   selftest.sh          runs everything in a temporary directory and cleans up
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=$(hostname -s)
T=$(mktemp -d /tmp/dgx-backup-selftest-XXXXXX)
trap 'rm -rf "$T"' EXIT
FAILS=0
ok()  { printf '  ✅ %s\n' "$*"; }
bad() { FAILS=$((FAILS+1)); printf '  ❌ %s\n' "$*"; }

SNAP="$T/backups/$HOST/snapshots/2026-01-01T00-00-00"
VDIR="$T/backups/$HOST/verify"
REC="$VDIR/2026-01-01T00-00-00.sha256"
mkdir -p "$SNAP/home/sub"
for i in $(seq 1 40); do printf 'contents of file %d\n' "$i" >"$SNAP/home/sub/f$i.txt"; done
printf '{"schema":1,"status":"complete","snapshot":"2026-01-01T00-00-00","top_level":{"sub":{"files":40,"bytes":0}}}' >"$SNAP/MANIFEST.json"
ln -sfn "snapshots/2026-01-01T00-00-00" "$T/backups/$HOST/latest"

echo "1. first verify records a baseline"
if "$HERE/verify.sh" --dest "$T" >/dev/null 2>&1; then ok "exit 0"; else bad "first verify should succeed"; fi
[ -f "$REC" ] && ok "record written" || bad "no record at $REC"
BASELINE=$(md5sum "$REC" 2>/dev/null | cut -d' ' -f1)

echo "2. re-running on an untouched snapshot stays clean"
if "$HERE/verify.sh" --dest "$T" >/dev/null 2>&1; then ok "exit 0"; else bad "re-run on clean data should succeed"; fi

echo "3. rot is detected: same size, same mtime, different bytes"
F="$SNAP/home/sub/f7.txt"
MT=$(stat -c %y "$F"); SZ=$(stat -c %s "$F")
printf 'CONTENTS OF FILE 7\n' >"$F"
touch -d "$MT" "$F"
[ "$(stat -c %s "$F")" = "$SZ" ] || bad "test bug: the rotted file changed size, so this proves nothing"
OUT=$("$HERE/verify.sh" --dest "$T" 2>&1); RC=$?
if [ $RC -ne 0 ]; then ok "exit $RC"; else bad "corruption went undetected, exit 0"; fi
echo "$OUT" | grep -q "SILENT CORRUPTION" && ok "reported as silent corruption" || bad "no corruption message"
echo "$OUT" | grep -q "sub/f7.txt" && ok "named the rotted file" || bad "did not name the file"

echo "4. the run that finds rot must not overwrite the evidence"
AFTER=$(md5sum "$REC" 2>/dev/null | cut -d' ' -f1)
[ "$BASELINE" = "$AFTER" ] && ok "baseline record untouched" || bad "baseline was overwritten with the rotted hashes"
[ -f "$REC.suspect" ] && ok "new hashes written to .suspect instead" || bad "no .suspect file"

echo "5. an incomplete snapshot is refused"
python3 - "$SNAP/MANIFEST.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["status"] = "incomplete"; json.dump(d, open(p, "w"))
PY
"$HERE/verify.sh" --dest "$T" >/dev/null 2>&1 && bad "an incomplete snapshot should be refused" || ok "refused"

echo
if [ $FAILS -eq 0 ]; then echo "selftest: all checks passed"; else echo "selftest: $FAILS failed"; exit 1; fi
