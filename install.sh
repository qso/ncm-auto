#!/bin/bash
# 安装 FSEvents 事件监听守护进程：目录有变化才触发转换，空闲零轮询。
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$BASE/config.sh"

LABEL="com.ncm-auto.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
EVENTD="$BASE/bin/ncm-eventd"
NCMDUMP="$BASE/bin/ncmdump"

NCMDUMP_VERSION="1.5.1"
NCMDUMP_URL="https://github.com/taurusxin/ncmdump/releases/download/${NCMDUMP_VERSION}/ncmdump-${NCMDUMP_VERSION}-macos-arm64.zip"
NCMDUMP_SHA256="5b2888b8a53e7a817a75d4e79c872840e37f200b08394ec3b4370430347339c4"

die() { echo "错误: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "本项目仅支持 macOS"

mkdir -p "$BASE/logs" "$BASE/state" "$HOME/Library/LaunchAgents"

# ---- 编译 FSEvents 监听程序（macOS 自带 clang 和 CoreServices） ----
if [ ! -x "$EVENTD" ] || [ "$BASE/ncm-eventd.c" -nt "$EVENTD" ]; then
  command -v clang >/dev/null 2>&1 || die "缺少编译器，请先安装 Xcode Command Line Tools: xcode-select --install"
  echo "编译 ncm-eventd ..."
  /usr/bin/clang -O2 -Wall -framework CoreServices -o "$EVENTD" "$BASE/ncm-eventd.c"
fi

check_taglib() {
  if ! command -v brew >/dev/null 2>&1; then
    die "未找到 Homebrew。请先安装 Homebrew，然后执行: brew install taglib"
  fi
  if ! brew --prefix taglib >/dev/null 2>&1; then
    die "缺少 taglib 依赖。请先执行: brew install taglib"
  fi
}

# ---- 获取 ncmdump（优先使用已存在的二进制） ----
ensure_ncmdump() {
  if [ -x "$NCMDUMP" ]; then
    return 0
  fi

  check_taglib
  local arch tmp
  arch="$(uname -m)"

  if [ "$arch" = "arm64" ]; then
    echo "下载 ncmdump ${NCMDUMP_VERSION}（macOS arm64）..."
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$tmp/ncmdump.zip" "$NCMDUMP_URL"
    echo "$NCMDUMP_SHA256  $tmp/ncmdump.zip" | shasum -a 256 -c - >/dev/null 2>&1 \
      || die "ncmdump 下载校验失败（SHA-256 不匹配）"
    unzip -q "$tmp/ncmdump.zip" -d "$BASE/bin"
    rm -rf "$tmp"
  else
    echo "Intel Mac：从源码编译 ncmdump ${NCMDUMP_VERSION} ..."
    command -v cmake >/dev/null 2>&1 || die "需要 cmake，请执行: brew install cmake taglib"
    command -v git >/dev/null 2>&1 || die "需要 git"
    tmp="$(mktemp -d)"
    git clone --depth 1 --branch "$NCMDUMP_VERSION" \
      https://github.com/taurusxin/ncmdump.git "$tmp/src" >/dev/null 2>&1 \
      || die "克隆 ncmdump 源码失败"
    cmake -S "$tmp/src" -B "$tmp/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$tmp/build" -j"$(sysctl -n hw.ncpu)" >/dev/null
    cp "$tmp/build/ncmdump" "$NCMDUMP"
    rm -rf "$tmp"
  fi

  chmod +x "$NCMDUMP"
}

ensure_ncmdump
"$NCMDUMP" -v >/dev/null 2>&1 || die "ncmdump 无法运行，请确认已执行: brew install taglib"

if [ "$MAKE_MP3_COPY" = "1" ] && ! command -v ffmpeg >/dev/null 2>&1; then
  echo "提示: 未找到 ffmpeg，无损文件将只保留 FLAC，不生成 320k MP3 副本。"
  echo "      需要 MP3 副本时请执行: brew install ffmpeg"
fi

chmod +x "$BASE/ncm-watch.sh" "$BASE/uninstall.sh" 2>/dev/null || true

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

WATCH_ARGS=""
for d in "${WATCH_DIRS[@]}"; do
  WATCH_ARGS="$WATCH_ARGS    <string>$(xml_escape "$d")</string>"$'\n'
done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EVENTD</string>
    <string>$BASE/ncm-watch.sh</string>
$WATCH_ARGS  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$BASE/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$BASE/logs/launchd.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "已安装并启动：${LABEL}（FSEvents 事件驱动，无定时轮询）"
echo "监听目录：${WATCH_DIRS[*]}"
echo "输出目录：$OUTPUT_DIR"
echo "查看日志：tail -f \"$BASE/logs/watch.log\""
