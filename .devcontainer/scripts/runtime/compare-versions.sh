#!/bin/sh
#
# compare-versions.sh (WP-7.10 / WP-7.11)
#
# Drift detection across all four axes:
#   1. FreeCAD install   vs FREECAD_VERSION pin
#   2. freecad-mcp addon vs FREECAD_MCP_VERSION pin (Addon <-> PyPI coupling)
#   3. opencode          vs OPENCODE_VERSION pin
#   4. uv                vs UV_VERSION pin
#
# Every deviation produces a warning that names the remedy
# (.devcontainer/scripts/build/update-versions.sh) — WP-7.11.
#
# Exit: 0 no drift, 1 drift, 2 pins/tooling unavailable (nothing to compare),
#       2 on usage error as well.
#
# POSIX sh / dash-safe.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
. "$SCRIPT_DIR/versions.sh"
SETTINGS_FILE_NAME=freecad_mcp_settings.json
ADDON_NAME=FreeCADMCP
UPDATE_SCRIPT=".devcontainer/scripts/build/update-versions.sh"

QUIET=0
JSON=0
STRICT=0
STRICT_UNAVAILABLE=0

C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''; C_BOLD=''

usage() {
	cat <<'EOF'
compare-versions.sh — detect version drift between pins and what is installed

Usage:
  compare-versions.sh [options]

Options
      --json                 machine-readable report on stdout
      --quiet                only print warnings (no OK lines)
      --strict               unavailable information counts as a failure
	--versions-json F      pin file (default /usr/local/share/freecad-devbox/versions.json)
      --self-test            run the pure-logic self tests (offline, no FreeCAD)
  -h, --help                 this text

Checked axes
  FreeCAD install        vs FREECAD_VERSION
  freecad-mcp addon      vs FREECAD_MCP_VERSION   (Addon and PyPI must match)
  opencode               vs OPENCODE_VERSION
  uv                     vs UV_VERSION

Exit: 0 no drift | 1 drift | 2 pins or tooling unavailable
EOF
}

init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
		C_RESET=$(printf '\033[0m'); C_RED=$(printf '\033[31m')
		C_YELLOW=$(printf '\033[33m'); C_GREEN=$(printf '\033[32m')
		C_CYAN=$(printf '\033[36m'); C_BOLD=$(printf '\033[1m')
	fi
}
log()  { printf '%s[compare]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { [ "$QUIET" = "1" ] || printf '%s[compare]%s %sOK%s   %s\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[compare]%s %sWARN%s %s\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[compare]%s %sDRIFT%s %s\n' "$C_CYAN" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }

# ---------------------------------------------------------------------------
# pure logic
# ---------------------------------------------------------------------------
norm_ver() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
		sed -e 's/^[[:space:]]*v//' -e 's/[[:space:]]*$//' |
		sed -e 's/\.0$//' -e 's/\.0$//' -e 's/\.0$//'
}

first_token() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1; }

pin() {
	version_pin "$VERSIONS_JSON" "$1"
}

# verdict: 0 equal, 1 different, 2 unavailable
verdict() {
	_e=$1; _a=$2
	if [ -z "$_a" ]; then printf '2'; return 0; fi
	if [ -z "$_e" ]; then printf '0'; return 0; fi
	if [ "$(norm_ver "$_e")" = "$(norm_ver "$_a")" ]; then printf '0'; else printf '1'; fi
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }

# ---------------------------------------------------------------------------
# probes
# ---------------------------------------------------------------------------
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

actual_freecad() {
	_out=''
	if [ -n "${FREECAD_INSTALL_DIR:-}" ] && [ -d "$FREECAD_INSTALL_DIR" ]; then
		_out=$(basename -- "$FREECAD_INSTALL_DIR")
	elif [ -n "${FREECAD_HOME:-}" ] && [ -d "$FREECAD_HOME" ]; then
		_out=$(freecad_version_from_home "$FREECAD_HOME")
	else
		for _d in /opt/freecad/*; do
			if [ -d "$_d" ]; then _out=$(basename -- "$_d"); break; fi
		done
	fi
	if command -v freecadcmd >/dev/null 2>&1; then
		_v=$(first_token "$(freecadcmd --version 2>/dev/null || true)")
		if [ -n "$_v" ] && [ -n "$_out" ] && [ "$(norm_ver "$_v")" != "$(norm_ver "$_out")" ]; then
			printf '%s (freecadcmd: %s)' "$_out" "$_v"
			return 0
		fi
		[ -n "$_out" ] || _out=$_v
	fi
	printf '%s' "$_out"
}

actual_addon() {
	_mod="$(resolve_freecad_user_dir)/Mod/$ADDON_NAME"
	[ -d "$_mod" ] || return 0
	if [ -f "$_mod/package.xml" ]; then
		_v=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "$_mod/package.xml" | head -n 1)
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	fi
	if [ -f "$_mod/rpc_server/version.py" ]; then
		sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
			"$_mod/rpc_server/version.py" | head -n 1
	fi
}

actual_pypi_mcp() {
	if command -v python3 >/dev/null 2>&1; then
		_v=$(python3 - <<'PY' 2>/dev/null || true
try:
    from importlib.metadata import version
except ImportError:
    raise SystemExit(0)
try:
    print(version("freecad-mcp"))
except Exception:
    pass
PY
)
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	fi
	for _d in /opt/uv/tools/*/lib/python*/site-packages/freecad_mcp-*.dist-info \
	           /opt/uv/venvs/*/lib/python*/site-packages/freecad_mcp-*.dist-info; do
		[ -d "$_d" ] || continue
		basename -- "$_d" | sed -n 's/^freecad_mcp-\(.*\)\.dist-info$/\1/p'
		return 0
	done
	return 0
}

