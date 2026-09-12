#!/usr/bin/env bash
# =============================================================================
#  dsh-ubuntu-icon-icon — Ubuntu / Linux desktop launcher for DeepSeek Harness (DSH)
#  Ubuntu 版（Linux 上可直接用的那一版）
# -----------------------------------------------------------------------------
#  What it does
#    1. Installs an app-menu entry + icon for "DSH (GPT knot icon)".
#    2. Clicking that entry: reuses an already-running DSH Web GUI, otherwise
#       starts `dsh web`, waits for the port, then opens the GUI in an
#       app-mode window (Chrome/Chromium/Edge/Brave) — a browser tab is the
#       fallback.
#
#  Usage
#    ./dsh-ubuntu-icon.sh install     [--icon FILE]      # install for this user
#    ./dsh-ubuntu-icon.sh install     --system [--icon FILE]
#    ./dsh-ubuntu-icon.sh uninstall   [--system]
#    ./dsh-ubuntu-icon.sh run                            # what the icon runs
#    ./dsh-ubuntu-icon.sh check                          # environment report
#    ./dsh-ubuntu-icon.sh --help
#
#  Environment overrides
#    DSH_CMD        how to start the web GUI (default: dsh web / npx fallback)
#    DSH_PORT       preferred port (default 3080; when a DSH instance already
#                   listens on another port, that port wins)
#    DSH_WEB_URL    open this URL verbatim instead of probing
#    DSH_WORKSPACE  workspace root passed through as the invoking directory
#    DSH_APP_FLAGS  extra flags for the app-mode window (default --ozone-platform-hint=auto)
#    DSH_BROWSER    force a browser executable
#    DSH_NO_START=1 never start dsh; only attach to a running instance
# =============================================================================
set -u
umask 022

APP_NAME="DSH (GPT knot icon)"
APP_ID="dsh-ubuntu-icon"
ICON_NAME="dsh-ubuntu-icon"
VERSION="1.0.0"

DEFAULT_PORT="${DSH_PORT:-3080}"
WAIT_TIMEOUT="${DSH_WAIT_TIMEOUT:-25}"
LOG_FILE="${DSH_LOG_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/dsh-ubuntu-icon.log}"
SERVER_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsh-ubuntu-icon"
SERVER_LOG="$SERVER_LOG_DIR/dsh-web.log"

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# -----------------------------------------------------------------------------
# small helpers
# -----------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  mkdir -p -- "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(ts)" "$$" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

