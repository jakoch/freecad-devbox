#!/bin/sh
#
# show-tool-versions.sh (WP-7.6)
#
# Soll (expected) vs. Ist (actual) for every external component of the image.
# The expected side comes from the image's built copy of versions.json:
#   /usr/local/share/freecad-devbox/versions.json
#
# Degrades, never crashes: a missing versions.json or a missing binary yields
# "unavailable" plus an explanation instead of an abort.
#
# POSIX sh / dash-safe.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
REPO_VERSIONS_JSON=${FREECAD_DEVBOX_REPO_VERSIONS_JSON:-}
. "$SCRIPT_DIR/versions.sh"
FREECAD_HOME=${FREECAD_HOME:-}
SETTINGS_FILE_NAME=freecad_mcp_settings.json
ADDON_NAME=FreeCADMCP

FORMAT=markdown
CHECK_JSON=''
JSON_VALIDATOR=${FREECAD_DEVBOX_JSON_CHECK:-auto}
ONLY_DRIFT=0
WARN_EXIT=0

C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''; C_DIM=''; C_BOLD=''

usage() {
	cat <<'EOF'
show-tool-versions.sh — Soll (versions.json) vs. Ist (installed) for every tool

Usage:
  show-tool-versions.sh [options]

Options
  -f, --format FORMAT   markdown (default) | text | json | csv
	--versions-json F  path of versions.json (default
				 /usr/local/share/freecad-devbox/versions.json)
      --drift           only rows whose status is not OK
      --warn-exit       exit 1 when any row is not OK (default: exit 0)
      --check-json F    validate that F is strict JSON (jq if available, else a
                        bundled awk checker) and exit accordingly
      --self-test       run the pure-logic self tests (no FreeCAD required)
  -h, --help            this text

Exit
  0  report produced (or all rows OK when --warn-exit is used)
  1  drift detected (--warn-exit) / --check-json found invalid JSON
  2  usage error

Environment
  FREECAD_HOME            FreeCAD install dir, default: newest /opt/freecad/*
  FREECAD_USER_DIR        override the auto-detected FreeCAD user dir
  FREECAD_DEVBOX_JSON_CHECK  auto | jq | awk
EOF
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
log()  { printf '%s[versions]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s[versions]%s %sWARN%s %s\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[versions]%s %sFAIL%s %s\n' "$C_CYAN" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 2; }

init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
		C_RESET=$(printf '\033[0m')
		C_RED=$(printf '\033[31m')
		C_YELLOW=$(printf '\033[33m')
		C_GREEN=$(printf '\033[32m')
		C_CYAN=$(printf '\033[36m')
		C_DIM=$(printf '\033[2m')
		C_BOLD=$(printf '\033[1m')
	fi
}

# version normalisation for drift comparison:  " v1.1.4 " -> "1.1.4",
# trailing ".0" components are insignificant (1.1.4 == 1.1.4.0).
norm_ver() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
		sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^v//' |
		sed -e 's/\.0$//' -e 's/\.0$//' -e 's/\.0$//'
}

first_token() {
	# first dotted-number token in a --version output, if any
	printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1
}

pin() {
	version_pin "$VERSIONS_JSON" "$1"
}

resolve_freecad_user_dir() {
	_base=${FREECAD_USER_DIR:-}
	if [ -z "$_base" ]; then
		for _d in "${HOME:-/root}/.local/share/FreeCAD" "${HOME:-/root}/.FreeCAD" \
		         "${HOME:-/root}/.local/share/FreeCAD/v1-1"; do
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
	if [ -n "$FREECAD_HOME" ] && [ -d "$FREECAD_HOME" ]; then
		printf '%s\n' "$FREECAD_HOME"; return 0
	fi
	for _d in /opt/freecad/*; do
		if [ -d "$_d" ]; then printf '%s\n' "$_d"; return 0; fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# actual-version probes
# ---------------------------------------------------------------------------
actual_freecad() {
	_out=''
	if _home=$(resolve_freecad_home); then
		_out=$(freecad_version_from_home "$_home")
	fi
	if command -v freecadcmd >/dev/null 2>&1; then
		_v=$(first_token "$(freecadcmd --version 2>/dev/null || true)")
		[ -n "$_v" ] || _v=''
		if [ -n "$_out" ] && [ -n "$_v" ] && [ "$(norm_ver "$_out")" != "$(norm_ver "$_v")" ]; then
			printf '%s (freecadcmd reports %s)' "$_out" "$_v"
			return 0
		fi
		[ -n "$_out" ] || _out=$_v
	fi
	printf '%s' "$_out"
}

actual_addon_version() {
	_mod="$(resolve_freecad_user_dir)/Mod/$ADDON_NAME"
	[ -d "$_mod" ] || return 0
	# 1) package.xml is the canonical metadata (verified upstream: 0.1.25)
	if [ -f "$_mod/package.xml" ]; then
		_v=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "$_mod/package.xml" | head -n 1)
		if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
	fi
	# 2) rpc_server/version.py carries __version__
	if [ -f "$_mod/rpc_server/version.py" ]; then
		_v=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
			"$_mod/rpc_server/version.py" | head -n 1)
		if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
	fi
	return 0
}

actual_pypi_version() {
	if command -v freecad-mcp >/dev/null 2>&1; then
		_v=$(first_token "$(freecad-mcp --version 2>/dev/null || true)")
		if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
	fi
	if command -v python3 >/dev/null 2>&1; then
		_v=$(python3 - <<'PY' 2>/dev/null || true
try:
    from importlib.metadata import version, PackageNotFoundError
except ImportError:                                  # Python < 3.8
    raise SystemExit(0)
try:
    print(version("freecad-mcp"))
except PackageNotFoundError:
    pass
except Exception:
    pass
PY
)
		if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
	fi
	# last resort: scan the uv tool / env dirs for dist-info
	for _d in /opt/uv/tools/*/lib/python*/site-packages/freecad_mcp-*.dist-info \
	           /opt/uv/venvs/*/lib/python*/site-packages/freecad_mcp-*.dist-info; do
		if [ -d "$_d" ]; then
			basename -- "$_d" | sed -n 's/^freecad_mcp-\(.*\)\.dist-info$/\1/p'
			return 0
		fi
	done
	if command -v uv >/dev/null 2>&1; then
		uv tool list 2>/dev/null | sed -n 's/^freecad-mcp v\?\([0-9][^ ]*\).*/\1/p' | head -n 1
	fi
	return 0
}

