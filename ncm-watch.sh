#!/bin/bash
# 扫描网易云下载目录，把新的 .ncm 自动解密到 OUTPUT_DIR。
# 由 ncm-eventd 在 FSEvents 目录事件后调用，也可以手动执行。
# 退出码 75 表示还有文件需要稍后重试。macOS 自带 bash 3.2 兼容。
set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$BASE/config.sh"

STATE_DIR="$BASE/state"
LOG_DIR="$BASE/logs"
LOG_FILE="$LOG_DIR/watch.log"
PROCESSED="$STATE_DIR/processed.tsv"
PENDING="$STATE_DIR/pending.tsv"
LOCK_DIR="$STATE_DIR/lock"
NCMDUMP="$BASE/bin/ncmdump"
FFMPEG="$(command -v ffmpeg 2>/dev/null || true)"

mkdir -p "$OUTPUT_DIR" "$STATE_DIR" "$LOG_DIR"
touch "$PROCESSED" "$PENDING"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

# 日志超过 1MB 时保留最后 2000 行
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt 1048576 ]; then
  tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# 同一时间只允许一个实例运行（mkdir 是原子操作）
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -d "$LOCK_DIR" ]; then
    age=$(( $(date +%s) - $(stat -f%m "$LOCK_DIR") ))
    if [ "$age" -gt 600 ]; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

note() {
  [ "$NOTIFY" = "1" ] || return 0
  /usr/bin/osascript -e "display notification \"$1\" with title \"网易云音乐自动转换\"" >/dev/null 2>&1
}

converted=0
failed=0
pending_count=0

# 把 path\tsize\tmtime 记为已处理
mark_done() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PROCESSED"
  P="$1" awk -F'\t' '$1 != ENVIRON["P"]' "$PENDING" > "$PENDING.tmp" 2>/dev/null || true
  [ -f "$PENDING.tmp" ] && mv "$PENDING.tmp" "$PENDING"
}

handle_output() {
  # $1 = 新生成的文件
  local outfile="$1" mp3
  case "$outfile" in
    *.flac)
      if [ "$MAKE_MP3_COPY" = "1" ]; then
        if [ -z "$FFMPEG" ]; then
          log "  !! 未找到 ffmpeg，跳过 MP3 副本: $outfile"
          return 0
        fi
        mp3="${outfile%.flac}.mp3"
        if [ ! -s "$mp3" ] || [ "$outfile" -nt "$mp3" ]; then
          if "$FFMPEG" -hide_banner -loglevel error -y -i "$outfile" \
              -map 0:a -map 0:v? -c:a libmp3lame -b:a 320k -c:v copy \
              -id3v2_version 3 "$mp3" >> "$LOG_FILE" 2>&1; then
            log "  -> 320k MP3: $mp3"
          else
            log "  !! ffmpeg 转 MP3 失败: $outfile"
          fi
        fi
      fi
      ;;
  esac
}

for root in "${WATCH_DIRS[@]}"; do
  [ -d "$root" ] || continue

  while IFS= read -r -d '' f; do
    size="$(stat -f%z "$f" 2>/dev/null)" || continue
    mtime="$(stat -f%m "$f" 2>/dev/null)" || continue
    now="$(date +%s)"

    # 已转换过且文件未变化
    if grep -Fxq "$f"$'\t'"$size"$'\t'"$mtime" "$PROCESSED" 2>/dev/null; then
      continue
    fi

    # 两次扫描大小一致才算下载完成
    prev="$(P="$f" awk -F'\t' '$1 == ENVIRON["P"] { print $2 }' "$PENDING" 2>/dev/null | tail -n 1)"
    if [ "$prev" != "$size" ]; then
      P="$f" awk -F'\t' '$1 != ENVIRON["P"]' "$PENDING" > "$PENDING.tmp" 2>/dev/null || true
      printf '%s\t%s\n' "$f" "$size" >> "$PENDING.tmp"
      mv "$PENDING.tmp" "$PENDING"
      pending_count=$((pending_count + 1))
      continue
    fi

    if [ $((now - mtime)) -lt "$MIN_AGE_SECONDS" ]; then
      pending_count=$((pending_count + 1))
      continue
    fi

    rel="${f#"$root"/}"
    rel_dir="$(dirname "$rel")"
    if [ "$rel_dir" = "." ]; then
      dest_dir="$OUTPUT_DIR"
    else
      dest_dir="$OUTPUT_DIR/$rel_dir"
    fi
    mkdir -p "$dest_dir"

    base="$(basename "$rel" .ncm)"
    existing=""
    [ -f "$dest_dir/$base.mp3" ] && existing="$dest_dir/$base.mp3"
    [ -f "$dest_dir/$base.flac" ] && existing="$dest_dir/$base.flac"

    # 已经转换过、且输出比 ncm 新 → 直接标记跳过
    if [ -n "$existing" ] && [ "$existing" -nt "$f" ]; then
      log "跳过（已存在）: $rel -> $existing"
      mark_done "$f" "$size" "$mtime"
      continue
    fi

    find "$dest_dir" -maxdepth 1 -type f \( -name '*.mp3' -o -name '*.flac' \) -print 2>/dev/null | sort > "$STATE_DIR/before.$$"

    if output="$("$NCMDUMP" -o "$dest_dir" "$f" 2>&1)"; then
      find "$dest_dir" -maxdepth 1 -type f \( -name '*.mp3' -o -name '*.flac' \) -print 2>/dev/null | sort > "$STATE_DIR/after.$$"
      new_files="$(comm -13 "$STATE_DIR/before.$$" "$STATE_DIR/after.$$")"

      # 覆盖同名文件时不算新文件，这里兜底
      if [ -z "$new_files" ] && [ -n "$existing" ]; then
        new_files="$existing"
      fi

      count=0
      while IFS= read -r outfile; do
        [ -n "$outfile" ] || continue
        [ -f "$outfile" ] || continue
        handle_output "$outfile"
        count=$((count + 1))
      done <<< "$new_files"

      if [ "$count" -gt 0 ]; then
        converted=$((converted + 1))
        log "完成: $rel -> $dest_dir"
        mark_done "$f" "$size" "$mtime"
      else
        failed=$((failed + 1))
        log "!! 未发现输出文件: $rel"
        log "$output"
      fi
      rm -f "$STATE_DIR/before.$$" "$STATE_DIR/after.$$"
    else
      failed=$((failed + 1))
      rm -f "$STATE_DIR/before.$$" "$STATE_DIR/after.$$"
      log "!! 转换失败: $rel"
      log "$output"
    fi
  done < <(find "$root" -path "$OUTPUT_DIR" -prune -o -type f -name '*.ncm' -print0 2>/dev/null)
done

if [ "$converted" -gt 0 ]; then
  log "本轮完成 $converted 首"
  note "已自动转换 $converted 首歌曲 → 已转换文件夹"
fi
if [ "$failed" -gt 0 ]; then
  log "本轮失败 $failed 首"
  note "有 $failed 首转换失败，详情见 logs/watch.log"
fi

# 75 = 还有文件等待稳定，事件守护进程会稍后重试
if [ "$pending_count" -gt 0 ]; then
  exit 75
fi
exit 0