say()  { printf '  %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; log "WARN: $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

die() { printf 'xx %s\n' "$*" >&2; log "FATAL: $*"; exit 1; }

notify() { # notify <summary> <body> — always fails: callers use it on the error path
  local title="$1" body="$2" shown=0
  if [ "${DSH_NO_DIALOG:-0}" != "1" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    # timeout: a GUI dialog must never hang a launch (zenity waiting on a dead X
    # display is the classic case), and its exit status must not leak to the caller.
    # DSH_NO_DIALOG=1 forces console-only output (used by the test suite).
    if have zenity; then
      if have timeout; then timeout 20 zenity --error --no-markup --title="$title" --text="$body" 2>/dev/null && shown=1
      else zenity --error --no-markup --title="$title" --text="$body" 2>/dev/null && shown=1; fi
    fi
    if [ "$shown" = 0 ] && have kdialog; then
      if have timeout; then timeout 20 kdialog --error "$body" --title "$title" 2>/dev/null && shown=1
      else kdialog --error "$body" --title "$title" 2>/dev/null && shown=1; fi
    fi
    if [ "$shown" = 0 ] && have notify-send; then
      if have timeout; then timeout 10 notify-send -u critical -a "$APP_NAME" "$title" "$body" 2>/dev/null && shown=1
      else notify-send -u critical -a "$APP_NAME" "$title" "$body" 2>/dev/null && shown=1; fi
    fi
    if [ "$shown" = 0 ] && have xmessage; then
      if have timeout; then printf '%s\n\n%s\n' "$title" "$body" | timeout 20 xmessage -center -file - 2>/dev/null && shown=1
      else printf '%s\n\n%s\n' "$title" "$body" | xmessage -center -file - 2>/dev/null && shown=1; fi
    fi
  fi
  printf '\n%s\n%s\n' "$title" "$body" >&2
  log "NOTIFY(shown=${shown}): $title"
  return 1
}

# HTTP probe: any response (even 401/403) means "something answers here".
http_alive() { # http_alive <port>
  local port="$1" code=""
  if have curl; then
    code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != "000" ]
    return
  fi
  if have wget; then
    wget -q -T 2 -O /dev/null "http://127.0.0.1:${port}/" 2>/dev/null
    return
  fi
  port_listening "$port"
}

# TCP probe: is anything listening on this loopback port?
# A live GUI accepted the TCP connection in 106 ms while plain HTTP to it timed
# out (its Host/token gate holds the reply), so "listening" — not "HTTP 200" —
# is the reliable readiness test. /dev/tcp keeps this dependency-free.
port_listening() { # port_listening <port>
  local port="$1"
  if have ss; then
    ss -ltnH 2>/dev/null | grep -qE "([.:]|:::)${port}[[:space:]]" && return 0
  fi
  if have timeout; then
    timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null
    return
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

# The port a dsh process listens on (from `ss -ltnpH`, e.g. 127.0.0.1:3080).
dsh_pid_listen_port() { # dsh_pid_listen_port <pid>
  local pid="$1" port="" ino hex
  if have ss; then
    port="$(ss -ltnpH 2>/dev/null | grep -F "pid=${pid}," \
      | sed -n 's/.*[.:]\([0-9]\{2,5\}\)[[:space:]].*/\1/p' | head -n 1)"
  fi
  if [ -z "$port" ] && [ -d "/proc/$pid/fd" ]; then
    for ino in $(ls -l "/proc/$pid/fd" 2>/dev/null | sed -n 's/.*socket:\[\([0-9]*\)\].*/\1/p'); do
      hex="$(awk -v i="$ino" '$10 == i && $4 == "0A" { split($2, a, ":"); print a[2]; exit }' /proc/net/tcp 2>/dev/null)"
      if [ -n "$hex" ]; then port="$((16#$hex))"; break; fi
    done
  fi
  [ -z "$port" ] && return 1
  printf '%s' "$port"
}

# Find the port a running DSH Web GUI listens on: the preferred port first, then
# any listener whose process belongs to a dsh process.
# DSH_DETECT_SCAN=0 probes only the preferred port (used by the test suite to make
# the "nothing is running" branch deterministic on a machine that does have one).
detect_running_port() {
  local port pid
  if http_alive "$DEFAULT_PORT" || port_listening "$DEFAULT_PORT"; then
    printf '%s' "$DEFAULT_PORT"; return 0
  fi
  [ "${DSH_DETECT_SCAN:-1}" = "0" ] && return 1
  for pid in $(pgrep -f '(^|/)dsh( |$)' 2>/dev/null); do
    port="$(dsh_pid_listen_port "$pid" 2>/dev/null || true)"
    if [ -n "$port" ] && port_listening "$port"; then printf '%s' "$port"; return 0; fi
  done
  if have ss; then
    port="$(ss -ltnpH 2>/dev/null | grep -i 'dsh' \
      | sed -n 's/.*[.:]\([0-9]\{2,5\}\)[[:space:]].*/\1/p' \
      | while read -r p; do port_listening "$p" && { printf '%s' "$p"; break; }; done)"
    if [ -n "${port:-}" ]; then printf '%s' "$port"; return 0; fi
  fi
  return 1
}

# -----------------------------------------------------------------------------
# DSH command discovery
# -----------------------------------------------------------------------------
dsh_command() {
  if [ -n "${DSH_CMD:-}" ]; then printf '%s' "$DSH_CMD"; return 0; fi
  if have dsh; then printf 'dsh web'; return 0; fi
  # npx cache / global installs that are not on PATH
  local c
  for c in "$HOME"/.npm/_npx/*/node_modules/.bin/dsh \
           "$HOME"/.local/share/npm/bin/dsh \
           /usr/local/bin/dsh /usr/bin/dsh \
           "$HOME"/.local/bin/dsh; do
    [ -x "$c" ] && { printf '%s web' "$c"; return 0; }
  done
  if have npx; then printf 'npx -y @deepseek-ai/dsh web'; return 0; fi
  return 1
}

# -----------------------------------------------------------------------------
# browser / app-mode window
# -----------------------------------------------------------------------------
find_browser() {
  local candidate
  if [ -n "${DSH_BROWSER:-}" ]; then
    # Trust DSH_BROWSER only if it really is an executable: a typo must fail loudly
    # here rather than silently "succeeding" with nothing on screen.
    if [ -x "$DSH_BROWSER" ]; then printf '%s' "$DSH_BROWSER"; return 0; fi
    if have "$DSH_BROWSER"; then printf '%s' "$(command -v "$DSH_BROWSER")"; return 0; fi
    warn "DSH_BROWSER=$DSH_BROWSER 不是可执行命令，忽略它"
    log "DSH_BROWSER not executable: $DSH_BROWSER"
  fi
  for candidate in \
    google-chrome google-chrome-stable chromium chromium-browser \
    microsoft-edge microsoft-edge-stable brave-browser brave \
    vivaldi vivaldi-stable; do
    if have "$candidate"; then printf '%s' "$candidate"; return 0; fi
  done
  for candidate in \
    /snap/bin/chromium /snap/bin/chromium-browser /snap/bin/brave \
    /var/lib/flatpak/exports/bin/com.google.Chrome \
    "$HOME/.local/share/flatpak/exports/bin/com.google.Chrome" \
    /var/lib/flatpak/exports/bin/org.chromium.Chromium; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

open_gui() { # open_gui <url>
  local url="$1" browser="" pid="" i=0
  local flags="${DSH_APP_FLAGS:---ozone-platform-hint=auto}"

  if browser="$(find_browser)"; then
    # A dedicated profile dir keeps the app window out of the normal browser
    # session and lets an app window start while the browser is already open.
    local app_profile="${XDG_DATA_HOME:-$HOME/.local/share}/dsh-ubuntu-icon/chromium-profile"
    mkdir -p -- "$app_profile" 2>/dev/null || app_profile=""
    # shellcheck disable=SC2086
    nohup "$browser" --app="$url" $flags \
      ${app_profile:+--user-data-dir="$app_profile"} \
      --no-first-run --no-default-browser-check \
      >>"$LOG_FILE" 2>&1 &
    pid=$!
    # 0.4 s is long enough for "command not found"/bad flag/one-shot wrapper to die,
    # short enough not to delay the launch, and fire-and-forget stays async.
    for i in 1 2 3 4; do
      kill -0 "$pid" 2>/dev/null || break
      have sleep && sleep 0.1
    done
    if ! kill -0 "$pid" 2>/dev/null; then
      log "browser exited at once: $browser --app=$url"
      warn "浏览器启动即退出：$browser（详见 $LOG_FILE）"
      return 1
    fi
    log "opened app window: $browser --app=$url (pid $pid)"
    say "已用 app 模式打开：$browser"
    return 0
  fi

  if have xdg-open; then
    # Check the handoff instead of backgrounding blindly: with no usable session
    # xdg-open fails immediately, and the user must not be told "opened".
    if xdg-open "$url" >>"$LOG_FILE" 2>&1; then
      log "xdg-open $url -> ok"
      say "已交给默认浏览器打开（xdg-open）"
      return 0
    fi
    log "xdg-open failed (url=$url), rc=$?"
    warn "xdg-open 打不开这个地址（没有可用的桌面会话？）"
    printf '\n  请手动打开这个地址：\n      %s\n\n' "$url"
    return 1
  fi

  if have sensible-browser; then
    nohup sensible-browser "$url" >>"$LOG_FILE" 2>&1 &
    log "sensible-browser $url"
    say "已交给 sensible-browser 打开"
    return 0
  fi

  log "no browser found (url=$url)"
  warn "没找到可用的浏览器"
  printf '\n  请手动打开这个地址：\n      %s\n\n' "$url"
  return 1
}

# -----------------------------------------------------------------------------
# run: attach to a running GUI, or start one, then open it
# -----------------------------------------------------------------------------
start_dsh() { # start_dsh <cmd> <port>
  local cmd="$1" port="$2"
  mkdir -p -- "$SERVER_LOG_DIR" 2>/dev/null || true
  log "starting: $cmd --no-open --port $port"
  printf '\n  正在启动 DSH Web GUI（首次启动可能需要几秒）…\n'
  # shellcheck disable=SC2086
  ( cd "${DSH_WORKSPACE:-$HOME}" 2>/dev/null || cd "$HOME"
    nohup $cmd --no-open --port "$port" >>"$SERVER_LOG" 2>&1 &
    echo $! >"$SERVER_LOG_DIR/dsh-web.pid" ) || return 1
  return 0
}

url_from_server_log() {
  [ -f "$SERVER_LOG" ] || return 1
  sed -n 's/^dsh web:[[:space:]]*\(http[^[:space:]]*\).*/\1/p' "$SERVER_LOG" | tail -n 1
}

wait_for_port() { # wait_for_port <port> <seconds>
  local port="$1" deadline=$(( SECONDS + $2 ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    # The token URL line is the strongest readiness signal, so look for it first;
    # the TCP probe then covers servers that print nothing (or hold the HTTP reply).
    url_from_server_log | grep -q . && return 0
    port_listening "$port" && return 0
    sleep 1
  done
  return 1
}

do_run() {
  log "run: start (port=$DEFAULT_PORT, no_start=${DSH_NO_START:-0})"

  if [ -n "${DSH_WEB_URL:-}" ]; then
    say "使用 DSH_WEB_URL=${DSH_WEB_URL}"
    open_gui "$DSH_WEB_URL"; return $?
  fi

  local port
  if port="$(detect_running_port)"; then
    if [ "$port" = "$DEFAULT_PORT" ]; then
      say "检测到已运行的 DSH（127.0.0.1:${port}），直接打开"
    else
      say "检测到已运行的 DSH 在 127.0.0.1:${port}（不是首选端口 ${DEFAULT_PORT}），复用它，不另起服务"
    fi
    open_gui "http://127.0.0.1:${port}/"
    return $?
  fi

  if [ "${DSH_NO_START:-0}" = "1" ]; then
    notify "$APP_NAME" "没有检测到正在运行的 DSH Web GUI（探测端口 127.0.0.1:${DEFAULT_PORT}，也不扫描其它端口），且 DSH_NO_START=1。请先在终端运行：dsh web"
    return 1
  fi

  local cmd
  if ! cmd="$(dsh_command)"; then
    notify "$APP_NAME" "找不到 dsh 命令。请先安装/运行 DSH（例如：npx @deepseek-ai/dsh web），或用 DSH_CMD 指定启动命令。"
    return 1
  fi

  : >"$SERVER_LOG" 2>/dev/null || true
  start_dsh "$cmd" "$DEFAULT_PORT" || {
    notify "$APP_NAME" "启动失败：$cmd。详情见 $SERVER_LOG"
    return 1
  }

  if ! wait_for_port "$DEFAULT_PORT" "$WAIT_TIMEOUT"; then
    local tail_log=""
    tail_log="$(tail -n 6 "$SERVER_LOG" 2>/dev/null || true)"
    notify "$APP_NAME" "等了 ${WAIT_TIMEOUT}s，DSH 仍未在 127.0.0.1:${DEFAULT_PORT} 响应。日志：$SERVER_LOG
${tail_log}"
    return 1
  fi

  local url
  url="$(url_from_server_log || true)"
  [ -n "$url" ] || url="http://127.0.0.1:${DEFAULT_PORT}/"
  log "ready: $url"
  open_gui "$url"
}

# -----------------------------------------------------------------------------
# install / uninstall
# -----------------------------------------------------------------------------
install_icon() { # install_icon <icon-file> <prefix>
  local src="$1" prefix="$2" ext size_dir base
  [ -f "$src" ] || die "图标文件不存在：$src"
  ext="${src##*.}"
  case "$ext" in
    svg|SVG) size_dir="scalable"; base="$ICON_NAME.svg" ;;
    png|PNG) size_dir="256x256";  base="$ICON_NAME.png" ;;
    *)       die "图标格式不支持（用 .svg 或 .png）：$src" ;;
  esac
  install -Dm644 "$src" "$prefix/share/icons/hicolor/${size_dir}/apps/${base}"
  say "图标   → $prefix/share/icons/hicolor/${size_dir}/apps/${base}"
}

write_desktop() { # write_desktop <target-file> <exec-path>
  local target="$1" exec_path="$2"
  cat >"$target" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=${APP_NAME}
Name[zh_CN]=DSH（GPT 蓝结图标）
Comment=DeepSeek Harness Web GUI in an app window
Comment[zh_CN]=以独立应用窗口打开 DeepSeek Harness Web GUI
Exec=${exec_path} run
Icon=${ICON_NAME}
Terminal=false
Categories=Development;
Keywords=dsh;deepseek;harness;ai;gpt;chat;
StartupNotify=true
EOF
  chmod 644 "$target"
  say "菜单项 → $target"
  if have desktop-file-validate; then
    local out=""
    out="$(desktop-file-validate "$target" 2>&1 || true)"
    if [ -n "$out" ]; then warn "desktop-file-validate 提示：$out"; else say "校验   → desktop-file-validate 通过"; fi
  fi
}

refresh_caches() { # refresh_caches <prefix>
  local prefix="$1"
  if have update-desktop-database; then update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true; fi
  if have gtk-update-icon-cache; then gtk-update-icon-cache -qtf "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true; fi
}

do_install() {
  local system=0 icon_src=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --system) system=1 ;;
      --icon) shift; icon_src="${1:-}" ;;
      *) die "未知参数：$1" ;;
    esac
    shift
  done

  local prefix bindir target install_as
  if [ "$system" = 1 ]; then
    prefix="/usr/local"; bindir="/usr/local/bin"
    target="/usr/local/share/applications/${APP_ID}.desktop"
  else
    prefix="$HOME/.local"; bindir="$HOME/.local/bin"
    target="$HOME/.local/share/applications/${APP_ID}.desktop"
  fi
  install_as="$bindir/dsh-ubuntu-icon"

  # 1) the launcher script itself
  if [ "$system" = 1 ] && [ "$(id -u)" != "0" ]; then
    have sudo || die "系统级安装需要 root 或 sudo"
    sudo install -Dm755 "${BASH_SOURCE[0]}" "$install_as" || die "无法写入 $install_as"
  else
    install -Dm755 "${BASH_SOURCE[0]}" "$install_as" || die "无法写入 $install_as"
  fi
  say "启动器 → $install_as"

  # 2) icon: user-supplied file, else the bundled one next to this script
  if [ -z "$icon_src" ]; then
    local cand
    for cand in "$SELF_DIR/${ICON_NAME}.svg" "$SELF_DIR/icon/${ICON_NAME}.svg" \
                "$SELF_DIR/icons/${ICON_NAME}.svg" "$SELF_DIR/../assets/knot.svg" \
                "$SELF_DIR/${ICON_NAME}.png"; do
      [ -f "$cand" ] && { icon_src="$cand"; break; }
    done
  fi
  [ -n "$icon_src" ] || die "找不到图标文件；用 --icon /path/to/icon.svg 指定"
  install_icon "$icon_src" "$prefix"

  # 2b) raster sizes for the menu / dock, shipped prebuilt under icons/hicolor
  if [ -d "$SELF_DIR/icons/hicolor" ]; then
    cp -r -- "$SELF_DIR/icons/hicolor/." "$prefix/share/icons/hicolor/" || die "无法写入图标目录"
    say "图标   → $prefix/share/icons/hicolor/{16,24,32,48,64,128,256,512}x*/apps/${ICON_NAME}.png"
  fi

  # 3) desktop entry
  mkdir -p -- "$(dirname -- "$target")"
  write_desktop "$target" "$install_as"

  # 4) caches
  refresh_caches "$prefix"

  cat <<EOF