actual_cmd_version() {
	# $1 = binary, $2 = flag
	if ! command -v "$1" >/dev/null 2>&1; then return 0; fi
	first_token "$("$1" "$2" 2>/dev/null || true)"
}

dpkg_version() {
	command -v dpkg-query >/dev/null 2>&1 || return 0
	dpkg-query -W -f='${Version}' "$1" 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------------------
# version comparison: 0 = equal, 1 = different, 2 = unknown/unavailable
# ---------------------------------------------------------------------------
compare_row() {
	_expected=$1; _actual=$2; _min=$3
	if [ -z "$_expected" ] && [ -z "$_actual" ]; then printf '0'; return 0; fi
	if [ -z "$_actual" ]; then printf '2'; return 0; fi
	if [ -z "$_expected" ]; then printf '0'; return 0; fi
	if [ "$(norm_ver "$_expected")" = "$(norm_ver "$_actual")" ]; then printf '0'; return 0; fi
	if [ -n "$_min" ]; then
		_a=$(norm_ver "$_actual")
		if [ "$(printf '%s\n%s\n' "$_min" "$_a" | sort -V | head -n 1)" = "$(norm_ver "$_min")" ] &&
		   [ "$(printf '%s\n%s\n' "$_min" "$_a" | sort -V | tail -n 1)" = "$_a" ]; then
			printf '0'; return 0
		fi
	fi
	printf '1'
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr -d '\n'
}

# ---------------------------------------------------------------------------
# strict JSON checker (fallback when jq is absent)
# ---------------------------------------------------------------------------
json_check_awk() {
	awk '
	function fail(msg) { printf("invalid JSON: %s\n", msg) > "/dev/stderr"; bad=1; exit 1 }
	{
		line = $0
		n = length(line)
		for (i = 1; i <= n; i++) {
			c = substr(line, i, 1)
			if (instring) {
				if (esc) { esc = 0; continue }
				if (c == "\\") { esc = 1; continue }
				if (c == "\"") { instring = 0; continue }
				continue
			}
			if (c == "\"") { instring = 1; prev = "\""; continue }
			if (c == "{" || c == "[") { depth++; stack = stack c; prev = c; continue }
			if (c == "}" || c == "]") {
				if (depth == 0) fail("unbalanced closing \"" c "\" at line " NR)
				top = substr(stack, length(stack), 1)
				if ((c == "}" && top != "{") || (c == "]" && top != "[")) \
					fail("mismatched closing \"" c "\" at line " NR)
				depth--; stack = substr(stack, 1, length(stack) - 1); prev = c; continue
			}
			if (c == " " || c == "\t") continue
			if (c == ",") { if (prev == "") fail("unexpected \",\" at line " NR); prev = ","; continue }
			prev = c
		}
		# a trailing comma before a closing bracket is caught on the next line/char
		if (prev == ",") lastcomma = NR
		else lastcomma = 0
	}
	END {
		if (bad) exit 1
		if (instring) { printf("invalid JSON: unterminated string\n") > "/dev/stderr"; exit 1 }
		if (depth != 0) { printf("invalid JSON: %d unclosed bracket(s)\n", depth) > "/dev/stderr"; exit 1 }
		if (lastcomma) { printf("invalid JSON: trailing comma at line %d\n", lastcomma) > "/dev/stderr"; exit 1 }
	}
	' "$1"
}

check_json_file() {
	_f=$1
	if [ ! -f "$_f" ]; then
		err "no such file: $_f"
		return 1
	fi
	case "$JSON_VALIDATOR" in
		jq)
			if jq empty "$_f" 2>/tmp/fdev-json.err; then
				log "strict JSON OK: $_f (jq)"
				return 0
			fi
			err "invalid JSON: $_f"
			sed 's/^/        /' /tmp/fdev-json.err >&2 || true
			return 1
			;;
		awk)
			if json_check_awk "$_f"; then
				log "strict JSON OK: $_f (awk fallback)"
				return 0
			fi
			return 1
			;;
		*)
			if command -v jq >/dev/null 2>&1; then
				JSON_VALIDATOR=jq
				check_json_file "$_f"
				return $?
			fi
			JSON_VALIDATOR=awk
			check_json_file "$_f"
			return $?
			;;
	esac
}

