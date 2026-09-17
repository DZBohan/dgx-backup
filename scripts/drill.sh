#!/usr/bin/env bash
# Rehearse a restore without a spare machine.
#
#   drill.sh [--snapshot NAME|latest] [--dest MOUNTPOINT] [--keep]
#
# Check selected recovery requirements using a temporary restore on this machine.
# This requires no sudo or spare machine. It does not boot a clean system or start services.
#
# Checks:
#   1. confirm that a fixed list of required paths exists in the snapshot
#   2. copy the snapshot to a temporary directory, excluding Projects
#   3. check selected permissions, one executable bit, and broken relative symlinks
#   4. check the first token of ExecStart entries, accepting system paths without testing them
#   5. parse four selected JSON and TOML configuration files
#   6. compare recorded file counts with snapshot entries listed in the manifest
#
# Projects contains 1.3 TB and uses the same rsync copy mechanism. Excluding it keeps the
# copy small enough for a weekly drill. Check 6 still counts its snapshot files.
# This does not test Projects data transfer, full recovery time, or restore.sh itself.

set -uo pipefail

LABEL=${LABEL:-DGXBACKUP}
HOSTNAME_S=$(hostname -s)
SNAPNAME=latest
DEST=""
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
    --snapshot) SNAPNAME=$2; shift ;;
    --dest) DEST=$2; shift ;;
    --keep) KEEP=1 ;;
    *) echo "unknown argument: $1"; exit 1 ;;
    esac
    shift
done

die() { echo "✗ $*" >&2; exit 1; }
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$*"; }

if [ -z "$DEST" ]; then
    DEV=$(lsblk -rno PATH,LABEL | awk -v l="$LABEL" '$2==l {print $1; exit}')
    [ -n "$DEV" ] || die "no partition labelled $LABEL"
    DEST=$(findmnt -n -o TARGET --source "$DEV" | head -1)
    [ -n "$DEST" ] || die "$DEV not mounted"
fi
ROOT="$DEST/backups/$HOSTNAME_S"
if [ "$SNAPNAME" = latest ]; then SNAP=$(readlink -f "$ROOT/latest"); else SNAP="$ROOT/snapshots/$SNAPNAME"; fi
[ -d "$SNAP/home" ] || die "not a snapshot: $SNAP"

STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$SNAP/MANIFEST.json" 2>/dev/null)
[ "$STATUS" = complete ] || die "snapshot is '$STATUS'; drilling an unfinished copy proves nothing"

WORK=$(mktemp -d /tmp/restore-drill-XXXXXX)
trap '[ "$KEEP" -eq 1 ] || rm -rf "$WORK"' EXIT
echo "drill of $(basename "$SNAP") into $WORK"
echo

# ---------- 1. required paths ----------
# This fixed list would have caught the original omission of ~/.ssh.
# Each entry names a dependency and the consequence of losing it; the list is not exhaustive.
echo "1. files the running system depends on"
while IFS='|' read -r path why; do
    [ -z "$path" ] && continue
    if [ -e "$SNAP/home/$path" ]; then ok "$path"; else bad "$path missing — $why"; fi
done <<'EOF'
.ssh/id_ed25519|no git over SSH from a restored machine
.claude.json|Claude Code top-level configuration
Claude/CLAUDE.md|Lucia's operating rules
.claude/projects/-home-dzbohan-Claude/memory/MEMORY.md|Lucia's memory index
.codex/AGENTS.md|Vivian's operating rules
.codex/config.toml|model, sandbox and approval policy
.codex/telegram/.env|Vivian's bot token and allowlist
.claude/channels/telegram/.env|Lucia's bot token
Codex/learned.md|Vivian's long-term memory
Shared/SERVER.md|facts both assistants read
codex-assistant/codex-tg-bridge.py|the bridge itself
Scripts/claude-tg-runner.sh|what claude-tg.service executes
Scripts/claude-tg-watchdog.py|the watchdog
Claude/stt-api/main.py|speech-to-text service
.config/systemd/user/claude-tg.service|service definition
EOF
echo

# ---------- 2. copy the snapshot without Projects ----------
echo "2. restoring (everything except Projects, which is 1.3 TB of the same rsync)"
rsync -aHAX --numeric-ids --quiet --exclude='Projects/' "$SNAP/home/" "$WORK/home/"
RC=$?
# backup.sh tolerates exit code 24 because it reads a live home directory. Here the source is a
# finished snapshot that nothing should be writing to, so a file vanishing mid-copy is a signal
# about the drive or the snapshot, not ordinary noise. Only 0 passes.
if [ $RC -eq 0 ]; then ok "rsync returned 0"; else bad "rsync returned $RC (a completed snapshot should copy cleanly)"; fi
echo

# ---------- 3. selected permissions and relative symlinks ----------
echo "3. modes and symlinks survived the round trip"
chk_mode() {
    local p="$WORK/home/$1" want=$2
    [ -e "$p" ] || { bad "$1 not restored"; return; }
    local got; got=$(stat -c %a "$p")
    [ "$got" = "$want" ] && ok "$1 is $got" || bad "$1 is $got, expected $want"
}
chk_mode .ssh 700
chk_mode .ssh/id_ed25519 600
chk_mode .codex/telegram/.env 600
chk_mode .claude/channels/telegram/.env 600
[ -x "$WORK/home/Scripts/claude-tg-watchdog.py" ] && ok "watchdog is executable" || bad "watchdog lost its executable bit"

