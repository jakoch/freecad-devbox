#!/bin/sh
#
# start-freecad.sh — X11 (Xvfb) + optional WM + optional x11vnc/noVNC + FreeCAD GUI.
#
# This is the piece that makes the MCP tools work *at all*: execute_code,
# execute_code_async, get_view (screenshots) and commit() all need FreeCAD's
# GUI thread, so a headless container can only ever use execute_code_headless.
#
# POSIX sh / dash-safe. Non-interactive, idempotent (re-running re-uses a live
# X server instead of starting a second one).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

# ---------------------------------------------------------------------------
# Defaults (override via environment or flags)
# ---------------------------------------------------------------------------
DISPLAY_NUM=${DISPLAY_NUM:-:99}
SCREEN=${SCREEN:-1920x1080x24}
VNC_PORT=${VNC_PORT:-5900}
NOVNC_PORT=${NOVNC_PORT:-6080}
START_WM=${START_WM:-1}
START_VNC=${START_VNC:-1}
START_NOVNC=${START_NOVNC:-0}
WM_BIN=${WM_BIN:-fluxbox}
DETACH=0
ENV_ONLY=0

SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
. "$SCRIPT_DIR/versions.sh"

C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''

init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
		C_RESET=$(printf '\033[0m')
		C_RED=$(printf '\033[31m')
		C_YELLOW=$(printf '\033[33m')
		C_GREEN=$(printf '\033[32m')
		C_CYAN=$(printf '\033[36m')
	fi
}
log()  { printf '%s[start-freecad]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[start-freecad]%s %sOK%s %s\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[start-freecad]%s %sWARN%s %s\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[start-freecad]%s %sFAIL%s %s\n' "$C_CYAN" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Poll a TCP port on localhost. $1=port $2=pid (optional) $3=timeout in seconds.
# Succeeds only if something is actually LISTENing - background helpers that
# die instantly would otherwise be reported as started.
port_open() {
	python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(1)
sys.exit(0 if s.connect_ex(('127.0.0.1', int(sys.argv[1]))) == 0 else 1)
" "$1" 2>/dev/null
}

wait_for_port() {
	_p=$1; _pid=${2:-}; _secs=${3:-10}
	_i=0
	_maxtries=$((_secs * 10))
	while [ "$_i" -lt "$_maxtries" ]; do
		if port_open "$_p"; then
			return 0
		fi
		if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
			return 1
		fi
		_i=$((_i + 1))
		sleep 0.1
	done
	return 1
}

usage() {
	cat <<'EOF'
start-freecad.sh — Xvfb (+ WM) (+ x11vnc / noVNC) + FreeCAD GUI

Usage:
  start-freecad.sh [options] [-- COMMAND [ARGS...]]

Options
  --display N        X display, default :99            (DISPLAY_NUM)
  --screen SPEC      Xvfb screen spec, default 1920x1080x24   (SCREEN)
  --no-vm            do not start fluxbox
  --wm BINARY        window manager to start (default fluxbox)
  --vnc[=PORT]       start x11vnc on PORT (default 5900)
  --no-vnc           do not start x11vnc
  --novnc[=PORT]     also expose noVNC via websockify (default 6080)
  --no-novnc         do not start websockify (default behaviour)
  --detach           return immediately, leave FreeCAD running in background
  --wait             stay in the foreground until FreeCAD exits (default)
  --env-only         set up X/GUI environment, run COMMAND, do not start FreeCAD
  -h, --help         this text

Examples
  start-freecad.sh                              # Xvfb + fluxbox + x11vnc + FreeCAD
  start-freecad.sh --novnc                      # + browser VNC on http://localhost:6080
  start-freecad.sh --detach --novnc             # start and get your shell back
  start-freecad.sh --env-only -- freecadcmd -c 'print(App.Version())'

VNC access from the host (WP-6.4, alternative to noVNC)
  x11vnc is started with -nopw, i.e. WITHOUT a password. Do not expose 5900.
  Publish it only on localhost:  -p 127.0.0.1:5900:5900
  Password instead of -nopw:    set VNC_PASSWORD_FILE=/path/to/passwd-file
  Screen sharing from an X11 host instead of VNC:
      docker exec -it <container> xhost +local:   # allow the host's X server
      # then DISPLAY=<container's :99> freecad ... does not work across hosts;
      # use VNC/noVNC, or X11-forward with x11vnc's built-in XDMCP support.
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
	case "$1" in
		--display)     DISPLAY_NUM=${2:?--display needs a value}; shift 2 ;;
		--screen)      SCREEN=${2:?--screen needs a value};      shift 2 ;;
		--no-vm)       START_WM=0;                               shift ;;
		--wm)          WM_BIN=${2:?--wm needs a value}; START_WM=1; shift 2 ;;
		--vnc)        START_VNC=1;                             shift ;;
		--vnc=*)      START_VNC=1; VNC_PORT=${1#--vnc=};      shift ;;
		--no-vnc)      START_VNC=0;                             shift ;;
		--novnc)       START_NOVNC=1;                          shift ;;
		--novnc=*)     START_NOVNC=1; NOVNC_PORT=${1#--novnc=}; shift ;;
		--no-novnc)    START_NOVNC=0;                          shift ;;
		--detach)      DETACH=1;                                shift ;;
		--wait)        DETACH=0;                                                  shift ;;
		--env-only)    ENV_ONLY=1;                              shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		*)             die "unknown option '$1' (try --help)" ;;
	esac
