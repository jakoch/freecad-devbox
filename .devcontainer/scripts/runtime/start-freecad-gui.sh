#!/bin/sh
#
# start-freecad-gui.sh — default container command (WP-6.5).
#
# Thin wrapper around start-freecad.sh with the defaults a human wants when the
# container is started with `docker run` / `docker compose up`:
#   Xvfb :99 + fluxbox + FreeCAD GUI + x11vnc + noVNC on 6080.
#
# POSIX sh / dash-safe.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

usage() {
	cat <<'EOF'
start-freecad-gui.sh — default container command

Starts, in this order:
  1. Xvfb            :99, 1920x1080x24, software rendering (llvmpipe)
  2. fluxbox         window manager (without one, dialogs end up off-screen)
  3. FreeCAD GUI     -> the MCP addon auto-starts XML-RPC on 127.0.0.1:9875
  4. x11vnc          127.0.0.1:5900, -nopw unless VNC_PASSWORD_FILE is set
  5. noVNC/websockify http://localhost:6080/vnc.html

All options are forwarded to start-freecad.sh, e.g.
  start-freecad-gui.sh --no-novnc
  start-freecad-gui.sh --display :77 --screen 1600x1200x24

Environment
  VNC_PASSWORD_FILE   x11vnc -rfbauth file (replaces -nopw)
  NOVNC_PORT          default 6080
  VNC_PORT            default 5900
  FREECAD_USER_DIR    override the auto-detected FreeCAD user dir
EOF
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
esac

# noVNC is on by default here: a container that only exposes an X display that
# nobody can see is not usable. docker compose only publishes 6080.
# NOTE: --novnc takes its port glued on ("--novnc=6080"). "--novnc 6080" makes
# start-freecad.sh parse "6080" as a positional COMMAND and abort.
exec sh "$SCRIPT_DIR/start-freecad.sh" "--novnc=${NOVNC_PORT:-6080}" "$@"