# ---------------------------------------------------------------------------
# row collection:  name|expected|actual|status|source
# ---------------------------------------------------------------------------
collect_rows() {
	_e_freecad=$(pin FREECAD_VERSION)
	_e_mcp=$(pin FREECAD_MCP_VERSION)
	_e_uv=$(pin UV_VERSION)
	_e_oc=$(pin OPENCODE_VERSION)

	# FreeCAD GUI: authoritative source is the install path (WP-1.19), because
	# an extracted AppImage does not reliably report its version.
	_a_freecad=$(actual_freecad)
	_a_freecadcmd=$(actual_cmd_version freecadcmd --version)
	_a_addon=$(actual_addon_version)
	_a_pypi=$(actual_pypi_version)
	_a_opencode=$(actual_cmd_version opencode --version)
	_a_uv=$(actual_cmd_version uv --version)
	_a_uvx=$(actual_cmd_version uvx --version)
	_a_py=$(actual_cmd_version python3 -V)
	_a_py=$(norm_ver "$_a_py")
	_a_xvfb=$(dpkg_version xvfb)
	if [ -z "$_a_xvfb" ] && command -v Xvfb >/dev/null 2>&1; then
		_a_xvfb=$(Xvfb -help 2>&1 | head -n 1 || true)
	fi
	_a_x11vnc=$(dpkg_version x11vnc)
	if [ -z "$_a_x11vnc" ] && command -v x11vnc >/dev/null 2>&1; then
		_a_x11vnc=$(x11vnc -version 2>&1 | head -n 1 || true)
		_a_x11vnc=$(first_token "$_a_x11vnc")
	fi

	add_row "FreeCAD"            "$_e_freecad" "$_a_freecad"   "" "install path $(resolve_freecad_home 2>/dev/null || echo 'n/a')"
	add_row "freecadcmd"         "$_e_freecad" "$_a_freecadcmd" "" "freecadcmd --version"
	add_row "freecad-mcp (addon)" "$_e_mcp"    "$_a_addon"     "" "$(resolve_freecad_user_dir)/Mod/$ADDON_NAME/package.xml"
	add_row "freecad-mcp (PyPI)"  "$_e_mcp"    "$_a_pypi"      "" "importlib.metadata / uv tool list"
	add_row "opencode"           "$_e_oc"      "$_a_opencode"  "" "opencode --version"
	add_row "uv"                 "$_e_uv"      "$_a_uv"        "" "uv --version"
	add_row "uvx"                "$_e_uv"      "$_a_uvx"       "" "uvx --version"
	add_row "python3"            ">=3.12"      "$_a_py"        "3.12" "python3 -V (>=3.12 required by freecad-mcp)"
	add_row "Xvfb"               ""           "$_a_xvfb"      "" "dpkg-query xvfb"
	add_row "x11vnc"             ""           "$_a_x11vnc"    "" "dpkg-query x11vnc"
}