✔ 安装完成（${APP_NAME}，v${VERSION}）
    · 在应用菜单里搜索 "DSH" 或 "GPT"，点击即用
    · 命令行自检：  dsh-ubuntu-icon check
    · 直接打开：    dsh-ubuntu-icon run
    · 卸载：        dsh-ubuntu-icon uninstall $([ "$system" = 1 ] && echo --system)

   日志：$LOG_FILE
   服务输出：$SERVER_LOG
EOF
}

do_uninstall() {
  local system=0
  [ "${1:-}" = "--system" ] && system=1
  local prefix bindir target
  if [ "$system" = 1 ]; then
    prefix="/usr/local"; bindir="/usr/local/bin"
    target="/usr/local/share/applications/${APP_ID}.desktop"
  else
    prefix="$HOME/.local"; bindir="$HOME/.local/bin"
    target="$HOME/.local/share/applications/${APP_ID}.desktop"
  fi
  local size
  rm -f -- "$target" "$bindir/dsh-ubuntu-icon" \
           "$prefix/share/icons/hicolor/scalable/apps/${ICON_NAME}.svg"
  for size in 16 24 32 48 64 128 256 512; do
    rm -f -- "$prefix/share/icons/hicolor/${size}x${size}/apps/${ICON_NAME}.png"
  done
  refresh_caches "$prefix"
  say "已卸载（日志保留在 $LOG_FILE）"
}

