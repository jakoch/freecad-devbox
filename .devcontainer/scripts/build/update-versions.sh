#!/usr/bin/env bash
# =============================================================================
# update-versions.sh — WP-1.9 / WP-1.20: refresh pins, with review diff
# =============================================================================
#
# Determines the latest *stable* version of every component, downloads the
# official checksums and writes .devcontainer/versions.json atomically
# (tmp file + mv in the same directory, so the rename is atomic).
#
# Principles:
#   * NO silent upgrades. This script is never invoked by the image build
#     (WP-1.20). Only this manual tool writes versions.json.
#   * It writes only once the diff has been reviewed. Hence:
#       --dry-run  (default) shows the diff and changes nothing
#       --write    writes atomically
#   * Without --write nothing is touched, even if the diff is empty.
#
# ---------------------------------------------------------------------------
# VERIFICATION STATUS (honest)
# ---------------------------------------------------------------------------
# Run in a Debian trixie devcontainer with bash 5.2, curl, jq 1.7, diff,
# coreutils and network access:
#   * `bash -n` ok
#   * `--dry-run` against the real APIs: versions.json stays unchanged
#   * `--write` against a copy: writes atomically, produces an identical diff
#   * Negative test: no network -> clear error, no partial write
# NOT verified: execution inside GitHub Actions (no Docker, no runner).
# =============================================================================

set -euo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

VERSIONS_JSON=${VERSIONS_JSON:-$SCRIPT_DIR/../../versions.json}
RESOLVER=$SCRIPT_DIR/resolve-versions.sh

MODE=dry-run           # dry-run | write
ONLY=all              # all | freecad | uv | opencode | freecad-mcp
QUIET=0

# Deliberately GLOBAL: the EXIT trap only runs after returning from main(),
# so a "local tmp_res" would no longer be set and `set -u` would abort
# cleanup with "tmp_res: unbound variable".
tmp_res=''

log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '%s: ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — WP-1.9 refresh pins (with review diff, atomic write)

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --dry-run          show only the diff, write nothing (default)
  --write            update versions.json atomically (tmp + mv)
  --only WHICH       all (default) | freecad | uv | opencode | freecad-mcp
  --versions-json P  target file (default: $VERSIONS_JSON)
  -q, --quiet        errors only, on stderr
  -h, --help         this help

Flow:
  1. resolve the latest stable versions + checksums live (resolve-versions.sh --mode auto)
  2. update only the selected JSON fields and show the diff
  3. only with --write: replace atomically (tmp in the same dir + mv)

Note: the FreeCADMCP workbench deliberately has no pin of its own. It ships
inside the PyPI sdist of freecad-mcp (freecadMcp.sdist.sha256), which is also
where the image extracts it from, so addon and MCP server cannot drift apart.

Examples:
  $SCRIPT_NAME --dry-run            # view the diff (typical case)
  $SCRIPT_NAME --dry-run --only freecad
  $SCRIPT_NAME --write              # apply after review
EOF
}

merge_selected_versions() {
  local resolved_json=$1 output_json=$2
  jq --arg only "$ONLY" --slurpfile resolved "$resolved_json" '
    . as $current | $resolved[0] as $latest
    | if $only == "all" then $latest
      elif $only == "freecad" then
        $current | .freecad.version = $latest.freecad.version
                    | .freecad.sha256 = $latest.freecad.sha256
      elif $only == "uv" then
        $current | .uv.version = $latest.uv.version
                    | .uv.sha256 = $latest.uv.sha256
      elif $only == "opencode" then
        $current | .opencode.version = $latest.opencode.version
                    | .opencode.binaryPackage.integrity = $latest.opencode.binaryPackage.integrity
      elif $only == "freecad-mcp" then
        $current | .freecadMcp.version = $latest.freecadMcp.version
                    | .freecadMcp.wheel.sha256 = $latest.freecadMcp.wheel.sha256
                    | .freecadMcp.sdist.sha256 = $latest.freecadMcp.sdist.sha256
      else error("unsupported component: " + $only)
      end
  ' "$VERSIONS_JSON" >"$output_json"
}

