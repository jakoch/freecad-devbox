#!/bin/sh
#
# entrypoint.sh — idempotent bootstrap for the FreeCAD DevBox.
#
# Invoked twice in a normal devcontainer life cycle:
#   1. as the image ENTRYPOINT (docker run / compose up)
#   2. as devcontainer `postCreateCommand` (./.devcontainer/scripts/runtime/entrypoint.sh)
#
# It never overwrites user state, never fails the container because an optional
# piece is missing and always ends in `exec` so signals reach the real process.
#
# POSIX sh / dash-safe on purpose: no [[ ]], no arrays, no process substitution.

set -eu

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd -P)

SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
. "$SCRIPT_DIR/versions.sh"

TARGET_USER=${FREECAD_DEVBOX_USER:-vscode}
TARGET_HOME=${FREECAD_DEVBOX_HOME:-/home/$TARGET_USER}

SETTINGS_FILE_NAME=freecad_mcp_settings.json
ADDON_NAME=FreeCADMCP

# ---------------------------------------------------------------------------
# Output helpers (colour only on a TTY, never when NO_COLOR is set)
# ---------------------------------------------------------------------------
C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''; C_DIM=''

init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
		C_RESET=$(printf '\033[0m')
		C_RED=$(printf '\033[31m')
		C_YELLOW=$(printf '\033[33m')
		C_GREEN=$(printf '\033[32m')
		C_CYAN=$(printf '\033[36m')
		C_DIM=$(printf '\033[2m')
	fi
}

log()  { printf '%s[entrypoint]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[entrypoint]%s %sOK%s %s\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[entrypoint]%s %sWARN%s %s\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[entrypoint]%s %sFAIL%s %s\n' "$C_CYAN" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
	cat <<'EOF'
freecad-devbox entrypoint

Usage:
  entrypoint.sh [COMMAND [ARGS...]]

Behaviour
  * verifies the FreeCADMCP addon, self-heals it by re-running
    .devcontainer/scripts/runtime/freecad-mcp-addon.sh when it is missing
  * makes sure <FREECAD_USER_DIR>/freecad_mcp_settings.json has
    auto_start_rpc: true (and warns loudly about remote_enabled w/o token)
  * installs ~/.config/opencode/opencode.json from the template ONLY if it
    does not exist yet (existing user config is never touched)
  * verifies opencode / uvx / freecad are on PATH
  * prints the Soll-vs-Ist tool overview (show-tool-versions.sh) and the
    version drift report (compare-versions.sh)
  * execs COMMAND (no COMMAND => prints what to run next and exits 0)

Environment overrides
	FREECAD_DEVBOX_VERSIONS_JSON  path of versions.json (default $SHARE_DIR/versions.json)
  FREECAD_DEVBOX_SHARE_DIR      default /usr/local/share/freecad-devbox
  FREECAD_DEVBOX_USER           user owning the state (default vscode)
  FREECAD_DEVBOX_HOME           that user's home (default /home/vscode)
  FREECAD_USER_DIR              FreeCAD user app data dir (auto-detected if unset)
  FREECAD_MCP_TOKEN             written into opencode.json on first run only
  FREECAD_DEVBOX_SKIP_ADDON     set to 1 to never (re)install the addon
  FREECAD_DEVBOX_SELFHEAL       set to 0 to only report a missing addon
  FREECAD_DEVBOX_QUIET          set to 1 to suppress the overview
  FREECAD_DEVBOX_COLOR          auto (default) | never
  NO_COLOR                      honoured by every script of this image
EOF
}

# ---------------------------------------------------------------------------
# FreeCAD user dir / Mod dir resolution (WP-5.3, WP-5.13)
#
# Two layouts must be supported:
#   FreeCAD 1.0 -> ~/.local/share/FreeCAD/Mod/
#   FreeCAD 1.1 -> ~/.local/share/FreeCAD/v1-1/Mod/
# FREECAD_USER_DIR is honoured as a *base* directory: if only a versioned
# subdirectory carries the MCP settings, that subdirectory wins.
# ---------------------------------------------------------------------------
resolve_freecad_user_dir() {
	_base=${FREECAD_USER_DIR:-}
	if [ -z "$_base" ]; then
		for _d in "$APP_HOME/.local/share/FreeCAD" "$APP_HOME/.FreeCAD" "$TARGET_HOME/.local/share/FreeCAD"; do
			if [ -d "$_d" ]; then
				_base=$_d
				break
			fi
		done
		[ -n "$_base" ] || _base="$APP_HOME/.local/share/FreeCAD"
	fi

	# Exact match first (settings file or Mod dir already present).
	if [ -f "$_base/$SETTINGS_FILE_NAME" ] || [ -d "$_base/Mod" ]; then
		printf '%s\n' "$_base"
		return 0
	fi
	# Then a versioned subdirectory that actually carries our state.
	for _d in "$_base"/v[0-9]*-[0-9]*; do
		if [ -f "$_d/$SETTINGS_FILE_NAME" ] || [ -d "$_d/Mod" ]; then
			printf '%s\n' "$_d"
			return 0
		fi
	done
	printf '%s\n' "$_base"
}