ROWS=''
add_row() {
	_name=$1; _exp=$2; _act=$3; _min=$4; _src=$5
	_rc=$(compare_row "$_exp" "$_act" "$_min")
	case "$_rc" in
		0) if [ -z "$_exp" ]; then _st='n/a'; else _st='OK'; fi ;;
		1) _st='MISMATCH' ;;
		*) _st='UNAVAILABLE' ;;
	esac
	[ -n "$_act" ] || _act='unavailable'
	[ -n "$_exp" ] || _exp='(no pin)'
	ROWS="${ROWS}${_name}|${_exp}|${_act}|${_st}|${_src}
"
}

# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
render_markdown() {
	printf '## Tool versions — expected (versions.json) vs. actual\n\n'
	printf 'pins file: `%s`\n\n' "$VERSIONS_JSON"
	printf '| Tool | Expected | Actual | Status | Source |\n'
	printf '|---|---|---|---|---|\n'
	printf '%s' "$ROWS" | while IFS='|' read -r n e a s src; do
		[ -n "$n" ] || continue
		[ "$ONLY_DRIFT" = "1" ] && [ "$s" = 'OK' ] && continue
		printf '| %s | `%s` | `%s` | %s | %s |\n' "$n" "$e" "$a" "$s" "$src"
	done
	printf '\n'
	notes
}

render_text() {
	printf 'Tool versions — expected (versions.json) vs. actual\n'
	printf 'pins: %s\n' "$VERSIONS_JSON"
	printf '%-22s %-14s %-22s %s\n' 'TOOL' 'EXPECTED' 'ACTUAL' 'STATUS'
	printf '%s' "$ROWS" | while IFS='|' read -r n e a s src; do
		[ -n "$n" ] || continue
		[ "$ONLY_DRIFT" = "1" ] && [ "$s" = 'OK' ] && continue
		case "$s" in
			OK)          _c=$C_GREEN ;;
			MISMATCH)    _c=$C_RED ;;
			UNAVAILABLE) _c=$C_YELLOW ;;
			*)           _c=$C_DIM ;;
		esac
		printf '%-22s %-14s %-22s %s%s%s\n' "$n" "$e" "$a" "$_c" "$s" "$C_RESET"
	done
	printf '\n'
	notes
}

render_csv() {
	printf 'tool,expected,actual,status,source\n'
	printf '%s' "$ROWS" | while IFS='|' read -r n e a s src; do
		[ -n "$n" ] || continue
		printf '%s,%s,%s,%s,%s\n' "$n" "$e" "$a" "$s" "$src"
	done
}