# Report up to 20 broken links with relative targets. Absolute targets are skipped,
# including those that point into the original home directory.
BROKEN=$(find "$WORK/home" -xtype l 2>/dev/null | while read -r l; do
    t=$(readlink "$l"); case "$t" in /*) ;; *) echo "$l";; esac
done | head -20)
if [ -z "$BROKEN" ]; then ok "no broken relative symlinks"; else
    bad "broken relative symlinks:"; echo "$BROKEN" | sed "s|$WORK/home/|     |"
fi
echo

# ---------- 4. paths referenced by the restored unit files ----------
# A unit whose executable is missing fails to start with a message that does not name the cause,
# so this resolves what the units point at against the restored tree.
#
# Every whitespace-separated token is examined, not only the first. Three of the six units on this
# machine start with /usr/bin/python3 and name the real script in the second token, so checking
# argv[0] alone would have passed them without looking at anything that comes from the backup.
#
# ExecStartPre is included deliberately: claude-tg.service has one, and a missing pre-start script
# stops the unit just as effectively as a missing ExecStart.
echo "4. paths referenced by the restored unit files"
UNITS=$(mktemp)
for u in "$WORK/home/.config/systemd/user"/*.service; do
    [ -f "$u" ] || continue
    # Match the directive name exactly rather than by prefix, then keep it as its own field.
    # The sed delimiter cannot be | here: the alternation in the pattern uses it.
    grep -hE '^ExecStart(Pre|Post)?=' "$u" \
        | sed -E "s#^(ExecStart(Pre|Post)?)=[-@]*#$(basename "$u")\t\1\t#" >>"$UNITS"
done
# Keep the loop outside a pipeline: a subshell's PASS and FAIL updates are discarded, which would
# let a missing path print a cross and still exit 0.
while IFS=$'\t' read -r name directive cmd; do
    [ -z "${cmd:-}" ] && continue
    for tok in $cmd; do
        case "$tok" in
        %h/*|/home/dzbohan/*) ;;
        *) continue ;;     # options, arguments and system binaries are not restored from the backup
        esac
        rel=${tok#\%h/}; rel=${rel#/home/dzbohan/}
        # ~/Projects is excluded from the drill copy on purpose, so its absence here says nothing
        # about the backup. Report that plainly instead of raising a failure the drill created.
        case "$rel" in
        Projects/*)
            if [ -e "$SNAP/home/$rel" ]; then ok "$name $directive → $rel (in the snapshot; outside the drill copy)"
            else bad "$name $directive → $rel missing from the snapshot itself"; fi
            continue ;;
        esac
        if [ -e "$WORK/home/$rel" ]; then ok "$name $directive → $rel"
        else bad "$name $directive → $rel missing from the restore"; fi
    done
done <"$UNITS"
rm -f "$UNITS"
echo

# ---------- 5. syntax of selected configuration files ----------
echo "5. configuration files parse"
python3 - "$WORK/home" <<'PY'
import json, sys, tomllib, os
home = sys.argv[1]
bad = False
checks = [("json", ".claude.json"), ("json", ".claude/channels/telegram/access.json"),
          ("json", ".codex/telegram/state.json"), ("toml", ".codex/config.toml")]
for kind, rel in checks:
    p = os.path.join(home, rel)
    if not os.path.exists(p):
        print("  ❌ %s missing" % rel); bad = True; continue
    try:
        if kind == "json":
            json.load(open(p, encoding="utf-8"))
        else:
            tomllib.load(open(p, "rb"))
        print("  ✅ %s parses" % rel)
    except Exception as e:
        print("  ❌ %s does not parse: %s" % (rel, e))
        bad = True
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
echo

# ---------- 6. file counts for manifest-listed snapshot entries ----------
echo "6. manifest agrees with the snapshot"
python3 - "$SNAP" <<'PY'
import json, os, sys
snap = sys.argv[1]
m = json.load(open(os.path.join(snap, "MANIFEST.json")))
home = os.path.join(snap, "home")
bad = False
top = m.get("top_level") or {}
# An empty or absent top_level used to pass, so a manifest that recorded nothing looked like
# a manifest that agreed with everything. Missing counts are a failure, not a silent pass.
if not top:
    print("  ❌ MANIFEST.json has no top_level counts to compare against")
    sys.exit(1)
for name, rec in sorted(top.items()):
    p = os.path.join(home, name)
    if not os.path.exists(p):
        print("  ❌ manifest lists %s but it is not in the snapshot" % name); bad = True; continue
    if not os.path.isdir(p) or os.path.islink(p):
        real = 1
    else:
        real = sum(len(fs) for _, _, fs in os.walk(p, onerror=lambda e: None))
    flag = "✅" if real == rec["files"] else "❌"
    if flag == "❌": bad = True
    if flag == "❌" or name in ("Projects", ".claude", ".codex"):
        print("  %s %-24s manifest %d, on disk %d" % (flag, name, rec["files"], real))
for name in sorted(os.listdir(home)):
    if name not in top:
        print("  ❌ %s is in the snapshot but the manifest does not list it" % name)
        bad = True
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

echo
echo "drill: $PASS checks passed, $FAIL failed"
[ "$KEEP" -eq 1 ] && echo "restored tree kept at $WORK"
[ "$FAIL" -eq 0 ] || exit 1