# -----------------------------------------------------------------------------
# check: environment report
# -----------------------------------------------------------------------------
do_check() {
  local browser cmd port
  printf '\n%s v%s — 环境自检\n' "$APP_NAME" "$VERSION"
  printf '  OS            : %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}")"
  printf '  kernel        : %s\n' "$(uname -srm)"
  printf '  session       : %s / DISPLAY=%s / WAYLAND=%s\n' \
    "${XDG_SESSION_TYPE:-unknown}" "${DISPLAY:-none}" "${WAYLAND_DISPLAY:-none}"

  if cmd="$(dsh_command)"; then printf '  dsh           : %s\n' "$cmd"
  else printf '  dsh           : !! 未找到（请设 DSH_CMD）\n'; fi

  if port="$(detect_running_port)"; then
    printf '  running GUI   : yes — http://127.0.0.1:%s/\n' "$port"
    printf '  url           : http://127.0.0.1:%s/\n' "$port"
  else
    printf '  running GUI   : no（点击图标时会自动启动）\n'
  fi

  if browser="$(find_browser)"; then printf '  app window    : %s\n' "$browser"
  elif have xdg-open; then printf '  browser       : 仅 xdg-open（会开成普通标签页）\n'
  else printf '  browser       : !! 没找到浏览器\n'; fi

  printf '  desktop-db    : %s\n' "$(have update-desktop-database && echo yes || echo no)"
  printf '  gtk-icon-cache: %s\n' "$(have gtk-update-icon-cache && echo yes || echo no)"
  printf '  installed     : %s\n' \
    "$([ -f "$HOME/.local/share/applications/${APP_ID}.desktop" ] && echo "$HOME/.local/share/applications/${APP_ID}.desktop" || echo no)"
  printf '  log           : %s\n\n' "$LOG_FILE"
}

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# -----------------------------------------------------------------------------
main() {
  local action="${1:-run}"
  [ $# -gt 0 ] && shift
  case "$action" in
    install)   do_install "$@" ;;
    uninstall) do_uninstall "$@" ;;
    run)       do_run "$@" ;;
    check)     do_check "$@" ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
