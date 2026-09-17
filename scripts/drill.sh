#!/usr/bin/env bash
# Rehearse a restore without a spare machine.
#
#   drill.sh [--snapshot NAME|latest] [--dest MOUNTPOINT] [--keep]
#
# The question a drill has to answer is not "does the machine boot". It is "does the restored tree
# contain everything the machine refers to". That is where a restore actually fails: something was
# never in scope, nobody noticed, and it is missing on the day it matters. That question can be
# answered on this machine, today, with no second computer.
#
# What this checks, in order of how badly each would hurt:
#   1. every file the running system points at is present in the snapshot
#   2. the restore reproduces modes and symlinks (a 644 private key means no git over SSH)
#   3. every ExecStart path in the restored unit files exists inside the restored tree
#   4. configuration files still parse
#   5. the manifest's own counts match what is really there
#
# It restores everything except ~/Projects, which is 1.3 TB of image data whose restore path is
# identical to everything else's. Excluding it keeps the drill cheap enough to run every week,
# which matters more than testing the same rsync invocation on bigger files.

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

# ---------- 1. is everything the running system points at actually in the snapshot ----------
# This is the check that would have caught ~/.ssh being left out of the original scope list.
# The list is deliberately concrete: these are the files without which some specific thing breaks.
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

# ---------- 2. restore, minus the bulk ----------
echo "2. restoring (everything except Projects, which is 1.3 TB of the same rsync)"
rsync -aHAX --numeric-ids --quiet --exclude='Projects/' "$SNAP/home/" "$WORK/home/"
RC=$?
# 24 is "some files vanished while copying", normal on a live home directory.
if [ $RC -eq 0 ] || [ $RC -eq 24 ]; then ok "rsync returned $RC"; else bad "rsync returned $RC"; fi
echo

# ---------- 3. modes and symlinks ----------
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

# A symlink that pointed inside the home directory must still point somewhere real after a restore.
# One pointing outside (into /usr, say) is fine and is not the backup's problem.
BROKEN=$(find "$WORK/home" -xtype l 2>/dev/null | while read -r l; do
    t=$(readlink "$l"); case "$t" in /*) ;; *) echo "$l";; esac
done | head -20)
if [ -z "$BROKEN" ]; then ok "no broken relative symlinks"; else
    bad "broken relative symlinks:"; echo "$BROKEN" | sed "s|$WORK/home/|     |"
fi
echo

# ---------- 4. do the service definitions point at things that exist ----------
# A restored unit whose ExecStart is missing fails at start with a message that does not say why.
echo "4. every ExecStart in the restored units exists in the restored tree"
# The loop must not sit in a pipeline: a subshell's pass and fail counts are thrown away, which
# would let a missing ExecStart print a cross and still exit 0.
UNITS=$(mktemp)
for u in "$WORK/home/.config/systemd/user"/*.service; do
    [ -f "$u" ] || continue
    grep -h '^ExecStart' "$u" | sed "s|^ExecStart=|$(basename "$u")\t|" >>"$UNITS"
done
while IFS=$'\t' read -r name cmd; do
    [ -z "${cmd:-}" ] && continue
    set -- $cmd
    # Units use %h and absolute /home/<user> paths; both have to be mapped into the drill tree.
    p=${1/\%h/$WORK\/home}
    p=${p/\/home\/dzbohan/$WORK\/home}
    case "$p" in /usr/bin/*|/bin/*|/usr/local/bin/*) ok "$name → $p (system path, not from backup)"; continue ;; esac
    if [ -e "$p" ]; then ok "$name → ${p#$WORK/home/}"; else bad "$name → ${p#$WORK/home/} missing from the restore"; fi
done <"$UNITS"
rm -f "$UNITS"
echo

# ---------- 5. configuration still parses ----------
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

# ---------- 6. does the manifest describe what is really there ----------
echo "6. manifest agrees with the snapshot"
python3 - "$SNAP" <<'PY'
import json, os, sys
snap = sys.argv[1]
m = json.load(open(os.path.join(snap, "MANIFEST.json")))
home = os.path.join(snap, "home")
bad = False
for name, rec in sorted(m.get("top_level", {}).items()):
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
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

echo
echo "drill: $PASS checks passed, $FAIL failed"
[ "$KEEP" -eq 1 ] && echo "restored tree kept at $WORK"
[ "$FAIL" -eq 0 ] || exit 1
