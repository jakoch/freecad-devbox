#!/bin/sh
#
# show-checksums.sh (WP-7.12)
#
# Audit evidence: every artifact the build pinned and verified, with the hash
# that was checked. Nothing is downloaded here — this only reports what the
# build recorded, plus (optionally) a re-hash of files that are still in the
# image.
#
# IMPORTANT, and repeated in docs/versions.md and docs/architecture.md:
#   The FreeCAD/uv SHA256 sidecars are served from the SAME origin as the
#   artifacts. They prove transfer integrity (bit rot, a truncated download, a
#   CDN mix-up) — they do NOT prove provenance. FreeCAD publishes no .asc/.sig,
#   so a compromised upstream would publish a matching sidecar. The
#   compensating control is build attestation of the image itself (cosign /
#   GitHub build provenance), not the sidecar.
#
# POSIX sh / dash-safe.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
REPO_VERSIONS_JSON=${FREECAD_DEVBOX_REPO_VERSIONS_JSON:-}
. "$SCRIPT_DIR/versions.sh"
ADDON_NAME=FreeCADMCP
SETTINGS_FILE_NAME=freecad_mcp_settings.json

VERIFY=0
FORMAT=text

C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''; C_BOLD=''

usage() {
	cat <<'EOF'
show-checksums.sh — list every build-verified artifact and its hash

Usage:
  show-checksums.sh [--verify] [--format text|markdown|json]

Options
      --verify        also recompute hashes of artifacts still present in the
                      image (slow: the FreeCAD tree is ~2 GB, so by default only
                      the small marker files are re-hashed)
      --format F      text (default) | markdown | json
  -h, --help          this text

Provenance caveat: the upstream SHA256 sidecars come from the same origin as the
artifacts, so they prove transfer integrity, NOT provenance. See docs/versions.md.
EOF
}

init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
		C_RESET=$(printf '\033[0m'); C_RED=$(printf '\033[31m')
		C_YELLOW=$(printf '\033[33m'); C_GREEN=$(printf '\033[32m')
		C_CYAN=$(printf '\033[36m'); C_BOLD=$(printf '\033[1m')
	fi
}
log() { printf '%s[checksums]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--verify)   VERIFY=1;                            shift ;;
		--format)   FORMAT=${2:?--format needs a value}; shift 2 ;;
		--format=*) FORMAT=${1#--format=};                shift ;;
		-h|--help)  usage; exit 0 ;;
		*)          printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
done
init_colors

if [ ! -f "$VERSIONS_JSON" ] && [ -n "$REPO_VERSIONS_JSON" ] && [ -f "$REPO_VERSIONS_JSON" ]; then
	VERSIONS_JSON=$REPO_VERSIONS_JSON
fi
if [ ! -f "$VERSIONS_JSON" ]; then
	for _c in "$SCRIPT_DIR/../versions.json" "$SCRIPT_DIR/../../versions.json"; do
		if [ -f "$_c" ]; then VERSIONS_JSON=$_c; break; fi
	done
fi

pin() {
	version_pin "$VERSIONS_JSON" "$1"
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }

ROWS=''
MISSING_PINS=0

# row <component> <artifact/source> <algorithm> <hash> <verified-at-build?>
row() {
	if [ -z "$4" ] || [ "$4" = "(unset)" ]; then
		MISSING_PINS=$(( MISSING_PINS + 1 ))
		_h=$C_YELLOW"not pinned"$C_RESET
		[ "$FORMAT" = text ] || _h='not pinned'
	else
		_h=$4
	fi
	_v=$5
	if [ "$FORMAT" = text ]; then
		printf '%-24s %-52s %-8s %s\n' "$1" "$2" "$3" "$_h"
		[ "$_v" = '-' ] || printf '%-24s %-52s %-8s %s\n' '' '' 'source' "$_v"
	else
		ROWS="${ROWS}${1}|${2}|${3}|${4}|${5}
"
	fi
}

FREECAD_VERSION=$(pin FREECAD_VERSION)
FREECAD_ARCH=$(pin FREECAD_ARCH)
FREECAD_PYTHON_TAG=$(pin FREECAD_PYTHON_TAG)
FREECAD_INSTALL=$(pin FREECAD_INSTALL)

# ---------------------------------------------------------------------------
if [ "$FORMAT" = text ]; then
	printf 'Build-verified artifacts (from %s)\n' "$VERSIONS_JSON"
	printf '%-24s %-52s %-8s %s\n' 'COMPONENT' 'ARTIFACT / SOURCE' 'ALGO' 'HASH'
	printf '%-24s %-52s %-8s %s\n' '------------------------' '----------------------------------------------------' '--------' '----'
fi

# --- FreeCAD ---------------------------------------------------------------
if [ "$FREECAD_INSTALL" = apt ]; then
	row "FreeCAD (apt)" "Debian package, verified by apt signatures (InRelease), no sha256 sidecar" "apt" \
		"n/a" "apt in Trixie only carries 1.0.0 — this does NOT satisfy 'always current'"
else
	row "FreeCAD AppImage" \
		"FreeCAD_${FREECAD_VERSION}-Linux-${FREECAD_ARCH:-x86_64}-${FREECAD_PYTHON_TAG:-py311}.AppImage" \
		"sha256" "$(pin FREECAD_SHA256)" \
		"https://github.com/FreeCAD/FreeCAD/releases/download/${FREECAD_VERSION}/ (sidecar <asset>-SHA256.txt)"