main() {
  local arg diff_rc=0 dstdir tmp_new

  while [ $# -gt 0 ]; do
    arg=$1
    case $arg in
      --dry-run)          MODE=dry-run; shift ;;
      --write)            MODE=write; shift ;;
      --only)             ONLY=${2:?--only needs a value}; shift 2 ;;
      --versions-json)    VERSIONS_JSON=${2:?--versions-json needs a value}; shift 2 ;;
      -q|--quiet)         QUIET=1; shift ;;
      -h|--help)          usage; exit 0 ;;
      *)                  die "unknown argument: '$arg' (--help)" ;;
    esac
  done

  case $ONLY in
    all|freecad|uv|opencode|freecad-mcp) ;;
    *) die "--only: '$ONLY' (allowed: all|freecad|uv|opencode|freecad-mcp)" ;;
  esac

  [ -f "$VERSIONS_JSON" ] || die "versions.json not found: $VERSIONS_JSON"
  [ -f "$RESOLVER" ]     || die "resolve-versions.sh not found: $RESOLVER"
  have curl || die "curl is missing (required for live resolution)"
  have diff || die "diff is missing (required for the review diff)"
  have jq || die "jq is missing (required for versions.json)"

  # Resolve only the wanted components; the rest is carried over from the
  # current file, so a partial run cannot accidentally drop other pins.
  # resolve-versions.sh --mode auto resolves everything; we filter after it.
  tmp_res=$(mktemp -d)
  trap '[ -n "$tmp_res" ] && rm -rf "$tmp_res"' EXIT

  log "== update-versions: resolving latest stable versions live (--only=$ONLY)"
  if ! "$RESOLVER" --mode auto --format json --versions-json "$VERSIONS_JSON" \
        >"$tmp_res/resolved.json" 2>"$tmp_res/resolve.log"; then
    cat "$tmp_res/resolve.log" >&2
    die "resolve-versions.sh --mode auto failed - versions.json was NOT changed."
  fi
  # -n suppresses auto-print, so the trailing p is what actually emits the line.
  sed -n 's/^== done:/== [update-versions]/p' "$tmp_res/resolve.log" >&2 || true

  merge_selected_versions "$tmp_res/resolved.json" "$tmp_res/new.json" \
    || die "JSON pins could not be merged."

  # Review-Diff
  if jq -e --slurpfile updated "$tmp_res/new.json" '. == $updated[0]' "$VERSIONS_JSON" >/dev/null; then
    log ""
    log "== No change: all pins are already current."
    exit 0
  fi
  diff -u --label "a/versions.json (current)" --label "b/versions.json (new)" \
    "$VERSIONS_JSON" "$tmp_res/new.json" >"$tmp_res/diff.txt" 2>/dev/null || diff_rc=$?
  [ "$diff_rc" -eq 1 ] || [ "$diff_rc" -eq 0 ] \
    || die "diff aborted with exit $diff_rc (unknown error)"

  log ""
  log "== Diff for review (components: $ONLY)"
  cat "$tmp_res/diff.txt" >&2
  log ""

  if [ "$MODE" = dry-run ]; then
    log ""
    log "== DRY-RUN: versions.json was NOT changed."
    log "   To apply: $SCRIPT_NAME --write${ONLY:+ --only $ONLY}"
    exit 0
  fi

  # Write atomically: tmp in the same directory (same filesystem -> rename is
  # atomic), carrying over the original file's permissions.
  dstdir=$(dirname -- "$VERSIONS_JSON")
  tmp_new=$(mktemp "$dstdir/.versions.json.XXXXXX")
  jq . "$tmp_res/new.json" >"$tmp_new"
  chmod --reference="$VERSIONS_JSON" "$tmp_new" 2>/dev/null || chmod 644 "$tmp_new"
  mv -f "$tmp_new" "$VERSIONS_JSON"

  log ""
  log "== versions.json updated (atomically via tmp + mv)."
  log "   Please review the diff above and commit it."
}

main "$@"