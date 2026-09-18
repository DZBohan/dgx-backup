#!/usr/bin/env bash
# 让备份脚本能读到备份盘的 SMART 健康数据。
#
#   sudo ~/Scripts/setup-smart-monitoring.sh
#
# 为什么需要这个：SMART 是整套备份里**唯一能在数据坏掉之前预警**的一层。校验和还原演练都是
# 事后的——它们告诉你「已经烂了」。SMART 读的是盘自己报的重分配扇区和待定扇区，坏道刚出现
# 时就会涨，那时候数据往往还是好的、还来得及换盘。
#
# 做两件事：
#   1. 装 smartmontools（已经装了就跳过）
#   2. 加一条 sudoers 规则，让 dzbohan 能免密跑 /usr/sbin/smartctl 这一个程序
#
# 第 2 步是必需的，因为读裸块设备需要 root，而每周备份是以 dzbohan 的身份跑的。
# 规则只覆盖 smartctl 这一个只读诊断工具，不是给账户开免密 sudo。
#
# 反复跑是安全的，跑第二遍不会有副作用。

set -uo pipefail

USER_NAME=${SUDO_USER:-dzbohan}
SMARTCTL=/usr/sbin/smartctl
SUDOERS=/etc/sudoers.d/smartctl
LABEL=DGXBACKUP

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
info() { printf '  ·  %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    red "这个脚本要用 sudo 跑："
    echo "    sudo $0"
    exit 1
fi

echo "为 $USER_NAME 配置 SMART 监控"
echo

# ---------- 1. 装 smartmontools ----------
echo "1. smartmontools"
if [ -x "$SMARTCTL" ]; then
    ok "已经装了（$("$SMARTCTL" --version | head -1 | awk '{print $1,$2}')）"
else
    info "正在安装"
    if ! apt-get install -y smartmontools >/dev/null 2>&1; then
        red "安装失败。先试试 sudo apt update，再重跑这个脚本。"
        exit 1
    fi
    [ -x "$SMARTCTL" ] || { red "装完了但找不到 $SMARTCTL，意料之外，停在这里。"; exit 1; }
    ok "装好了"
fi

# ---------- 2. sudoers 规则 ----------
echo
echo "2. 免密规则（只针对 smartctl 这一个程序）"

# ⚠️ 绝对不能直接往 /etc/sudoers.d/ 里写。语法错误的 sudoers 文件会让整个 sudo 失效，
# 而修它又需要 sudo，就锁死了。所以：先写临时文件 → visudo -c 校验 → 通过了才 install。
TMP=$(mktemp /tmp/smartctl-sudoers.XXXXXX)
trap 'rm -f "$TMP"' EXIT
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$SMARTCTL" > "$TMP"

if ! visudo -c -f "$TMP" >/dev/null 2>&1; then
    red "生成的规则没通过 visudo 校验，没有安装。内容是："
    cat "$TMP"
    exit 1
fi
ok "语法校验通过"

if [ -f "$SUDOERS" ] && diff -q "$TMP" "$SUDOERS" >/dev/null 2>&1; then
    ok "规则已经在了，内容一致，不动它"
else
    install -m 440 -o root -g root "$TMP" "$SUDOERS"
    ok "已写入 $SUDOERS（权限 440）"
fi

# 装完再整体校验一次 /etc/sudoers 体系。万一这里失败，说明别处本来就有问题，
# 而我们刚加的这个文件是能撤掉的，所以立刻撤掉，宁可没有 SMART 也不要坏掉的 sudo。
if ! visudo -c >/dev/null 2>&1; then
    red "装进去之后整体 sudoers 校验失败，已经把刚加的文件撤掉。"
    rm -f "$SUDOERS"
    exit 1
fi
ok "整体 sudoers 校验通过"

# ---------- 3. 以那个用户的身份真的试一次 ----------
# 关键：不能只验 root 能读。要验的是**备份脚本将来的运行身份**能不能读。
# 2026-09-17 犯过一次同类错误：写给别人跑的脚本只测了自己那条路径。
echo
echo "3. 以 $USER_NAME 的身份实测"
DEV=$(lsblk -rno PATH,LABEL | awk -v l="$LABEL" '$2==l {print $1; exit}')
if [ -z "$DEV" ]; then
    info "备份盘 $LABEL 现在没插，跳过实测"
    info "插上之后可以自己验：sudo -n $SMARTCTL -H -d sat /dev/sdX"
else
    DISK=${DEV%[0-9]*}
    if sudo -u "$USER_NAME" sudo -n "$SMARTCTL" -H -d sat "$DISK" >/dev/null 2>&1; then
        ok "$USER_NAME 现在可以免密读 SMART 了"
    else
        red "还是读不了。规则装上了但没生效，需要人看一眼。"
        exit 1
    fi

    echo
    echo "4. 这块盘现在的状态"
    OUT=$("$SMARTCTL" -H -A -i -d sat "$DISK" 2>/dev/null)
    printf '  %-26s %s\n' "型号:"       "$(echo "$OUT" | grep -i 'Device Model\|Model Number' | cut -d: -f2- | xargs)"
    printf '  %-26s %s\n' "容量:"       "$(echo "$OUT" | grep -i 'User Capacity' | cut -d: -f2- | sed 's/\[.*//' | xargs)"
    printf '  %-26s %s\n' "整体健康:"   "$(echo "$OUT" | grep -i 'overall-health' | cut -d: -f2- | xargs)"
    printf '  %-26s %s\n' "通电小时:"   "$(echo "$OUT" | awk '/Power_On_Hours/{print $10}')"
    printf '  %-26s %s\n' "启停次数:"   "$(echo "$OUT" | awk '/Start_Stop_Count/{print $10}')"
    printf '  %-26s %s\n' "重分配扇区:" "$(echo "$OUT" | awk '/Reallocated_Sector_Ct/{print $10}')"
    printf '  %-26s %s\n' "待定扇区:"   "$(echo "$OUT" | awk '/Current_Pending_Sector/{print $10}')"
    printf '  %-26s %s\n' "无法纠正:"   "$(echo "$OUT" | awk '/Offline_Uncorrectable/{print $10}')"
    echo
    info "重分配扇区和待定扇区应该都是 0。不是 0 就是换盘的信号。"
    info "通电小时数能看出这块盘是全新还是二手。"
fi

echo
echo "配置完成。下次备份会自动读 SMART，异常会发 Telegram 给你。"