fi

# --- uv --------------------------------------------------------------------
row "uv" "uv-x86_64-unknown-linux-gnu.tar.gz" "sha256" "$(pin UV_SHA256)" \
	"https://github.com/astral-sh/uv/releases (sidecar .sha256)"

# --- opencode --------------------------------------------------------------
# Binary package only: the image unpacks package/bin/opencode from it.
# The opencode-ai meta package is just a postinstall script and is not
# installed - hence there is no pin for it.
row "opencode (binary)" "npm opencode-linux-x64@$(pin OPENCODE_VERSION)" "sha512" \
	"$(pin OPENCODE_BINARY_SHA512)" "https://registry.npmjs.org/opencode-linux-x64"

# --- freecad-mcp -----------------------------------------------------------
row "freecad-mcp (wheel)" "freecad_mcp-$(pin FREECAD_MCP_VERSION)-py3-none-any.whl" "sha256" \
	"$(pin FREECAD_MCP_WHEEL_SHA256)" "https://pypi.org/project/freecad-mcp/"
_sdist=$(pin FREECAD_MCP_SDIST_SHA256)
if [ -n "$_sdist" ]; then
	row "freecad-mcp (sdist)" "freecad_mcp-$(pin FREECAD_MCP_VERSION).tar.gz" "sha256" \
		"$_sdist" "https://pypi.org/project/freecad-mcp/"
	row "freecad-mcp addon" "addon/FreeCADMCP from the same sdist" "sha256" \
		"$_sdist" "addon and MCP server come from one artifact -> no version drift possible"
fi

# ---------------------------------------------------------------------------
# local re-hash
# ---------------------------------------------------------------------------
if [ "$VERIFY" = "1" ]; then
	printf '\n'
	log "re-hashing artifacts still present in the image ..."
	UPDIR=${FREECAD_USER_DIR:-${HOME:-/root}/.local/share/FreeCAD}
	for f in "$VERSIONS_JSON" \
	         "$UPDIR/Mod/$ADDON_NAME/package.xml" \
	         "$UPDIR/Mod/$ADDON_NAME/rpc_server/version.py" \
	         "$UPDIR/Mod/$ADDON_NAME/InitGui.py" \
	         "$UPDIR/$SETTINGS_FILE_NAME" \
	         /usr/local/bin/freecad /usr/local/bin/freecadcmd \
	         "$SCRIPT_DIR/../opencode/opencode.json"
	do
		if [ -f "$f" ]; then
			printf '  %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
		else
			printf '  %snot present: %s%s\n' "$C_YELLOW" "$f" "$C_RESET"
		fi
	done
	if [ -n "${FREECAD_HOME:-}" ] && [ -d "$FREECAD_HOME" ]; then
		printf '\n'
		log "FreeCAD tree is large; hashing it on every start is not worth it."
		printf '  opt-in with: sha256sum -c /path/to/FreeCAD_%s-SHA256.txt   # run once\n' "$FREECAD_VERSION"
	fi
fi

# ---------------------------------------------------------------------------
# provenance warning + rendering
# ---------------------------------------------------------------------------
case "$FORMAT" in
	markdown)
		printf '## Build-verified artifacts\n\n'
		printf 'pins: `%s`\n\n' "$VERSIONS_JSON"
		printf '| Component | Artifact | Algo | Hash | Source |\n|---|---|---|---|---|\n'
		printf '%s' "$ROWS" | while IFS='|' read -r a b c d e; do
			[ -n "$a" ] || continue
			printf '| %s | `%s` | %s | `%s` | %s |\n' "$a" "$b" "$c" "${d:-not pinned}" "$e"
		done
		printf '\n'
		;;
	json)
		printf '{\n  "versions_json": "%s",\n  "artifacts": [\n' "$(json_escape "$VERSIONS_JSON")"
		first=1
		printf '%s' "$ROWS" | while IFS='|' read -r a b c d e; do
			[ -n "$a" ] || continue
			[ "$first" = 1 ] || printf ',\n'
			first=0
			printf '    {"component": "%s", "artifact": "%s", "algo": "%s", "hash": "%s", "source": "%s"}' \
				"$(json_escape "$a")" "$(json_escape "$b")" "$c" "$(json_escape "$d")" "$(json_escape "$e")"
		done
		printf '\n  ]\n}\n'
		;;
	text)
		printf '\n'
		;;
esac

printf '%s[checksums]%s %sPROVENANCE%s\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET"
printf '  The FreeCAD/uv SHA256 sidecars are served from the SAME origin as the artifact.\n'
printf '  They prove transfer integrity (bit rot, truncated download, CDN mix-up) and\n'
printf '  NOT provenance: FreeCAD publishes no .asc/.sig, so a compromised upstream\n'
printf '  would ship a matching sidecar. Compensating control: build attestation of\n'
printf '  the image itself (GitHub build provenance / cosign). See docs/versions.md.\n'

if [ "$MISSING_PINS" -gt 0 ]; then
	printf '\n'
	log "$MISSING_PINS artifact(s) have no hash in $VERSIONS_JSON — review the pins."
fi
exit 0