render_json() {
	printf '{\n'
	printf '  "versions_json": "%s",\n' "$(json_escape "$VERSIONS_JSON")"
	printf '  "freecad_user_dir": "%s",\n' "$(json_escape "$(resolve_freecad_user_dir)")"
	printf '  "tools": [\n'
	_first=1
	printf '%s' "$ROWS" | while IFS='|' read -r n e a s src; do
		[ -n "$n" ] || continue
		[ "$_first" = "1" ] || printf ',\n'
		_first=0
		printf '    {"tool": "%s", "expected": "%s", "actual": "%s", "status": "%s", "source": "%s"}' \
			"$(json_escape "$n")" "$(json_escape "$e")" "$(json_escape "$a")" \
			"$s" "$(json_escape "$src")"
	done
	printf '\n  ]\n}\n'
}

notes() {
	[ -f "$VERSIONS_JSON" ] || {
		warn "$VERSIONS_JSON not found — the expected column is unavailable."
		warn "In the image this file is written at build time; on a host checkout use"
		warn "  --versions-json .devcontainer/versions.json"
		return 0
	}
	if printf '%s' "$ROWS" | grep -q '|MISMATCH|'; then
		warn "drift detected. Regenerate the pins with:"
		warn "  .devcontainer/scripts/build/update-versions.sh --dry-run   # then review the diff"
		warn "See docs/versions.md for the pinning policy."
	fi
}