done

init_colors

# ---------------------------------------------------------------------------
# WP-6.8  environment hygiene before anything GUI-ish starts
#
# The AppImage bundles its own Qt + Python 3.11. Anything that leaks the host's
# or the distro's Python into that process breaks the addon import, so the two
# most dangerous variables are cleared rather than "fixed".
# ---------------------------------------------------------------------------
unset PYTHONHOME || true
unset PYTHONSTARTUP || true

if [ -n "${PYTHONPATH:-}" ]; then
	warn "PYTHONPATH is set ($PYTHONPATH) and could shadow FreeCAD's bundled Python."
	warn "It is passed through unchanged because a host project may need it;"
	warn "unset it if FreeCAD crashes with an ImportError for FreeCADGui."
fi

# APPIMAGE_EXTRACT_AND_RUN=0: the image was extracted with --appimage-extract, so
# FreeCAD runs from /opt/freecad/<version>/AppRun directly. Without this the
# runtime would try to re-mount itself via FUSE, which is unavailable in
# unprivileged / rootless devcontainers (WP-2.7).
APPIMAGE_EXTRACT_AND_RUN=0
export APPIMAGE_EXTRACT_AND_RUN

# Software rendering: llvmpipe. No GPU in the container by default.
LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-1}
GALLIUM_DRIVER=${GALLIUM_DRIVER:-llvmpipe}
# X11 MIT-SHM crashes some Qt versions under Xvfb -> disable it.
QT_X11_NO_MITSHM=${QT_X11_NO_MITSHM:-1}
QT_SCALE_FACTOR=${QT_SCALE_FACTOR:-1}
export LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER QT_X11_NO_MITSHM QT_SCALE_FACTOR

