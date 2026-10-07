#!/bin/sh
#
# show-tool-locations.sh (WP-7.7)
#
# Where does each tool actually come from? Prints path, resolved target and a
# note per tool, so a stale /usr/local/bin symlink or a shadowing binary in
# ~/.opencode/bin cannot go unnoticed.
#
# Degrades gracefully: a tool that is not installed is reported as MISSING, it
# does not abort the report.
#
# POSIX sh / dash-safe.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
. "$SCRIPT_DIR/versions.sh"
SETTINGS_FILE_NAME=freecad_mcp_settings.json
ADDON_NAME=FreeCADMCP

FORMAT=text
ONLY_MISSING=0
C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''; C_DIM=''; C_BOLD=''

usage() {
	cat <<'EOF'
show-tool-locations.sh — which binary/file is actually used

Usage:
  show-tool-locations.sh [--format text|markdown|json] [--missing]

Options
      --format F   text (default) | markdown | json
      --missing    list only missing tools (exit 1 if anything is missing)
  -h, --help       this text

Exit: 0 all present, 1 something missing (only with --missing), 2 usage error
EOF
}

init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
		C_RESET=$(printf '\033[0m'); C_RED=$(printf '\033[31m')
		C_YELLOW=$(printf '\033[33m'); C_GREEN=$(printf '\033[32m')
		C_CYAN=$(printf '\033[36m'); C_BOLD=$(printf '\033[1m')
	fi
}
log() { printf '%s[locations]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--format)     FORMAT=${2:?--format needs a value}; shift 2 ;;
		--format=*)   FORMAT=${1#--format=};              shift ;;
		--missing)    ONLY_MISSING=1;                     shift ;;
		-h|--help)    usage; exit 0 ;;
		*)            printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
done
init_colors

pin() {
	version_pin "$VERSIONS_JSON" "$1"
}

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

