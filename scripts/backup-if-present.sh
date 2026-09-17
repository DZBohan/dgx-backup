#!/usr/bin/env bash
# What the weekly timer actually runs.
#
# Three jobs, in this order:
#   1. if the drive is not plugged in, say so and exit 75 (EX_TEMPFAIL), which the unit treats as
#      success. A drive left at home is not a broken backup, and conflating the two makes the
#      staleness alarm useless.
#   2. read SMART before writing, so a drive that is already failing is not handed 1.4 TB.
#   3. run backup.sh, then verify.sh, then check how long it has been since the last good run and
#      tell Bohan over Telegram if that is too long.
#
# The staleness alarm is the part that matters. A backup that silently stops running looks exactly
# like a backup that is working, until the day you need it.

set -uo pipefail

LABEL=${LABEL:-DGXBACKUP}
HERE=$(cd "$(dirname "$0")" && pwd)
STALE_DAYS=${STALE_DAYS:-14}
HOSTNAME_S=$(hostname -s)
STATE_DIR="$HOME/.local/state/dgx-backup"
mkdir -p "$STATE_DIR"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

# Reuse the Telegram credentials the Claude channel already has. This deliberately does not open a
# getUpdates poller; it only calls sendMessage, so it cannot steal messages from the bridge.
#
# TEST_MODE=1 prefixes every message with [TEST]. This exists because a test of the staleness
# alarm once sent Bohan "last success: 2026-08-27" with no marking, and he read it as a record of
# a backup that had never happened. A test that writes a plausible fact into someone's inbox is
# worse than no test: anything sent to a person must be distinguishable from a real report.
tg() {
    [ "${TEST_MODE:-0}" = "1" ] && set -- "[TEST] $*"
    local env="$HOME/.claude/channels/telegram/.env"
    local access="$HOME/.claude/channels/telegram/access.json"
    [ -f "$env" ] && [ -f "$access" ] || { log "no telegram credentials, cannot notify: $*"; return; }
    local token chat
    token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$env" | cut -d= -f2-)
    chat=$(python3 -c "import json,sys; a=json.load(open(sys.argv[1])).get('allowFrom') or []; print(a[0] if a else '')" "$access")
    [ -n "$token" ] && [ -n "$chat" ] || { log "incomplete telegram credentials"; return; }
    curl -s --max-time 20 -X POST "https://api.telegram.org/bot$token/sendMessage" \
        --data-urlencode "chat_id=$chat" --data-urlencode "text=$*" >/dev/null || log "telegram send failed"
}

check_staleness() {
    local last="$STATE_DIR/last-success"
    [ -f "$last" ] || return 0
    local age_days=$(( ( $(date +%s) - $(cat "$last") ) / 86400 ))
    if [ "$age_days" -ge "$STALE_DAYS" ]; then
        tg "⚠️ 备份已经 $age_days 天没有成功跑过了。上次成功：$(date -d "@$(cat "$last")" '+%F %H:%M')。插上 DGXBACKUP 那块盘即可，或者告诉我出了什么问题。"
    fi
}

# ---------- 1. is the drive here ----------
DEV=$(lsblk -rno PATH,LABEL | awk -v l="$LABEL" '$2==l {print $1; exit}')
if [ -z "$DEV" ]; then
    log "drive labelled $LABEL is not attached; skipping"
    check_staleness
    exit 75
fi

MP=$(findmnt -n -o TARGET --source "$DEV" | head -1)
if [ -z "$MP" ]; then
    log "$DEV present but not mounted, trying to mount"
    udisksctl mount -b "$DEV" >/dev/null 2>&1
    MP=$(findmnt -n -o TARGET --source "$DEV" | head -1)
    [ -n "$MP" ] || { log "could not mount $DEV"; tg "⚠️ 备份盘插着但挂不上（$DEV），这次跳过。"; exit 75; }
fi
log "drive at $MP"

# ---------- 2. SMART before writing ----------
# Report health before the run, not after: the point is to warn while the drive can still be
# replaced, rather than discover the problem from a failed restore.
if command -v smartctl >/dev/null 2>&1; then
    SMART=$(smartctl -H -A -d sat "$DEV" 2>/dev/null)
    HEALTH=$(echo "$SMART" | grep -i 'overall-health' | sed 's/.*: *//')
    REALLOC=$(echo "$SMART" | awk '/Reallocated_Sector_Ct/{print $10}')
    PENDING=$(echo "$SMART" | awk '/Current_Pending_Sector/{print $10}')
    HOURS=$(echo "$SMART" | awk '/Power_On_Hours/{print $10}')
    log "SMART: health=${HEALTH:-?} realloc=${REALLOC:-?} pending=${PENDING:-?} hours=${HOURS:-?}"
    if [ -n "${HEALTH:-}" ] && [ "$HEALTH" != "PASSED" ]; then
        tg "⚠️ 备份盘 SMART 自检不是 PASSED，而是「$HEALTH」。这次仍然备份了，但请考虑换盘。"
    fi
    if [ "${REALLOC:-0}" -gt 0 ] 2>/dev/null || [ "${PENDING:-0}" -gt 0 ] 2>/dev/null; then
        tg "⚠️ 备份盘出现坏扇区：重分配 ${REALLOC:-?}，待定 ${PENDING:-?}。盘还能用，但这是换盘的信号。"
    fi
else
    log "smartctl not installed; skipping drive health check (see docs/system-level.md)"
fi

# ---------- 3. back up, verify, then judge staleness ----------
if ! "$HERE/backup.sh"; then
    tg "❌ 备份失败了。跑 journalctl --user -u dgx-backup.service 看原因。"
    exit 1
fi

if ! "$HERE/verify.sh"; then
    # Corruption is worth interrupting for: every later snapshot will link the bad copy forward.
    tg "❌ 备份完成了，但校验发现静默损坏。跑 ~/Projects/GitHub/dgx-backup/scripts/verify.sh --full 看是哪些文件。"
    exit 1
fi

# TEST_MODE never touches the real state file: a test must not leave a "last success" timestamp
# behind for the next real run to believe.
if [ "${TEST_MODE:-0}" = "1" ]; then
    log "TEST_MODE: not recording this run as a success"
else
    date +%s >"$STATE_DIR/last-success"
fi
SIZE=$(df -h "$MP" | tail -1 | awk '{print $4}')
COUNT=$(ls -1 "$MP/backups/$HOSTNAME_S/snapshots" 2>/dev/null | wc -l)
log "done; $COUNT snapshots on the drive, $SIZE free"
tg "✅ 每周备份完成。盘上现在有 $COUNT 份快照，剩余空间 $SIZE。"