actual_cmd() {
	command -v "$1" >/dev/null 2>&1 || return 0
	first_token "$("$1" "$2" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
DRIFT=0
UNAVAILABLE=0
JSON_ROWS=''

record() { # record <axis> <expected> <actual> <verdict> <remedy>
	_a=$1; _e=$2; _g=$3; _v=$4; _r=$5
	case "$_v" in
		0) ok "$_a: expected $_e, found ${_g:-<nothing>}" ;;
		1)
			err "$_a: DRIFT — expected '$_e', found '${_g:-<nothing>}'"
			warn "  remedy: review and renew the pins with  $UPDATE_SCRIPT --dry-run"
			warn "  then commit the reviewed diff. Never let the image float silently."
			DRIFT=$(( DRIFT + 1 ))
			;;
		2)
			warn "$_a: cannot verify (pin '$_e', actual '${_g:-<unavailable>}')"
			UNAVAILABLE=$(( UNAVAILABLE + 1 ))
			;;
	esac
	JSON_ROWS="${JSON_ROWS}${_a}|${_e}|${_g:-}|$(case "$_v" in 0) printf ok ;; 1) printf drift ;; *) printf unavailable ;; esac)
"
}

run_compare() {
	e_freecad=$(pin FREECAD_VERSION)
	e_mcp=$(pin FREECAD_MCP_VERSION)
	e_oc=$(pin OPENCODE_VERSION)
	e_uv=$(pin UV_VERSION)

	if [ ! -f "$VERSIONS_JSON" ]; then
		warn "$VERSIONS_JSON not found — expected versions unavailable, nothing to compare."
		warn "In the image this file is created at build time; on a host checkout pass"
		warn "  --versions-json .devcontainer/versions.json"
		UNAVAILABLE=$(( UNAVAILABLE + 1 ))
	else
		[ "$QUIET" = "1" ] || log "pins: $VERSIONS_JSON ($(pin FREECAD_RESOLVE_MODE || printf 'mode n/a'))"
	fi

	[ "$JSON" = "1" ] || [ "$QUIET" = "1" ] || printf '\n'

	a_freecad=$(actual_freecad)
	record "FreeCAD install"    "$e_freecad" "$a_freecad" \
		"$(verdict "$e_freecad" "$a_freecad")" "$UPDATE_SCRIPT"

	a_addon=$(actual_addon)
	record "freecad-mcp addon"  "$e_mcp" "$a_addon" \
		"$(verdict "$e_mcp" "$a_addon")" "$UPDATE_SCRIPT"

	a_pypi=$(actual_pypi_mcp)
	record "freecad-mcp (PyPI)" "$e_mcp" "$a_pypi" \
		"$(verdict "$e_mcp" "$a_pypi")" "$UPDATE_SCRIPT"

	a_oc=$(actual_cmd opencode --version)
	record "opencode"           "$e_oc" "$a_oc" \
		"$(verdict "$e_oc" "$a_oc")" "$UPDATE_SCRIPT"

	a_uv=$(actual_cmd uv --version)
	record "uv"                 "$e_uv" "$a_uv" \
		"$(verdict "$e_uv" "$a_uv")" "$UPDATE_SCRIPT"

	# The Addon <-> PyPI coupling is the one that silently breaks the MCP call
	# contract, so it gets its own explicit statement.
	if [ -n "$a_addon" ] && [ -n "$a_pypi" ] && [ "$(norm_ver "$a_addon")" != "$(norm_ver "$a_pypi")" ]; then
		err "freecad-mcp Addon ($a_addon) and PyPI package ($a_pypi) disagree"
		warn "  The MCP server checks this: get_rpc_status reports a version_check"
		warn "  failure and tool calls may fault. Reinstall the addon with"
		warn "  $SCRIPT_DIR/freecad-mcp-addon.sh --update"
		DRIFT=$(( DRIFT + 1 ))
	fi
}