# Qt platform plugins: the extracted AppImage ships its own. Point Qt at them so
# the distro's Qt (from apt) cannot win and fail to find the xcb platform plugin.
find_qt_plugin_path() {
	# The last entry is a deliberate glob (usr/lib/<triple>/qt6/plugins/platforms)
	# and must stay unquoted; the first three are literal paths and are quoted.
	for _d in \
		"${FREECAD_HOME:-/nonexistent}/usr/plugins/platforms" \
		"${FREECAD_HOME:-/nonexistent}/usr/lib/qt6/plugins/platforms" \
		"${FREECAD_HOME:-/nonexistent}/usr/lib/qt5/plugins/platforms" \
		${FREECAD_HOME:-/nonexistent}/usr/lib/*/qt6/plugins/platforms
	do
		if [ -d "$_d" ]; then
			printf '%s\n' "$_d"
			return 0
		fi
	done
	return 1
}

if [ -n "${FREECAD_HOME:-}" ] && _qt=$(find_qt_plugin_path); then
	export QT_QPA_PLATFORM_PLUGIN_PATH="${QT_QPA_PLATFORM_PLUGIN_PATH:-$_qt}"
	export QT_PLUGIN_PATH="${QT_PLUGIN_PATH:-$_qt}"
	log "Qt platform plugins: $QT_QPA_PLATFORM_PLUGIN_PATH"
fi

# ---------------------------------------------------------------------------
# FreeCAD user dir: the addon + settings must be in the dir FreeCAD actually
# reads. Reuse the entrypoint's resolution rules (WP-5.3 / WP-5.13).
# ---------------------------------------------------------------------------
SETTINGS_FILE_NAME=freecad_mcp_settings.json

resolve_freecad_user_dir() {
	_base=${FREECAD_USER_DIR:-}
	if [ -z "$_base" ]; then
		for _d in "${HOME:-/root}/.local/share/FreeCAD" "${HOME:-/root}/.FreeCAD"; do
			if [ -d "$_d" ]; then _base=$_d; break; fi
		done
		[ -n "$_base" ] || _base="${HOME:-/root}/.local/share/FreeCAD"
	fi
	if [ -f "$_base/$SETTINGS_FILE_NAME" ] || [ -d "$_base/Mod" ]; then
		printf '%s\n' "$_base"; return 0
	fi
	for _d in "$_base"/v[0-9]*-[0-9]*; do
		if [ -f "$_d/$SETTINGS_FILE_NAME" ] || [ -d "$_d/Mod" ]; then
			printf '%s\n' "$_d"; return 0
		fi
	done
	printf '%s\n' "$_base"
}

FREECAD_USER_DIR=$(resolve_freecad_user_dir)
export FREECAD_USER_DIR
log "FREECAD_USER_DIR=$FREECAD_USER_DIR"

if [ -f "$FREECAD_USER_DIR/$SETTINGS_FILE_NAME" ]; then
	if grep -q '"auto_start_rpc"[[:space:]]*:[[:space:]]*true' "$FREECAD_USER_DIR/$SETTINGS_FILE_NAME"; then
		ok "auto_start_rpc=true - the XML-RPC server will come up on its own"
	else
		warn "auto_start_rpc is NOT true in $FREECAD_USER_DIR/$SETTINGS_FILE_NAME."
		warn "Start it manually: menu 'FreeCAD MCP' -> 'Start RPC Server'."
	fi
else
	warn "no $SETTINGS_FILE_NAME in $FREECAD_USER_DIR - run .devcontainer/scripts/runtime/entrypoint.sh"
fi

# ---------------------------------------------------------------------------
# X server
# ---------------------------------------------------------------------------
DISPLAY=$DISPLAY_NUM
export DISPLAY

xvfb_alive() {
	# /tmp/.X11-unix/X<n> alone is NOT enough: the socket survives when Xvfb is
	# killed (SIGKILL, container restart of a previous run) and only the process
	# is gone. A stale socket makes start-freecad.sh skip Xvfb, and FreeCAD then
	# dies with a misleading "libxcb-cursor0 is needed" /
	# "no Qt platform plugin could be initialized" instead of a connect error.
	# So: require the socket AND a real X connection through it.
	_num=${DISPLAY#:}
	_num=${_num%%.*}
	[ -S "/tmp/.X11-unix/X$_num" ] || return 1
	if command -v xdpyinfo >/dev/null 2>&1; then
		xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || return 1
	fi
	return 0
}

# Drop a socket no X server is listening on, otherwise Xvfb refuses to bind it.
remove_stale_x_socket() {
	_num=${DISPLAY#:}
	_num=${_num%%.*}
	[ -S "/tmp/.X11-unix/X$_num" ] || return 0
	warn "stale X socket /tmp/.X11-unix/X$_num with no live server - removing it"
	rm -f "/tmp/.X11-unix/X$_num" || true
}

start_xvfb() {
	if xvfb_alive; then
		ok "X server already running on $DISPLAY"
		return 0
	fi
	command -v Xvfb >/dev/null 2>&1 || die "Xvfb is not installed (missing X11 stack in the image)"
	remove_stale_x_socket
	# -nolisten tcp: do not expose an X TCP port inside the container.
	log "starting Xvfb $DISPLAY ($SCREEN, software rendering)"
	Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp -dpi 96 \
		>/tmp/xvfb.log 2>&1 &
	XVFB_PID=$!
	_i=0
	while [ "$_i" -lt 100 ]; do
		if xvfb_alive; then
			ok "Xvfb ready on $DISPLAY (pid $XVFB_PID)"
			return 0
		fi
		if ! kill -0 "$XVFB_PID" 2>/dev/null; then
			err "Xvfb died; last lines of /tmp/xvfb.log:"
			tail -n 20 /tmp/xvfb.log >&2 || true
			return 1
		fi
		_i=$((_i + 1))
		sleep 0.1
	done
	err "Xvfb did not create $DISPLAY within 10s (see /tmp/xvfb.log)"
	return 1
}

start_xvfb || die "cannot continue without an X server"

# Window manager: without one there is no title bar, no window list and no way
# to raise a window. Qt dialogs can end up off-screen.
if [ "$START_WM" = "1" ] && command -v "$WM_BIN" >/dev/null 2>&1; then
	log "starting window manager: $WM_BIN"
	"$WM_BIN" >/tmp/wm.log 2>&1 &
	WM_PID=$!
	ok "window manager $WM_BIN (pid $WM_PID)"
elif [ "$START_WM" = "1" ]; then
	warn "$WM_BIN not installed - windows will have no decorations and no focus handling"
fi

# ---------------------------------------------------------------------------
# WP-6.2  x11vnc  /  WP-6.3  noVNC
# ---------------------------------------------------------------------------
if [ "$START_VNC" = "1" ]; then
	if command -v x11vnc >/dev/null 2>&1; then
		VNC_ARGS="-display $DISPLAY -rfbport $VNC_PORT -forever -shared -noxdamage -wait 20 -quiet"
		if [ -n "${VNC_PASSWORD_FILE:-}" ]; then
			VNC_ARGS="$VNC_ARGS -rfbauth $VNC_PASSWORD_FILE"
			log "x11vnc with password file $VNC_PASSWORD_FILE"
		else
			VNC_ARGS="$VNC_ARGS -nopw"
			warn "x11vnc runs WITHOUT a password (-nopw). Keep port $VNC_PORT unpublished"
			warn "or bound to 127.0.0.1 (docker compose does that) and never on a shared network."
		fi
		# x11vnc >= 0.9.16 aborts as soon as WAYLAND_DISPLAY is set:
		#   "Wayland display server detected. Wayland sessions are as of now only
		#    supported via -rawfb and the bundled deskshot utility. Exiting."
		# VS Code injects WAYLAND_DISPLAY=vscode-wayland-<uuid>.sock into every
		# devcontainer, which silently kills x11vnc (its output goes to a log
		# nobody reads) and leaves noVNC serving a dead backend. x11vnc has no flag
		# to override the probe, so drop the variable for this child only.
		if [ -n "${WAYLAND_DISPLAY:-}" ]; then
			log "WAYLAND_DISPLAY is set ($WAYLAND_DISPLAY) - unsetting it for x11vnc"
		fi
		# shellcheck disable=SC2086
		env -u WAYLAND_DISPLAY x11vnc $VNC_ARGS >/tmp/x11vnc.log 2>&1 &
		X11VNC_PID=$!
		if wait_for_port "$VNC_PORT" "$X11VNC_PID" 15; then
			ok "x11vnc on 127.0.0.1:$VNC_PORT (pid $X11VNC_PID)"
		else
			warn "x11vnc did not come up on port $VNC_PORT; last lines of /tmp/x11vnc.log:"
			tail -n 15 /tmp/x11vnc.log >&2 || true
			warn "noVNC/websockify will have no backend to talk to."
		fi
	else
		warn "x11vnc not installed - no VNC access"
	fi
fi

if [ "$START_NOVNC" = "1" ]; then
	if command -v websockify >/dev/null 2>&1; then
		WEB_DIR=${NOVNC_WEB_DIR:-/usr/share/novnc}
		if [ -d "$WEB_DIR" ]; then
			websockify --web "$WEB_DIR" "$NOVNC_PORT" "localhost:$VNC_PORT" >/tmp/websockify.log 2>&1 &
			NOVNC_PID=$!
			if wait_for_port "$NOVNC_PORT" "$NOVNC_PID" 15; then
				ok "noVNC on http://localhost:$NOVNC_PORT/vnc.html (pid $NOVNC_PID)"
			else
				warn "noVNC/websockify did not come up on port $NOVNC_PORT; last lines of /tmp/websockify.log:"
				tail -n 15 /tmp/websockify.log >&2 || true
			fi
		else
			warn "noVNC web assets not found (apt install novnc) - websockify not started"
		fi
	else
		warn "websockify not installed - start with: apt-get install -y websockify novnc"
	fi
fi

# ---------------------------------------------------------------------------
# FreeCAD
# ---------------------------------------------------------------------------
FREECAD_BIN=${FREECAD_BIN:-freecad}
command -v "$FREECAD_BIN" >/dev/null 2>&1 || die "$FREECAD_BIN not on PATH - is /opt/freecad/<version> populated?"

if [ "$ENV_ONLY" = "1" ]; then
	if [ "$#" -eq 0 ]; then
		die "--env-only needs a command: start-freecad.sh --env-only -- freecadcmd --version"
	fi
	log "env-only mode, running: $*"
	exec "$@"
fi

log "FreeCAD binary: $(command -v "$FREECAD_BIN")"
if [ -f "$VERSIONS_JSON" ]; then
	log "pinned FreeCAD: $(version_pin "$VERSIONS_JSON" FREECAD_VERSION)"
fi

log "starting FreeCAD (first start of an AppImage populates its user dir)"
"$FREECAD_BIN" "$@" >/tmp/freecad.log 2>&1 &
FREECAD_PID=$!
printf '%s\n' "$FREECAD_PID" > /tmp/freecad.pid
ok "FreeCAD pid $FREECAD_PID (log: /tmp/freecad.log)"

if [ "$DETACH" = "1" ]; then
	log "detached - use 'tail -f /tmp/freecad.log' and freecad-mcp-healthcheck.sh"
	exit 0
fi

log "waiting for the XML-RPC server on 127.0.0.1:9875 (up to 120s) ..."
if [ -f "$SCRIPT_DIR/freecad-mcp-healthcheck.sh" ]; then
	if sh "$SCRIPT_DIR/freecad-mcp-healthcheck.sh" --wait 120 --quiet; then
		ok "MCP RPC server is reachable - 'opencode mcp list' should now work"
	else
		warn "RPC server not reachable yet. Check /tmp/freecad.log and the Report View"
		warn "inside FreeCAD for '[MCP]' messages."
	fi
fi

# Trap so Ctrl-C / SIGTERM tear the X stack down instead of leaking processes.
cleanup() {
	log "shutting down (FreeCAD pid $FREECAD_PID)"
	for _p in "$FREECAD_PID" "${X11VNC_PID:-}" "${NOVNC_PID:-}" "${WM_PID:-}" "${XVFB_PID:-}"; do
		[ -n "$_p" ] || continue
		kill "$_p" 2>/dev/null || true
	done
}
trap cleanup INT TERM

rc=0
wait "$FREECAD_PID" || rc=$?
trap - INT TERM
cleanup
log "FreeCAD exited with $rc"
exit "$rc"