# ---------------------------------------------------------------------------
# self test (pure logic, no FreeCAD required)
# ---------------------------------------------------------------------------
self_test() {
	init_colors
	fails=0
	t() { # t <desc> <expected> <got>
		if [ "$2" = "$3" ]; then
			printf '  ok    %-58s [%s]\n' "$1" "$3"
		else
			printf '  FAIL  %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"
			fails=$(( fails + 1 ))
		fi
	}
	printf 'self-test: version normalisation\n'
	t "norm_ver 'v1.1.4' -> 1.1.4"        '1.1.4'  "$(norm_ver 'v1.1.4')"
	t "norm_ver ' 0.12.23 ' -> 0.12.23"    '0.12.23' "$(norm_ver ' 0.12.23 ')"
	t "norm_ver '1.1.4.0' -> 1.1.4"       '1.1.4'  "$(norm_ver '1.1.4.0')"
	t "norm_ver '0.1.25' -> 0.1.25"        '0.1.25' "$(norm_ver '0.1.25')"
	printf 'self-test: comparison logic (0=equal 1=diff 2=unknown)\n'
	t "pin 1.1.4 vs actual 1.1.4"          '0' "$(compare_row '1.1.4' '1.1.4' '')"
	t "pin 1.1.4 vs actual v1.1.4"         '0' "$(compare_row '1.1.4' 'v1.1.4' '')"
	t "pin 1.1.4 vs actual 1.1.3"          '1' "$(compare_row '1.1.4' '1.1.3' '')"
	t "pin 1.1.4 vs missing actual"        '2' "$(compare_row '1.1.4' '' '')"
	t "no pin vs actual 9.9.9"             '0' "$(compare_row '' '9.9.9' '')"
	t "python 3.13 >= 3.12"                '0' "$(compare_row '>=3.12' '3.13.5' '3.12')"
	t "python 3.11 >= 3.12"                '1' "$(compare_row '>=3.12' '3.11.9' '3.12')"
	printf 'self-test: json escaping\n'
	t 'escape a\b"c'                       'a\\b\"c' "$(json_escape 'a\b"c')"
	printf 'self-test: first_token\n'
	t "extract 1.1.4 from 'FreeCAD 1.1.4'" '1.1.4' "$(first_token 'FreeCAD 1.1.4 (Rev 2026-09-28)')"
	t "extract 0.12.23 from 'uv 0.12.23 (x)'" '0.12.23' "$(first_token 'uv 0.12.23 (deadbeef 2026-01-01)')"
	t "no digits -> empty"                  '' "$(first_token 'Xvfb -help')"
	printf 'self-test: strict JSON checker (awk fallback)\n'
	_tmp=$(mktemp "${TMPDIR:-/tmp}/fdev-json-ok.XXXXXX")
	printf '{"a": [1, 2, {"b": "c"}], "d": null}\n' > "$_tmp"
	t 'valid object' '0' "$(json_check_awk "$_tmp" >/dev/null 2>&1; printf '%s' $?)"
	printf '{"a": 1,}\n' > "$_tmp"
	t 'trailing comma rejected' '1' "$(json_check_awk "$_tmp" >/dev/null 2>&1; printf '%s' $?)"
	printf '{"a": "unterminated\n' > "$_tmp"
	t 'unterminated string rejected' '1' "$(json_check_awk "$_tmp" >/dev/null 2>&1; printf '%s' $?)"
	printf '{"a": {\n' > "$_tmp"
	t 'unclosed brace rejected' '1' "$(json_check_awk "$_tmp" >/dev/null 2>&1; printf '%s' $?)"
	printf '{"a": ]}\n' > "$_tmp"
	t 'mismatched bracket rejected' '1' "$(json_check_awk "$_tmp" >/dev/null 2>&1; printf '%s' $?)"
	printf '{"a": "// not a comment"}\n' > "$_tmp"
	t 'JSONC line comment rejected' '1' "$(json_check_awk "$_tmp" >/dev/null 2>&1; printf '%s' $?)"
	rm -f "$_tmp"

	if [ "$fails" -eq 0 ]; then
		printf 'self-test: all checks passed\n'
		return 0
	fi
	printf 'self-test: %d check(s) FAILED\n' "$fails"
	return 1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
init_colors

while [ "$#" -gt 0 ]; do
	case "$1" in
		-f|--format)      FORMAT=${2:?--format needs a value}; shift 2 ;;
		--format=*)       FORMAT=${1#--format=};              shift ;;
		--versions-json)   VERSIONS_JSON=${2:?--versions-json needs a value}; shift 2 ;;
		--versions-json=*) VERSIONS_JSON=${1#--versions-json=};            shift ;;
		--drift)          ONLY_DRIFT=1;                        shift ;;
		--warn-exit)      WARN_EXIT=1;                         shift ;;
		--check-json)     CHECK_JSON=${2:?--check-json needs a value}; shift 2 ;;
		--check-json=*)   CHECK_JSON=${1#--check-json=};                 shift ;;
		--self-test)      self_test; exit $? ;;
		-h|--help)        usage; exit 0 ;;
		*)                die "unknown option '$1' (try --help)" ;;
	esac
done

case "$FORMAT" in
	markdown|text|json|csv) ;;
	*) die "unknown format '$FORMAT' (markdown|text|json|csv)" ;;
esac

if [ -n "$CHECK_JSON" ]; then
	check_json_file "$CHECK_JSON"
	exit $?
fi

# A host checkout can point at the repo's pin file instead of the built copy.
if [ ! -f "$VERSIONS_JSON" ] && [ -n "$REPO_VERSIONS_JSON" ] && [ -f "$REPO_VERSIONS_JSON" ]; then
	VERSIONS_JSON=$REPO_VERSIONS_JSON
fi
if [ ! -f "$VERSIONS_JSON" ]; then
	for _c in "$SCRIPT_DIR/../versions.json" "$SCRIPT_DIR/../../versions.json"; do
		if [ -f "$_c" ]; then VERSIONS_JSON=$_c; break; fi
	done
fi

collect_rows

case "$FORMAT" in
	markdown) render_markdown ;;
	text)     render_text ;;
	csv)      render_csv ;;
	json)     render_json ;;
esac

if [ "$WARN_EXIT" = "1" ]; then
	if printf '%s' "$ROWS" | grep -qE '\|(MISMATCH|UNAVAILABLE)\|'; then
		err "one or more components are out of sync with versions.json"
		exit 1
	fi
fi
exit 0