resolve_mod_dir() {
	_updir=$(resolve_freecad_user_dir)
	if [ -d "$_updir/Mod/$ADDON_NAME" ]; then
		printf '%s\n' "$_updir/Mod/$ADDON_NAME"
	else
		printf '%s\n' "$_updir/Mod/$ADDON_NAME"
	fi
}

# chown helper: only meaningful as root, silently skipped otherwise.
own_if_root() {
	_target=$1
	if [ "$(id -u)" = "0" ] && id "$TARGET_USER" >/dev/null 2>&1; then
		chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$_target" 2>/dev/null || true
	fi
	chmod -R u+rwX,go+rX "$_target" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# WP-7.2  addon present? self-heal when missing
# ---------------------------------------------------------------------------
ensure_addon() {
	_mod=$(resolve_mod_dir)
	_updir=$(resolve_freecad_user_dir)

	if [ -f "$_mod/InitGui.py" ]; then
		ok "MCP addon found: $_mod"
		return 0
	fi

	if [ -n "${FREECAD_DEVBOX_SKIP_ADDON:-}" ]; then
		warn "MCP addon missing ($_mod/InitGui.py) and FREECAD_DEVBOX_SKIP_ADDON is set."
		return 0
	fi

	warn "MCP addon missing ($_mod/InitGui.py) - self-healing."
	mkdir -p "$_updir/Mod" || { warn "cannot create $_updir/Mod"; return 0; }

	_installer="$SCRIPT_DIR/freecad-mcp-addon.sh"
	if [ ! -f "$_installer" ]; then
		err "addon installer not found: $_installer"
		warn "The workbench 'MCP Addon' will stay missing. See docs/troubleshooting.md."
		return 0
	fi

	if command -v timeout >/dev/null 2>&1; then
		timeout 600 sh "$_installer" || warn "freecad-mcp-addon.sh failed (exit $?)"
	else
		sh "$_installer" || warn "freecad-mcp-addon.sh failed"
	fi

	if [ -f "$_mod/InitGui.py" ]; then
		ok "MCP addon self-healed: $_mod"
	else
		err "addon still missing after self-heal - the workbench will not load."
		warn "FreeCAD keeps loading Mod/<addon>/package.xml only when it declares"
		warn "<subdirectory>./</subdirectory>; check $REPO_ROOT/docs/freecad-mcp-notes.md"
	fi
	own_if_root "$_updir/Mod"
}

# ---------------------------------------------------------------------------
# WP-7.3  freecad_mcp_settings.json -> auto_start_rpc: true
# ---------------------------------------------------------------------------
ensure_settings() {
	_updir=$(resolve_freecad_user_dir)
	_settings="$_updir/$SETTINGS_FILE_NAME"

	mkdir -p "$_updir"

	if [ ! -f "$_settings" ]; then
		cat > "$_settings" <<'EOF'
{
  "remote_enabled": false,
  "allowed_ips": "127.0.0.1",
  "auto_start_rpc": true,
  "auth_token": ""
}
EOF
		ok "created $_settings (auto_start_rpc=true, remote_enabled=false)"
		own_if_root "$_settings"
		return 0
	fi

	if python3 - "$_settings" <<'PY'
import json, os, sys

path = sys.argv[1]
defaults = {
    "remote_enabled": False,
    "allowed_ips": "127.0.0.1",
    "auto_start_rpc": True,
    "auth_token": "",
}
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
except Exception as exc:                                   # corrupt or unreadable
    print("unreadable (%s), rewriting with safe defaults" % exc, file=sys.stderr)
    data = {}
    changed = True
else:
    changed = False

for key, value in defaults.items():
    if key not in data:
        data[key] = value
        changed = True
if data.get("auto_start_rpc") is not True:
    data["auto_start_rpc"] = True
    changed = True

if not changed:
    sys.exit(0)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
	then
		ok "settings verified: $_settings (auto_start_rpc=true)"
	else
		# python3 missing or failed -> last resort: sed the single key.
		if grep -q '"auto_start_rpc"[[:space:]]*:[[:space:]]*true' "$_settings"; then
			ok "settings verified: auto_start_rpc=true"
		else
			sed 's/\("auto_start_rpc"[[:space:]]*:[[:space:]]*\)false/\1true/' \
				"$_settings" > "$_settings.tmp" && mv "$_settings.tmp" "$_settings"
			ok "settings patched (sed fallback): $_settings"
		fi
		own_if_root "$_settings"
	fi

	# Security check (WP-12.8): remote without token is arbitrary code execution.
	if grep -q '"remote_enabled"[[:space:]]*:[[:space:]]*true' "$_settings"; then
		if grep -q '"auth_token"[[:space:]]*:[[:space:]]*"[^"]\+"' "$_settings"; then
			warn "remote_enabled=true WITH auth_token - port 9875 listens on 0.0.0.0."
			warn "Never publish 9875 to an untrusted network."
		else
			warn "remote_enabled=true but auth_token is EMPTY."
			warn "ANY client that reaches port 9875 can run arbitrary Python"
			warn "inside this container via execute_code. Set a token or disable remote."
		fi
	fi
}

# ---------------------------------------------------------------------------
# WP-7.4  ~/.config/opencode/opencode.json  (write once, never overwrite)
# ---------------------------------------------------------------------------
find_opencode_template() {
	for _c in \
		"${OPENCODE_TEMPLATE:-}" \
		"$SCRIPT_DIR/../opencode/opencode.json" \
		"$SCRIPT_DIR/../../opencode/opencode.json" \
		"$SHARE_DIR/opencode.json" \
		"$REPO_ROOT/.devcontainer/opencode/opencode.json"
	do
		[ -n "$_c" ] || continue
		if [ -f "$_c" ]; then
			printf '%s\n' "$_c"
			return 0
		fi
	done
	return 1
}

ensure_opencode_config() {
	_dir="$APP_HOME/.config/opencode"
	_cfg="$_dir/opencode.json"

	if [ -e "$_cfg" ]; then
		ok "opencode config already present (left untouched): $_cfg"
		if [ -n "${FREECAD_MCP_TOKEN:-}" ] && grep -q '"FREECAD_MCP_TOKEN"[[:space:]]*:[[:space:]]*""' "$_cfg"; then
			warn "FREECAD_MCP_TOKEN is set but the existing opencode.json still has an"
			warn "empty token. Edit $_cfg (or point OPENCODE_CONFIG at your own file)."
		fi
		return 0
	fi

	_template=$(find_opencode_template) || {
		err "opencode template not found (looked next to the scripts and in $SHARE_DIR)"
		warn "Copy .devcontainer/opencode/opencode.json to $_cfg by hand."
		return 0
	}

	mkdir -p "$_dir"
	chmod 700 "$_dir" 2>/dev/null || true

	if [ -n "${FREECAD_MCP_TOKEN:-}" ]; then
		case "$FREECAD_MCP_TOKEN" in
			*[!A-Za-z0-9._-]*)
				warn "FREECAD_MCP_TOKEN contains characters outside [A-Za-z0-9._-];" \
				     "not injecting it into opencode.json."
				cp "$_template" "$_cfg"
				;;
			*)
				sed 's|"FREECAD_MCP_TOKEN"[[:space:]]*:[[:space:]]*""|"FREECAD_MCP_TOKEN": "'"$FREECAD_MCP_TOKEN"'"|' \
					"$_template" > "$_cfg"
				log "injected FREECAD_MCP_TOKEN into $_cfg"
				;;
		esac
	else
		cp "$_template" "$_cfg"
	fi

	chmod 600 "$_cfg" 2>/dev/null || true
	own_if_root "$_dir"
	ok "installed opencode config: $_cfg (from $_template)"
	log "verify with: opencode mcp list"
}