resolve_freecad_home() {
	if [ -n "${FREECAD_HOME:-}" ] && [ -d "$FREECAD_HOME" ]; then
		printf '%s\n' "$FREECAD_HOME"; return 0
	fi
	for _d in /opt/freecad/*; do
		if [ -d "$_d" ]; then printf '%s\n' "$_d"; return 0; fi
	done
	return 1
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
}

ROWS=''
MISSING=0

# emit_row <kind> <name> <path> <detail>
emit_row() {
	_kind=$1; _name=$2; _path=$3; _detail=$4
	if [ -z "$_path" ]; then
		_status=missing; MISSING=$(( MISSING + 1 ))
	elif [ -e "$_path" ]; then
		_status=present
	else
		_status=broken; MISSING=$(( MISSING + 1 ))
	fi
	[ "$ONLY_MISSING" = "1" ] && [ "$_status" = present ] && return 0
	ROWS="${ROWS}${_kind}|${_name}|${_path}|${_status}|${_detail}
"
}

which_of() { command -v "$1" 2>/dev/null || printf ''; }

real_of() {
	[ -n "$1" ] || return 0
	if command -v readlink >/dev/null 2>&1 && readlink -f "$1" >/dev/null 2>&1; then
		readlink -f "$1"
	else
		printf '%s' "$1"
	fi
}

# --- binaries --------------------------------------------------------------
for t in freecad freecadcmd opencode uv uvx Xvfb x11vnc fluxbox websockify python3 jq; do
	p=$(which_of "$t")
	if [ -n "$p" ]; then
		emit_row binary "$t" "$p" "$(real_of "$p")"
	else
		emit_row binary "$t" '' "not on PATH"
	fi
done

# --- opencode shadowing hazard (a real footgun, see docs/versions.md) -------
if [ -x "$HOME/.opencode/bin/opencode" ]; then
	_shadow=$("$HOME/.opencode/bin/opencode" --version 2>/dev/null | head -n 1 || true)
	_pinned=$(pin OPENCODE_VERSION)
	case "$_shadow" in
		*"$_pinned"*)
			_note="same version as the pin, harmless"
			;;
		*"v"*)
			_note="SHADOWS the pinned opencode ($_pinned) if ~/.opencode/bin precedes /usr/local/bin in PATH"
			;;
		*) _note="differs from the pin ($_pinned)" ;;
	esac
	emit_row shadow "$HOME/.opencode/bin/opencode" "$HOME/.opencode/bin/opencode" "$_shadow - $_note"
fi

# --- FreeCAD install -------------------------------------------------------
fh=$(resolve_freecad_home 2>/dev/null || printf '')
if [ -n "$fh" ]; then
	emit_row dir "FreeCAD install" "$fh" "FREECAD_VERSION=$(pin FREECAD_VERSION)"
	[ -x "$fh/AppRun" ] && emit_row file "AppRun" "$fh/AppRun" 'extracted AppImage entry point'
	[ -d "$fh/usr/lib" ] && emit_row dir "AppImage usr/lib" "$fh/usr/lib" "bundled Qt + Python 3.11"
else
	emit_row dir "FreeCAD install" '' "no /opt/freecad/* (FREECAD_INSTALL=$(pin FREECAD_INSTALL))"
fi

# --- addon + settings ------------------------------------------------------
updir=$(resolve_freecad_user_dir)
emit_row dir "FREECAD_USER_DIR" "$updir" "Mod subdir expected at $updir/Mod"
emit_row file "MCP addon" "$updir/Mod/$ADDON_NAME" "package.xml + InitGui.py"
emit_row file "MCP addon InitGui.py" "$updir/Mod/$ADDON_NAME/InitGui.py" "workbench class"
emit_row file "MCP settings" "$updir/$SETTINGS_FILE_NAME" "auto_start_rpc must be true"

# --- config + pins ---------------------------------------------------------
emit_row file "built pins (versions.json)" "$VERSIONS_JSON" "single source of truth"
emit_row file "opencode config" "$HOME/.config/opencode/opencode.json" 'global opencode config'
emit_row file "opencode template" "$SCRIPT_DIR/../opencode/opencode.json" "installed on first start only"
emit_row dir "uv cache" "${UV_CACHE_DIR:-<UV_CACHE_DIR unset>}" "set by the image"

# --- rendering -------------------------------------------------------------
case "$FORMAT" in
	text)
		printf 'Tool locations\n'
		printf '%-30s %-8s %-46s %s\n' 'NAME' 'STATUS' 'PATH' 'DETAIL'
		printf '%s' "$ROWS" | while IFS='|' read -r k n p s d; do
			[ -n "$k" ] || continue
			case "$s" in
				present) c=$C_GREEN ;; missing|cbroken) c=$C_RED ;; *) c=$C_DIM ;;
			esac
			printf '%-30s %s%-8s%s %-46s %s\n' "$n" "$c" "$s" "$C_RESET" "${p:--}" "$d"
		done
		;;
	markdown)
		printf '## Tool locations\n\n| Name | Status | Path | Detail |\n|---|---|---|---|\n'
		printf '%s' "$ROWS" | while IFS='|' read -r k n p s d; do
			[ -n "$k" ] || continue
			printf '| %s | %s | `%s` | %s |\n' "$n" "$s" "${p:--}" "$d"
		done
		;;
	json)
		printf '{\n  "entries": [\n'
		first=1
		printf '%s' "$ROWS" | while IFS='|' read -r k n p s d; do
			[ -n "$k" ] || continue
			[ "$first" = 1 ] || printf ',\n'
			first=0
			printf '    {"kind": "%s", "name": "%s", "path": "%s", "status": "%s", "detail": "%s"}' \
				"$k" "$(json_escape "$n")" "$(json_escape "$p")" "$s" "$(json_escape "$d")"
		done
		printf '\n  ]\n}\n'
		;;
	*) printf 'unknown format: %s\n' "$FORMAT" >&2; exit 2 ;;
esac

if [ "$ONLY_MISSING" = "1" ] && [ "$MISSING" -gt 0 ]; then
	printf '\n' >&2
	log "$MISSING entry/entries missing — see docs/troubleshooting.md"
	exit 1
fi
exit 0