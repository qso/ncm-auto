# ncm-auto

macOS 上的网易云音乐下载自动转换工具：用系统原生 **FSEvents** 监听下载目录，
发现新的 `.ncm` 文件后自动解密为 **MP3 / FLAC**。事件驱动、空闲零 CPU、
无需手动操作，也不需要任何轮询定时器。

> **English**: An event-driven macOS agent that watches NetEase Cloud Music
> downloads and automatically decrypts `.ncm` files to MP3/FLAC using native
> FSEvents + launchd. No polling, no idle CPU usage.

[![Platform](https://img.shields.io/badge/platform-macOS-black.svg)](#系统要求)
[![License](https://img.shields.io/github/license/qso/ncm-auto.svg)](LICENSE)

## 特性

- **事件驱动**：基于 macOS FSEvents，目录有变化才运行；空闲时进程阻塞在内核事件上，不扫盘
- **自动合并写入**：连续的文件写入事件会合并，并等待文件大小稳定后才转换
- **保留目录结构**：`电台节目/xxx.ncm` → `已转换/电台节目/xxx.mp3`
- **无损优先**：ncm 内是 FLAC 时保留 FLAC，并可选生成 320kbps MP3 副本
- **元数据完整**：标题、歌手、专辑等标签由 ncmdump 写入
- **不删源文件**：原始 `.ncm` 始终保留
- **系统原生**：监听程序仅使用 C + CoreServices FSEvents，launchd 保活，无 Electron / 无后台轮询
- **零第三方运行时**：除 `taglib`（ncmdump 依赖）和可选的 `ffmpeg` 外，无需额外服务

## 音质说明（重要）

本项目**只解密、不转码**。网易云下载的 `.ncm` 是加密容器，里面本身就是
MP3 或 FLAC；ncmdump 只是把原始音频取出来：

| 网易云下载音质设置 | ncm 内实际音频 | 本工具输出 |
|---|---|---|
| 标准 | MP3 128kbps | 原样 MP3 |
| 较高 | MP3 192kbps | 原样 MP3 |
| 极高 | MP3 320kbps | 原样 MP3 |
| 无损 | FLAC | FLAC + 320kbps MP3 副本（可配置） |

因此想要**最高音质**：在网易云音乐 **设置 → 下载设置 → 下载音质** 中选择
**「无损」**（需要会员）。把 FLAC 转成 MP3 只会降低音质，320kbps 已经是
MP3 的上限；`config.sh` 中的 `MAKE_MP3_COPY` 控制是否额外生成 MP3 副本。

## 系统要求

- macOS 11 或更高版本
- Apple Silicon（arm64）或 Intel Mac
- [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/)（提供 `clang`）
  ```bash
  xcode-select --install
  ```
- [Homebrew](https://brew.sh/)
- [`taglib`](https://formulae.brew.sh/formula/taglib) — ncmdump 的运行时依赖
  ```bash
  brew install taglib
  ```
- [`ffmpeg`](https://formulae.brew.sh/formula/ffmpeg) — **可选**，仅在需要从 FLAC 生成 MP3 副本时使用
  ```bash
  brew install ffmpeg
  ```

`ncmdump` 无需手动安装：`install.sh` 会自动下载官方 macOS arm64 预编译版
（并校验 SHA-256）；Intel Mac 会自动从源码编译。

## 快速开始

```bash
git clone https://github.com/qso/ncm-auto.git
cd ncm-auto

brew install taglib          # 必需
brew install ffmpeg          # 可选：无损 → 320k MP3 副本

./install.sh
```

安装脚本会：

1. 用系统 `clang` 编译 FSEvents 监听程序 `bin/ncm-eventd`
2. 自动获取 `ncmdump`（Apple Silicon 下载官方二进制，Intel 从源码编译）
3. 生成并加载 launchd 任务 `com.ncm-auto.agent`
4. 立即执行一次补扫，处理之前已下载的文件

之后在网易云音乐里正常点击下载即可。文件下载完成约 5–15 秒后，
转换结果会出现在 `~/Music/网易云音乐/已转换/`。

## 配置

编辑 `config.sh`，下一次事件触发时自动生效，无需重装：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WATCH_DIRS` | `("$HOME/Music/网易云音乐")` | 监听的下载目录，可写多个（递归） |
| `OUTPUT_DIR` | `"$HOME/Music/网易云音乐/已转换"` | 输出目录，保留子目录结构 |
| `MAKE_MP3_COPY` | `1` | 无损时是否额外生成 320kbps MP3 副本 |
| `MIN_AGE_SECONDS` | `10` | 文件最后修改后至少等待多少秒才转换 |
| `NOTIFY` | `1` | 转换完成后是否弹 macOS 通知 |

修改监听目录后需要重新运行 `./install.sh`（launchd 参数在 plist 中）。

## 使用

```bash
# 查看实时日志（在项目目录内）
tail -f logs/watch.log

# 手动立即扫描一次（通常不需要）
./ncm-watch.sh

# 查看后台任务状态
launchctl print gui/$(id -u)/com.ncm-auto.agent

# 停止并卸载后台任务（保留已转换的音乐）
./uninstall.sh
```

## 工作原理

```
网易云音乐下载 .ncm
        │
        ▼
FSEvents 通知 ncm-eventd（launchd 常驻）
        │  合并 3 秒内的连续写入事件
        ▼
ncm-watch.sh 扫描 .ncm 文件
        │  大小稳定 + 修改时间超过 10 秒
        ▼
ncmdump 解密 → 原始 MP3 / FLAC
        │
        ├─ FLAC + MAKE_MP3_COPY=1 → ffmpeg → 320kbps MP3
        ▼
~/Music/网易云音乐/已转换/（保留子目录结构）
```

- 已转换且源文件未变化时不会重复转换；重新下载会重新转换
- 输出文件比 ncm 新时直接跳过
- 未写完的文件会由守护进程短暂延迟重试，仍然由事件触发，不做周期扫描

## 项目结构

```
ncm-auto/
├── bin/
│   ├── ncmdump          # 自动获取（不提交到仓库）
│   └── ncm-eventd       # install.sh 编译生成（不提交到仓库）
├── ncm-eventd.c         # FSEvents 监听程序（C + CoreServices）
├── ncm-watch.sh         # 扫描 + 转换脚本
├── config.sh            # 用户配置
├── install.sh           # 安装 / 启动
├── uninstall.sh         # 停止 / 卸载
├── logs/                # 运行日志（不提交）
└── state/               # 已处理记录与锁（不提交）
```

## 常见问题

**没有生成文件？**

先看日志：

```bash
tail -n 50 logs/watch.log
tail -n 50 logs/launchd.err.log
```

确认 `config.sh` 里的 `WATCH_DIRS` 与网易云实际下载目录一致
（网易云音乐 → 设置 → 下载设置 → 下载目录）。

**报错 `Library not loaded: libtag.2.dylib`**

```bash
brew install taglib
```

**不生成 MP3 副本**

```bash
brew install ffmpeg
```

或者把 `config.sh` 中的 `MAKE_MP3_COPY` 设为 `0` 以只保留原始格式。

**日志提示 `missing album can't fix album image`**

新版网易云的部分 ncm 文件不包含封面，ncmdump 不会联网补图。音频本身正常。

**监听目录位于桌面 / 文稿 / 下载文件夹时没有反应**

这些目录受 macOS TCC 保护。给当前终端或 launchd 进程授予
「完全磁盘访问权限」（系统设置 → 隐私与安全性 → 完全磁盘访问权限），
然后重新运行 `./install.sh`。

**Intel Mac 上安装失败**

确认已安装构建依赖：

```bash
brew install cmake taglib
```

**如何确认 ncmdump 能正常工作？**

```bash
./bin/ncmdump -v
./bin/ncmdump "某个文件.ncm"
```

## 合规与免责声明

- 本项目仅用于转换**你本人通过网易云音乐客户端正常下载**的文件，方便个人设备播放与备份。
- 请勿将转换结果用于分发、传播或任何商业用途。
- 本项目不提供、不绕过任何付费会员或版权限制；能否下载无损取决于你的账号权限。
- 使用本项目产生的任何后果由使用者自行承担。

## 第三方组件

- [taurusxin/ncmdump](https://github.com/taurusxin/ncmdump) — MIT License，负责 `.ncm` 解密与标签写入
- [TagLib](https://taglib.org/) — LGPL/MPL，ncmdump 的标签库依赖
- [FFmpeg](https://ffmpeg.org/) — 可选，用于 FLAC → MP3 转码

## License

[MIT](LICENSE) © 2026 qso