# ---------------------------------------------------------------------------
# WP-7.5  PATH check for opencode / uvx
# ---------------------------------------------------------------------------
check_path_tools() {
	_missing=''
	for _tool in freecad freecadcmd opencode uv uvx Xvfb x11vnc; do
		if command -v "$_tool" >/dev/null 2>&1; then
			printf '  %-12s %s\n' "$_tool" "$(command -v "$_tool")"
		else
			printf '  %-12s %sMISSING%s\n' "$_tool" "$C_RED" "$C_RESET"
			_missing="$_missing $_tool"
		fi
	done
	if [ -n "$_missing" ]; then
		warn "not on PATH:$_missing"
		warn "uvx ships with the pinned uv install (WP-4.1). If uvx is missing the"
		warn "opencode MCP server cannot start at all - rebuild the image."
		return 0
	fi
	ok "all required binaries are on PATH"
}

# ---------------------------------------------------------------------------
# The two steps a human actually needs, in order.
#
# NOVNC_PORT must stay in sync with start-freecad-gui.sh, which forwards it as
# `--novnc=${NOVNC_PORT:-6080}`. Keep the default in both places equal.
# ---------------------------------------------------------------------------
print_next_steps() {
	_novnc_port=${NOVNC_PORT:-6080}
	printf '\n'
	log "1) start the FreeCAD desktop:"
	log "     start-freecad-gui.sh --detach"
	printf '\n'
	log "2) open it in the browser:"
	log "     http://localhost:$_novnc_port/vnc.html"
	printf '\n'
	log "   more:"
	log "     start-freecad.sh --help    # --display/--vnc/--novnc/noVNC-port options"
	log "     opencode                    # agent with the freecad MCP server"
	log "     opencode mcp list           # MCP server status"
	printf '\n'
}

