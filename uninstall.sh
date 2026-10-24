#!/bin/bash
# 停止并移除 launchd 常驻任务（不删除已转换的音乐）。
set -u

LABEL="com.qso.ncm-auto"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "已停止并移除 $LABEL（转换工具和已转换的音乐保留）。"