self_test() {
	init_colors
	fails=0
	t() {
		if [ "$2" = "$3" ]; then
			printf '  ok    %-56s [%s]\n' "$1" "$3"
		else
			printf '  FAIL  %-56s expected [%s] got [%s]\n' "$1" "$2" "$3"; fails=$(( fails + 1 ))
		fi
	}
	printf 'self-test: norm_ver\n'
	t "v1.1.4 -> 1.1.4"      '1.1.4'  "$(norm_ver 'v1.1.4')"
	t "1.1.4.0 -> 1.1.4"     '1.1.4'  "$(norm_ver '1.1.4.0')"
	t "1.18.34 unchanged"    '1.18.34' "$(norm_ver '1.18.34')"
	t "v1.18.34 -> 1.18.34"  '1.18.34' "$(norm_ver 'v1.18.34')"
	printf 'self-test: verdict (0=equal 1=drift 2=unavailable)\n'
	t "pin 1.1.4 / actual 1.1.4"     '0' "$(verdict '1.1.4' '1.1.4')"
	t "pin 1.1.4 / actual v1.1.4"    '0' "$(verdict '1.1.4' 'v1.1.4')"
	t "pin 1.1.4 / actual 1.1.3"     '1' "$(verdict '1.1.4' '1.1.3')"
	t "pin 1.1.4 / actual ''"        '2' "$(verdict '1.1.4' '')"
	t "no pin  / actual 9.9"         '0' "$(verdict '' '9.9')"
	t "an opencode pin typo would be caught as drift on the pin file" \
		'1' "$(verdict '1.18.34' '2.0.23')"
	printf 'self-test: first_token\n'
	t "opencode 1.18.34"    '1.18.34' "$(first_token '1.18.34')"
	t "uv 0.12.23 (...)"    '0.12.23' "$(first_token 'uv 0.12.23 (deadbeef 2026-01-01)')"
	t "no digits"           ''        "$(first_token 'FreeCAD')"
	if [ "$fails" -eq 0 ]; then printf 'self-test: all checks passed\n'; return 0; fi
	printf 'self-test: %d check(s) FAILED\n' "$fails"; return 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--json)          JSON=1;                     shift ;;
		--quiet)         QUIET=1;                    shift ;;
		--strict)        STRICT=1;                   shift ;;
		--strict-unavailable) STRICT_UNAVAILABLE=1;  shift ;;
		--versions-json)  VERSIONS_JSON=${2:?--versions-json needs a value}; shift 2 ;;
		--versions-json=*) VERSIONS_JSON=${1#--versions-json=}; shift ;;
		--self-test)     self_test; exit $? ;;
		-h|--help)       usage; exit 0 ;;
		*)               printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
done
init_colors

if [ "$JSON" = "1" ]; then
	QUIET=1
fi

run_compare

if [ "$JSON" = "1" ]; then
	printf '{\n  "versions_json": "%s",\n  "drift": %s,\n  "unavailable": %s,\n  "axes": [\n' \
		"$(json_escape "$VERSIONS_JSON")" "$DRIFT" "$UNAVAILABLE"
	first=1
	printf '%s' "$JSON_ROWS" | while IFS='|' read -r a e g s; do
		[ -n "$a" ] || continue
		[ "$first" = 1 ] || printf ',\n'
		first=0
		printf '    {"axis": "%s", "expected": "%s", "actual": "%s", "status": "%s"}' \
			"$(json_escape "$a")" "$(json_escape "$e")" "$(json_escape "$g")" "$s"
	done
	printf '\n  ]\n}\n'
else
	printf '\n'
	if [ "$DRIFT" -gt 0 ]; then
		err "$DRIFT axis/axes drifted. Run: $UPDATE_SCRIPT --dry-run"
	elif [ "$UNAVAILABLE" -gt 0 ]; then
		warn "no drift detected, but $UNAVAILABLE axis/axes could not be verified."
	else
		ok "no version drift detected across all axes"
	fi
fi

if [ "$DRIFT" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = "1" ] && [ "$UNAVAILABLE" -gt 0 ]; then exit 1; fi
if [ "$STRICT_UNAVAILABLE" = "1" ] && [ "$UNAVAILABLE" -gt 0 ]; then exit 1; fi
if [ "$UNAVAILABLE" -gt 0 ] && [ "$DRIFT" -eq 0 ] && [ "$JSON" != "1" ] && [ "$QUIET" != "1" ]; then
	exit 0
fi
exit 0