# ---------------------------------------------------------------------------
# Overview + drift report (WP-7.6 / WP-7.10)
# ---------------------------------------------------------------------------
print_overview() {
	[ -z "${FREECAD_DEVBOX_QUIET:-}" ] || return 0

	if [ -x "$SCRIPT_DIR/show-tool-versions.sh" ] || [ -f "$SCRIPT_DIR/show-tool-versions.sh" ]; then
		printf '\n'
		sh "$SCRIPT_DIR/show-tool-versions.sh" --format text || warn "show-tool-versions.sh failed"
	fi
	if [ -f "$SCRIPT_DIR/compare-versions.sh" ]; then
		printf '\n'
		# Never fail the container boot because of drift; the smoke test does that.
		NO_COLOR=1 sh "$SCRIPT_DIR/compare-versions.sh" --quiet \
			|| warn "version drift detected - see docs/versions.md"
	fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	init_colors

	if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
		usage
		return 0
	fi

	if [ -f "$VERSIONS_JSON" ]; then
		_pinned_freecad_version=$(version_pin "$VERSIONS_JSON" FREECAD_VERSION)
		if [ -n "$_pinned_freecad_version" ]; then
			FREECAD_VERSION=${FREECAD_VERSION:-$_pinned_freecad_version}
			FREECAD_HOME=${FREECAD_HOME:-/opt/freecad/$FREECAD_VERSION/squashfs-root}
			FREECAD_INSTALL_DIR=${FREECAD_INSTALL_DIR:-/opt/freecad/$FREECAD_VERSION}
			export FREECAD_VERSION FREECAD_HOME FREECAD_INSTALL_DIR
		fi
	fi

	# As root we manage the state of the unprivileged dev user, not /root.
	APP_HOME=${HOME:-$TARGET_HOME}
	if [ "$(id -u)" = "0" ] && [ -d "$TARGET_HOME" ]; then
		APP_HOME=$TARGET_HOME
	fi
	export APP_HOME

	log "freecad-devbox bootstrap (user=$(id -un) home=$APP_HOME)"

	if [ -f "$VERSIONS_JSON" ]; then
		log "pinned versions: $VERSIONS_JSON"
	else
		warn "$VERSIONS_JSON not found - showing 'unavailable' instead of the pins."
		warn "Expected keys: FREECAD_VERSION FREECAD_SHA256 FREECAD_MCP_VERSION UV_VERSION OPENCODE_VERSION ..."
	fi

	log "FreeCAD user dir: $(resolve_freecad_user_dir)"

	ensure_addon
	ensure_settings
	ensure_opencode_config

	log "tool locations:"
	check_path_tools

	print_overview

	if [ "$#" -eq 0 ]; then
		log "nothing to exec - container is ready."
		print_next_steps
		return 0
	fi

	log "exec: $*"
	exec "$@"
}

main "$@"