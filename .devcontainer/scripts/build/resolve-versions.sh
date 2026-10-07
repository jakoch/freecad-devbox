#!/usr/bin/env bash
# =============================================================================
# resolve-versions.sh — WP-1: resolve / verify pins
# =============================================================================
#
# Reads the pins from .devcontainer/versions.json and resolves missing values live.
# Two modes (WP-1.2):
#
#   PINNED (default)   Exact version from versions.json. If version *and*
#                      checksum are set, **not a single** network call is made
#                      for version resolution (WP-1.7) - the build works
#                      behind a firewall / without a GitHub token.
#   AUTO               Latest *stable* upstream release. Prereleases and
#                      drafts are explicitly excluded (WP-1.3).
#                      Trigger: --mode auto or FREECAD_VERSION=latest.
#
# Output (--format json, default): updated JSON pins in the same schema.
#
# ---------------------------------------------------------------------------
# VERIFICATION STATUS (honest - see todo.md / repo report)
# ---------------------------------------------------------------------------
# Run in a Debian trixie devcontainer with bash 5.2, curl, jq 1.7, coreutils
# and network access:
#   * `bash -n` ok, `sh -n` n/a (deliberately bash: pipefail, arrays)
#   * `--self-test` (fully offline) ok
#   * PINNED mode under `http_proxy=http://127.0.0.1:1` -> 0 network calls
#   * AUTO mode live against GitHub / npm / PyPI -> resolved 1.1.4 / 0.12.23 /
#     1.18.34 / 0.1.25, asset name existence confirmed in the release object
#   * Negative test "nonexistent version" -> clear error, no hang
# NOT verified: execution inside a `docker build` (no docker in the dev
# environment). The Dockerfile integration is therefore untested.
#
# Invocation: NOT from the Dockerfile. The image reads
# .devcontainer/versions.json directly with jq; this script is the tool for
# checking and refreshing pins (see build/update-versions.sh). Lives in
# scripts/build/.
# =============================================================================

set -euo pipefail

SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

# --- Defaults -----------------------------------------------------------------
VERSIONS_JSON=${VERSIONS_JSON:-$SCRIPT_DIR/../../versions.json}
. "$SCRIPT_DIR/../runtime/versions.sh"
MODE=pinned
FORMAT=json
QUIET=0
SELF_TEST=0
# Explicitly requested (possibly prerelease) tag; WP-1.3: only on demand.
FREECAD_TAG=""
# Behaviour when a value is still empty after resolution.
STRICT=1

# Upstream sources (as variables so CI can override them)
GITHUB_API=${GITHUB_API:-https://api.github.com}
GITHUB_DL=${GITHUB_DL:-https://github.com}
NPM_REGISTRY=${NPM_REGISTRY:-https://registry.npmjs.org}
PYPI_JSON=${PYPI_JSON:-https://pypi.org/pypi}

CURL_OPTIONS=${CURL_OPTIONS:---silent --show-error --location --fail --retry 5 --retry-all-errors --retry-delay 3 --retry-max-time 30}
CURL_CONNECT_TIMEOUT=${CURL_CONNECT_TIMEOUT:-15}

# All keys this script resolves. emit() and --build-arg check against this
# whitelist so nothing unexpected can leak into the ENV.
readonly ALL_KEYS="FREECAD_RESOLVE_MODE
FREECAD_VERSION FREECAD_SHA256 FREECAD_PYTHON_TAG FREECAD_ARCH FREECAD_INSTALL
UV_VERSION UV_SHA256 UV_PYTHON_VERSION UV_ARCH
OPENCODE_VERSION OPENCODE_BINARY_SHA512 OPENCODE_INSTALL OPENCODE_ARCH
FREECAD_MCP_VERSION FREECAD_MCP_WHEEL_SHA256 FREECAD_MCP_SDIST_SHA256"

# --- output -------------------------------------------------------------------
log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '%s: ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Counter proving offline operation (WP-1.7)
NET_CALLS=0
# Filled by fetch_* (avoids command substitution, which would not carry the
# variable state back into the parent shell context).
FETCHED_SHA=""

# --- read JSON pins ----------------------------------------------------------
read_versions_json() {
  local file=$1
  [ -f "$file" ] || die "versions.json not found: $file (--versions-json)"
  jq -e 'type == "object"' "$file" >/dev/null \
    || die "versions.json is not a valid JSON object: $file"
  load_version_pins "$file" || die "versions.json could not be read: $file"
}

is_known_key() {
  local k=$1 known
  for known in $ALL_KEYS; do
    [ "$known" = "$k" ] && return 0
  done
  return 1
}

# --- JSON access --------------------------------------------------------------
# jq is present in the image (WP-2.4). The sed/awk fallback exists so the script
# stays smoke-testable in the minimal `resolver` stage and on hosts without jq.
# Both paths are covered by --self-test.
HAVE_JQ=0
# RESOLVE_FORCE_NO_JQ=1 forces the sed/awk fallback. Testing only: it lets you
# exercise the fallback path on a host that does have jq (and vice versa).
if [ "${RESOLVE_FORCE_NO_JQ:-0}" != 1 ]; then
  have jq && HAVE_JQ=1
fi

json_get() {   # <file> <jq-filter>  -> scalar
  local file=$1 filter=$2
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r "${filter} // empty" <"$file" 2>/dev/null || true
  else
    json_get_fallback "$file" "$filter"
  fi
}

# Fallback for hosts without jq. Deliberately simple: it looks for the *last*
# component of a dotted path and takes the FIRST occurrence of that key. For the
# payloads we use (GitHub release/ref, npm metadata, PyPI JSON) that is unambiguous:
#   .tag_name        -> "tag_name"   (only occurrence)
#   .object.sha      -> "sha"        (only in .object)
#   .dist.integrity  -> "integrity"  (.dist precedes ._integrity)
#   .info.version    -> "version"    (.info comes early)
# jq is in the image anyway (WP-2.4) - this path exists only for smoke tests on
# hosts without jq.
json_get_fallback() {
  local file=$1 filter=$2 last
  last=$(printf '%s' "$filter" | sed 's/ .*//; s/^\[\]//; s/^.*\.\([A-Za-z0-9_]*\)$/\1/')
  case $last in
    ''|'*'|'..') return 0 ;;
  esac
  printf '%s' "$last" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || return 0
  sed -n "s/.*\"$last\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n 1
}

json_bool() {  # <file> <key> -> true|false
  local file=$1 key=$2
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r --arg k "$key" '(.[$k] // false) | tostring' <"$file" 2>/dev/null || true
  else
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$file" | head -n 1
  fi
}

# --- HTTP ---------------------------------------------------------------------
http_get() {   # <url> <dest>; error -> clear message, no hang
  local url=$1 dest=$2
  local -a hdr=()
  # The GitHub Accept header applies to api.github.com only. npm and PyPI answer
  # it with HTTP 406, so it is only sent there.
  case $url in
    "$GITHUB_API"/*)
      hdr+=(-H 'Accept: application/vnd.github+json')
      hdr+=(-H 'X-GitHub-Api-Version: 2022-11-28')
      [ -n "${GITHUB_TOKEN:-}" ] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
      ;;
  esac
  NET_CALLS=$((NET_CALLS + 1))
  log "  GET $url"
  if ! curl $CURL_OPTIONS --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        "${hdr[@]}" -o "$dest" "$url"; then
    rm -f "$dest"
    die "download failed: $url
  Possible causes: no network / proxy / 404 (resource does not exist) /
  invalid GITHUB_TOKEN. A token helps for GitHub API calls
  (60 requests/h without one, 5000 with)."
  fi
}

# --- Validierung --------------------------------------------------------------
# Asset names are derived, never hard-coded (WP-1.4).
#
# Mind the arch naming scheme: three different conventions.
#   Debian/RPM   x86_64 | aarch64     -> FREECAD_ARCH
#   Rust-Target  x86_64 | aarch64     -> uv  ("uv-x86_64-unknown-linux-gnu.tar.gz")
#   npm          x64     | arm64       -> opencode ("opencode-linux-x64")
freecad_asset_name()   { printf 'FreeCAD_%s-Linux-%s-%s.AppImage' "$1" "$2" "$3"; }
freecad_sidecar_name() { printf '%s-SHA256.txt' "$(freecad_asset_name "$1" "$2" "$3")"; }

uv_arch() {
  case "${UV_ARCH:-${FREECAD_ARCH:-x86_64}}" in
    x86_64|amd64)  printf 'x86_64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    *) die "unknown UV_ARCH/FREECAD_ARCH: '${UV_ARCH:-${FREECAD_ARCH:-}}' (x86_64|aarch64)" ;;
  esac
}
npm_arch() {
  case "${OPENCODE_ARCH:-${FREECAD_ARCH:-x86_64}}" in
    x86_64|amd64|x64)  printf 'x64' ;;
    aarch64|arm64)     printf 'arm64' ;;
    *) die "unknown OPENCODE_ARCH/FREECAD_ARCH: '${OPENCODE_ARCH:-${FREECAD_ARCH:-}}' (x86_64|aarch64)" ;;
  esac
}
uv_asset_name()   { printf 'uv-%s-unknown-linux-gnu.tar.gz' "$(uv_arch)"; }
opencode_pkg()    { printf 'opencode-linux-%s' "$(npm_arch)"; }

is_sha256()     { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }
is_commit_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }
is_sri_sha512() { printf '%s' "$1" | grep -Eq '^sha512-[A-Za-z0-9+/]+={0,2}$'; }

# Catches typos/injection before they are passed through as a 404 and end up in
# the 820 MB download (WP-11.10c: clear error instead of a hang).
validate_version_string() {
  local v=$1 what=$2
  case $v in
    '') die "$what: empty - expected e.g. '1.1.4', 'latest' or an explicit --*-tag." ;;
    latest|LATEST|Latest) return 0 ;;
  esac
  printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)*([.+_-][0-9A-Za-z.]+)?$' || die \
    "$what: '$v' does not look like a version number.
  Allowed: digits and '.', plus an optional suffix of '+', '-', '_'.
  For FreeCAD prereleases (weekly-*) use --freecad-tag <tag> explicitly."
}

# Two-phase check (WP-1.6): fetch the sidecar first and verify it belongs to the
# expected version / asset. Only then may the 820 MB asset be pulled. Sets FETCHED_SHA.
fetch_checksum_sidecar() {  # <version> <url> <expected-filename> <label>
  local version=$1 url=$2 expect_name=$3 label=$4
  local tmp line_count sha named
  tmp=$(mktemp -d)

  log "  [Phase 1/2] $label: loading checksum sidecar before the asset"
  http_get "$url" "$tmp/sidecar.txt"

  line_count=$(grep -cvE '^[[:space:]]*(#|$)' "$tmp/sidecar.txt" || true)
  [ "$line_count" = 1 ] || {
    rm -rf "$tmp"
    die "$label: sidecar $url has $line_count data lines, expected exactly 1.
  Expected format: '<sha256>  <asset>' (usable with sha256sum -c)."
  }

  sha=$(awk 'NF{print $1; exit}' "$tmp/sidecar.txt")
  named=$(awk 'NF{print $2; exit}' "$tmp/sidecar.txt")
  named=${named#\*}    # sha256sum binary mode: "<sha> *<name>"

  is_sha256 "$sha" || { rm -rf "$tmp"; die "$label: sidecar contains no valid sha256 (64 hex): '$sha'"; }
  [ "$named" = "$expect_name" ] || {
    rm -rf "$tmp"
    die "$label: sidecar does NOT belong to the expected artifact!
  expected: $expect_name  (version $version)
  found:    ${named:-<empty>}
  The two-phase check is meant to catch exactly this mix-up before the large
  asset is downloaded."
  }

  log "  [Phase 1/2] sidecar confirmed artifact '$expect_name'"
  FETCHED_SHA=$sha
  rm -rf "$tmp"
}

# --- resolution: FreeCAD ------------------------------------------------------
resolve_freecad() {
  local tmp tag pre draft asset

  validate_version_string "${FREECAD_VERSION:-}" FREECAD_VERSION
  FREECAD_PYTHON_TAG=${FREECAD_PYTHON_TAG:-py311}
  FREECAD_ARCH=${FREECAD_ARCH:-x86_64}
  FREECAD_INSTALL=${FREECAD_INSTALL:-appimage}

  if [ "$MODE" = auto ] || [ "${FREECAD_VERSION,,}" = latest ]; then
    tmp=$(mktemp -d)

    if [ -n "$FREECAD_TAG" ]; then
      # WP-1.3: prerelease only on explicit request.
      log "  [AUTO] explicitly requested tag: $FREECAD_TAG"
      http_get "$GITHUB_API/repos/FreeCAD/FreeCAD/releases/tags/$FREECAD_TAG" "$tmp/rel.json"
    else
      log "  [AUTO] determining latest stable release via the GitHub API"
      http_get "$GITHUB_API/repos/FreeCAD/FreeCAD/releases/latest" "$tmp/rel.json"
    fi

    tag=$(json_get "$tmp/rel.json" '.tag_name')
    [ -n "$tag" ] || die "GitHub API response has no 'tag_name'.
  Response was: $(head -c 300 "$tmp/rel.json")"
    FREECAD_VERSION=$tag
    validate_version_string "$FREECAD_VERSION" FREECAD_VERSION

    if [ -z "$FREECAD_TAG" ]; then
      pre=$(json_bool "$tmp/rel.json" prerelease)
      draft=$(json_bool "$tmp/rel.json" draft)
      [ "$pre" = false ] || die "tag '$FREECAD_VERSION' is a prerelease - aborting (WP-1.3).
  A prerelease is only accepted deliberately via --freecad-tag <tag>."
      [ "$draft" = false ] || die "tag '$FREECAD_VERSION' is a draft - aborting (WP-1.3)."
      log "  [AUTO] confirmed stable: tag=$FREECAD_VERSION prerelease=$pre draft=$draft"
    fi

    # Does the derived asset name exist in the release at all? This cleanly catches
    # "version ok, but that build flavour is no longer published".
    asset=$(freecad_asset_name "$FREECAD_VERSION" "$FREECAD_ARCH" "$FREECAD_PYTHON_TAG")
    if [ "$HAVE_JQ" -eq 1 ]; then
      if ! jq -e --arg a "$asset" '.assets[]? | select(.name == $a)' <"$tmp/rel.json" >/dev/null 2>&1; then
        die "FreeCAD $FREECAD_VERSION has no asset '$asset'.
  Available Linux assets:
$(jq -r '.assets[]?.name | select(test("Linux"))' <"$tmp/rel.json" 2>/dev/null | sed 's/^/    /')"
      fi
    fi
    log "  [AUTO] confirmed derived asset: $asset"

    fetch_checksum_sidecar "$FREECAD_VERSION" \
      "$GITHUB_DL/FreeCAD/FreeCAD/releases/download/$FREECAD_VERSION/$(freecad_sidecar_name "$FREECAD_VERSION" "$FREECAD_ARCH" "$FREECAD_PYTHON_TAG")" \
      "$asset" "FreeCAD"
    FREECAD_SHA256=$FETCHED_SHA
    rm -rf "$tmp"
  elif [ -n "${FREECAD_SHA256:-}" ]; then
    is_sha256 "$FREECAD_SHA256" || die "FREECAD_SHA256 is not a 64-digit hex value: '$FREECAD_SHA256'"
    log "  [PINNED] version + SHA256 set -> 0 network calls (WP-1.7)"
  else
    # Only the checksum is missing: exactly ONE sidecar download, no API call.
    fetch_checksum_sidecar "$FREECAD_VERSION" \
      "$GITHUB_DL/FreeCAD/FreeCAD/releases/download/$FREECAD_VERSION/$(freecad_sidecar_name "$FREECAD_VERSION" "$FREECAD_ARCH" "$FREECAD_PYTHON_TAG")" \
      "$(freecad_asset_name "$FREECAD_VERSION" "$FREECAD_ARCH" "$FREECAD_PYTHON_TAG")" "FreeCAD"
    FREECAD_SHA256=$FETCHED_SHA
  fi

  is_sha256 "$FREECAD_SHA256" || die "implausible FREECAD_SHA256: '$FREECAD_SHA256'"
  log "  FreeCAD $FREECAD_VERSION  asset=$(freecad_asset_name "$FREECAD_VERSION" "$FREECAD_ARCH" "$FREECAD_PYTHON_TAG")"
  log "  sha256 $FREECAD_SHA256"
}

# --- resolution: uv -----------------------------------------------------------
resolve_uv() {
  local tmp tag asset
  validate_version_string "${UV_VERSION:-}" UV_VERSION
  UV_PYTHON_VERSION=${UV_PYTHON_VERSION:-3.13}
  asset=$(uv_asset_name "$UV_VERSION")

  if [ "$MODE" = auto ]; then
    tmp=$(mktemp -d)
    log "  [AUTO] latest uv release via the GitHub API"
    http_get "$GITHUB_API/repos/astral-sh/uv/releases/latest" "$tmp/uv.json"
    tag=$(json_get "$tmp/uv.json" '.tag_name')
    [ -n "$tag" ] || die "uv: no 'tag_name' in the GitHub API response"
    UV_VERSION=${tag#v}
    asset=$(uv_asset_name "$UV_VERSION")
    rm -rf "$tmp"
  fi

  if [ -n "${UV_SHA256:-}" ]; then
    is_sha256 "$UV_SHA256" || die "UV_SHA256 is not a 64-digit hex value: '$UV_SHA256'"
    log "  [PINNED] uv $UV_VERSION + SHA256 set -> no resolution download"
  else
    # WP-1.10: the official .sha256 sidecar. Deliberately NOT `curl ... | sh`.
    fetch_checksum_sidecar "$UV_VERSION" \
      "$GITHUB_DL/astral-sh/uv/releases/download/$UV_VERSION/$asset.sha256" \
      "$asset" "uv"
    UV_SHA256=$FETCHED_SHA
  fi
  log "  uv $UV_VERSION  ($asset)"
  log "  sha256 $UV_SHA256"
}

# --- resolution: opencode -----------------------------------------------------
# Only the binary package opencode-linux-<arch> is pinned: the image installs
# exactly that (package/bin/opencode) and needs no nodejs.
resolve_opencode() {
  local tmp plat_pkg
  validate_version_string "${OPENCODE_VERSION:-}" OPENCODE_VERSION
  OPENCODE_INSTALL=${OPENCODE_INSTALL:-registry}
  plat_pkg="opencode-linux-$(npm_arch)"

  if [ "$MODE" = auto ] || [ -z "${OPENCODE_BINARY_SHA512:-}" ]; then
    tmp=$(mktemp -d)
    log "  [npm] $plat_pkg — .version + dist.integrity"
    http_get "$NPM_REGISTRY/$plat_pkg/latest" "$tmp/plat.json"
    if [ "$MODE" = auto ]; then
      OPENCODE_VERSION=$(json_get "$tmp/plat.json" '.version')
      [ -n "$OPENCODE_VERSION" ] || die "opencode: no '.version' in the npm metadata of $plat_pkg"
    fi
    plat_pkg="opencode-linux-$(npm_arch)"
    http_get "$NPM_REGISTRY/$plat_pkg/$OPENCODE_VERSION" "$tmp/plat.json"
    OPENCODE_BINARY_SHA512=$(json_get "$tmp/plat.json" '.dist.integrity')
    rm -rf "$tmp"
    [ -n "$OPENCODE_BINARY_SHA512" ] \
      || die "opencode: no '.dist.integrity' for $plat_pkg@$OPENCODE_VERSION"
  fi

  is_sri_sha512 "$OPENCODE_BINARY_SHA512" \
    || die "OPENCODE_BINARY_SHA512 is not an SRI string (sha512-<base64>): '$OPENCODE_BINARY_SHA512'"
  log "  opencode $OPENCODE_VERSION (install=$OPENCODE_INSTALL, $plat_pkg)"
}

# --- resolution: freecad-mcp (PyPI) -------------------------------------------
resolve_freecad_mcp() {
  local tmp v wheel
  validate_version_string "${FREECAD_MCP_VERSION:-}" FREECAD_MCP_VERSION

  if [ "$MODE" = auto ] || [ -z "${FREECAD_MCP_WHEEL_SHA256:-}" ]; then
    tmp=$(mktemp -d)
    log "  [PyPI] freecad-mcp JSON"
    http_get "$PYPI_JSON/freecad-mcp/json" "$tmp/pypi.json"
    if [ "$MODE" = auto ]; then
      v=$(json_get "$tmp/pypi.json" '.info.version')
      [ -n "$v" ] || die "freecad-mcp: no '.info.version' in the PyPI response"
      FREECAD_MCP_VERSION=$v
    fi
    # The package is py3-none-any -> there is exactly one wheel.
    if [ "$HAVE_JQ" -eq 1 ]; then
      wheel=$(jq -r --arg v "$FREECAD_MCP_VERSION" \
        '.urls[] | select(.packagetype == "bdist_wheel") | .digests.sha256' \
        <"$tmp/pypi.json" | head -n 1)
    else
      wheel=$(tr '{' '\n' <"$tmp/pypi.json" \
        | grep -m1 "freecad_mcp-$FREECAD_MCP_VERSION-py3-none-any.whl" \
        | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p')
    fi
    rm -rf "$tmp"
    [ -n "$wheel" ] && [ "$wheel" != null ] \
      || die "freecad-mcp $FREECAD_MCP_VERSION: no bdist_wheel in .urls"
    FREECAD_MCP_WHEEL_SHA256=$wheel
  fi

  is_sha256 "${FREECAD_MCP_WHEEL_SHA256:-}" \
    || die "FREECAD_MCP_WHEEL_SHA256 is not a 64-digit hex value: '${FREECAD_MCP_WHEEL_SHA256:-<empty>}'"
  if [ -n "${FREECAD_MCP_SDIST_SHA256:-}" ]; then
    is_sha256 "$FREECAD_MCP_SDIST_SHA256" \
      || die "FREECAD_MCP_SDIST_SHA256 is not a 64-digit hex value: '$FREECAD_MCP_SDIST_SHA256'"
  fi
  log "  freecad-mcp $FREECAD_MCP_VERSION  wheel $FREECAD_MCP_WHEEL_SHA256"
}

# --- addon -------------------------------------------------------------------
# No pin of its own any more: the image unpacks the addon from the PyPI sdist
# (addon/FreeCADMCP in the tarball) and verifies it against
# FREECAD_MCP_SDIST_SHA256. Workbench and MCP server therefore come from *one*
# artifact - the addon/PyPI coupling watched by compare-versions.sh cannot drift.

# --- output ------------------------------------------------------------------
emit() {
  local k v first=1
  case $FORMAT in
    env)
      for k in $ALL_KEYS; do
        eval "v=\${$k-}"; [ -n "$v" ] || continue
        printf '%s=%s\n' "$k" "$v"
      done ;;
    args)
      for k in $ALL_KEYS; do
        eval "v=\${$k-}"; [ -n "$v" ] || continue
        printf -- '--build-arg\n  %s=%s\n' "$k" "$v"
      done ;;
    shell)
      for k in $ALL_KEYS; do
        eval "v=\${$k-}"; [ -n "$v" ] || continue
        printf 'export %s=%s\n' "$k" "$v"
      done ;;
    json)
      jq \
        --arg mode "${FREECAD_RESOLVE_MODE:-PINNED}" \
        --arg freecad_version "${FREECAD_VERSION:-}" \
        --arg freecad_sha256 "${FREECAD_SHA256:-}" \
        --arg freecad_python_tag "${FREECAD_PYTHON_TAG:-}" \
        --arg freecad_arch "${FREECAD_ARCH:-}" \
        --arg freecad_install "${FREECAD_INSTALL:-}" \
        --arg uv_version "${UV_VERSION:-}" \
        --arg uv_sha256 "${UV_SHA256:-}" \
        --arg uv_python_version "${UV_PYTHON_VERSION:-}" \
        --arg uv_arch "${UV_ARCH:-}" \
        --arg opencode_version "${OPENCODE_VERSION:-}" \
        --arg opencode_binary_sha512 "${OPENCODE_BINARY_SHA512:-}" \
        --arg opencode_install "${OPENCODE_INSTALL:-}" \
        --arg opencode_arch "${OPENCODE_ARCH:-}" \
        --arg mcp_version "${FREECAD_MCP_VERSION:-}" \
        --arg mcp_wheel_sha256 "${FREECAD_MCP_WHEEL_SHA256:-}" \
        --arg mcp_sdist_sha256 "${FREECAD_MCP_SDIST_SHA256:-}" \
        '.resolveMode = $mode
         | .freecad.version = $freecad_version
         | .freecad.sha256 = $freecad_sha256
         | .freecad.pythonTag = $freecad_python_tag
         | .freecad.arch = $freecad_arch
         | .freecad.install = $freecad_install
         | .uv.version = $uv_version
         | .uv.sha256 = $uv_sha256
         | .uv.pythonVersion = $uv_python_version
         | .uv.arch = $uv_arch
         | .opencode.version = $opencode_version
         | .opencode.binaryPackage.integrity = $opencode_binary_sha512
         | .opencode.install = $opencode_install
         | .opencode.arch = $opencode_arch
         | .freecadMcp.version = $mcp_version
         | .freecadMcp.wheel.sha256 = $mcp_wheel_sha256
         | .freecadMcp.sdist.sha256 = $mcp_sdist_sha256' \
        "$VERSIONS_JSON" ;;
    *) die "unknown --format: $FORMAT (env|args|shell|json)" ;;
  esac
}

# --- self test (fully offline) ----------------------------------------------
self_test() {
  local d rc=0 out
  d=$(mktemp -d)

  printf '{"tag_name": "1.2.3", "prerelease": false, "draft": false, "assets": [{"name": "FreeCAD_1.2.3-Linux-x86_64-py311.AppImage"}]}' >"$d/a.json"
  printf '{"tag_name":"v9.9.9","prerelease":true,"draft":false}' >"$d/b.json"
  printf '{"object":{"sha":"d6bbe4b38be3a622b5981d9d2afa7037ee080534","type":"commit"}}' >"$d/c.json"

  out=$(json_get "$d/a.json" '.tag_name'); [ "$out" = 1.2.3 ] || { echo "FAIL tag_name (jq=$HAVE_JQ): '$out'" >&2; rc=1; }
  out=$(json_bool "$d/a.json" prerelease);  [ "$out" = false ] || { echo "FAIL prerelease: '$out'" >&2; rc=1; }
  out=$(json_bool "$d/b.json" prerelease);  [ "$out" = true ]  || { echo "FAIL prerelease=true: '$out'" >&2; rc=1; }
  out=$(json_get "$d/c.json" '.object.sha')
  [ "$out" = d6bbe4b38be3a622b5981d9d2afa7037ee080534 ] || { echo "FAIL nested .object.sha: '$out'" >&2; rc=1; }

  out=$(freecad_asset_name 1.1.4 x86_64 py311)
  [ "$out" = FreeCAD_1.1.4-Linux-x86_64-py311.AppImage ] || { echo "FAIL asset name: '$out'" >&2; rc=1; }
  out=$(freecad_sidecar_name 1.1.4 x86_64 py311)
  [ "$out" = FreeCAD_1.1.4-Linux-x86_64-py311.AppImage-SHA256.txt ] || { echo "FAIL sidecar name: '$out'" >&2; rc=1; }
  out=$(uv_asset_name)
  [ "$out" = uv-x86_64-unknown-linux-gnu.tar.gz ] || { echo "FAIL uv asset name: '$out'" >&2; rc=1; }
  FREECAD_ARCH=aarch64
  out=$(uv_asset_name);    [ "$out" = uv-aarch64-unknown-linux-gnu.tar.gz ] || { echo "FAIL uv asset aarch64: '$out'" >&2; rc=1; }
  out=$(npm_arch);         [ "$out" = arm64 ] || { echo "FAIL npm_arch aarch64: '$out'" >&2; rc=1; }
  out=$(opencode_pkg);     [ "$out" = opencode-linux-arm64 ] || { echo "FAIL opencode pkg aarch64: '$out'" >&2; rc=1; }
  FREECAD_ARCH=x86_64

  is_sha256 f6dc6ba676e5ac96a565ebc8d657232f94c6158e85b4352141bd1a46f6b43434 || { echo "FAIL is_sha256 positive" >&2; rc=1; }
  is_sha256 deadbeef && { echo "FAIL is_sha256 accepted a too-short value" >&2; rc=1; }
  is_sha256 f6dc6ba676e5ac96a565ebc8d657232f94c6158e85b4352141bd1a46f6b4343Z && { echo "FAIL is_sha256 accepted non-hex" >&2; rc=1; }
  is_commit_sha d6bbe4b38be3a622b5981d9d2afa7037ee080534 || { echo "FAIL is_commit_sha" >&2; rc=1; }
  is_commit_sha 1234 && { echo "FAIL is_commit_sha accepted a too-short value" >&2; rc=1; }
  is_sri_sha512 'sha512-9WUS2T0t4HHDVzXvuwTHF0nvhXvZ9mQ0r+ozCvKdJu0LVoQpOzqAW4qWTC3ygJc0Oedcc7j+Oct24JYlQYnySA==' || { echo "FAIL is_sri_sha512" >&2; rc=1; }
  is_sri_sha512 'deadbeef' && { echo "FAIL is_sri_sha512 accepted non-SRI" >&2; rc=1; }

  ( validate_version_string 1.1.4 X ) 2>/dev/null || { echo "FAIL validate ok" >&2; rc=1; }
  ( validate_version_string 0.12.23 X ) 2>/dev/null || { echo "FAIL validate uv ok" >&2; rc=1; }
  for bad in '' '9x9' '1.1.4; rm -rf /' '$(id)' '1.1.4 2' 'v1.1.4'; do
    if ( validate_version_string "$bad" X ) 2>/dev/null; then echo "FAIL validate accepted '$bad'" >&2; rc=1; fi
  done

  cat >"$d/versions.json" <<'EOF'
{
  "resolveMode": "PINNED",
  "freecad": {"version": "1.1.4", "sha256": "f6dc6ba676e5ac96a565ebc8d657232f94c6158e85b4352141bd1a46f6b43434", "pythonTag": "py311", "arch": "x86_64", "install": "appimage"},
  "uv": {"version": "0.12.23", "sha256": "9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6", "pythonVersion": "3.13", "arch": "x86_64"},
  "opencode": {"version": "1.18.34", "install": "registry", "arch": "x86_64", "binaryPackage": {"integrity": "sha512-example"}},
  "freecadMcp": {"version": "0.1.25", "wheel": {"sha256": "e52f04f8042122f0917cdcc09ada9fe3a7ea6e34c255984af45e77a0dc4c3efa"}, "sdist": {"sha256": "28b7bb22cb43c3b1bb672bef409386310308a8366851ab8bdf50ab687c8b5123"}},
  "LD_PRELOAD": "/tmp/evil.so"
}
EOF
  out=$(
    set -eu
    FREECAD_VERSION=; UV_VERSION=; UV_SHA256=; OPENCODE_VERSION=; FREECAD_ARCH=
    FREECAD_INSTALL=; FREECAD_PYTHON_TAG=; LD_PRELOAD=
    read_versions_json "$d/versions.json"
    printf '%s|%s|%s|%s|%s|%s|%s' \
      "$FREECAD_VERSION" "$UV_VERSION" "$UV_SHA256" "$OPENCODE_VERSION" \
      "$FREECAD_ARCH" "$FREECAD_INSTALL" "$FREECAD_PYTHON_TAG"
  ) || { echo "FAIL read_versions_json crashed" >&2; rc=1; }
  [ "$out" = '1.1.4|0.12.23|9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6|1.18.34|x86_64|appimage|py311' ] \
    || { echo "FAIL read_versions_json: '$out'" >&2; rc=1; }

  # Whitelist: only mapped JSON pins may be exported.
  out=$(
    set -eu
    unset LD_PRELOAD 2>/dev/null || true
    read_versions_json "$d/versions.json"
    printf '%s' "${LD_PRELOAD-<unset>}"
  ) || { echo "FAIL whitelist read crashed" >&2; rc=1; }
  [ "$out" = '<unset>' ] || { echo "FAIL JSON reader set LD_PRELOAD='$out'" >&2; rc=1; }

  printf '%s  %s\n' f6dc6ba676e5ac96a565ebc8d657232f94c6158e85b4352141bd1a46f6b43434 FreeCAD_1.1.4-Linux-x86_64-py311.AppImage >"$d/ok.sum"
  printf '%s *%s\n' f6dc6ba676e5ac96a565ebc8d657232f94c6158e85b4352141bd1a46f6b43434 FreeCAD_1.1.4-Linux-x86_64-py311.AppImage >"$d/bin.sum"
  out=$(awk 'NF{print $1; exit}' "$d/ok.sum")
  [ "$out" = f6dc6ba676e5ac96a565ebc8d657232f94c6158e85b4352141bd1a46f6b43434 ] || { echo "FAIL sidecar sha" >&2; rc=1; }
  out=$(awk 'NF{print $2; exit}' "$d/bin.sum"); out=${out#\*}
  [ "$out" = FreeCAD_1.1.4-Linux-x86_64-py311.AppImage ] || { echo "FAIL sidecar binary mode: '$out'" >&2; rc=1; }

  # The sidecar we generate must be accepted by sha256sum -c.
  printf '%s\n' "$(sha256sum "$d/ok.sum" | cut -d' ' -f1)  ok.sum" >"$d/real.sum"
  ( cd "$d" && sha256sum -c real.sum >/dev/null 2>&1 ) || { echo "FAIL sha256sum -c" >&2; rc=1; }

  # Whitelist: unknown keys must not slip through
  out=$( is_known_key FREECAD_VERSION && echo yes || echo no ); [ "$out" = yes ] || { echo "FAIL whitelist positive" >&2; rc=1; }
  out=$( is_known_key LD_PRELOAD && echo yes || echo no );      [ "$out" = no ]  || { echo "FAIL whitelist negative" >&2; rc=1; }
  out=$( is_known_key '' && echo yes || echo no );             [ "$out" = no ]  || { echo "FAIL whitelist empty" >&2; rc=1; }

  rm -rf "$d"
  if [ $rc -eq 0 ]; then
    printf 'self-test: OK (jq=%s)\n' "$([ "$HAVE_JQ" -eq 1 ] && echo present || echo 'sed-fallback')" >&2
  fi
  return $rc
}

usage() {
  cat <<EOF
$SCRIPT_NAME — WP-1 version resolution / pin verification

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --versions-json PATH   JSON file holding the pins (default: $VERSIONS_JSON)
  --mode MODE            pinned (default) | auto
  --format FORMAT        json (default) | env | args | shell
  --build-arg K=V        override a pin, like --build-arg in the Dockerfile;
                         repeatable. Keys not on the whitelist are ignored.
  --set K=V              alias for --build-arg
  --freecad-tag TAG      explicit release tag; deliberately accepts a
                         prerelease (WP-1.3). Without this option prerelease/
                         draft are rejected outright.
  --self-test            offline self test (no network)
  -q, --quiet            errors on stderr, otherwise silent
  -h, --help             this help

Examples:
  $SCRIPT_NAME                       # print pins (offline, 0 requests)
  $SCRIPT_NAME --mode auto           # resolve live
  $SCRIPT_NAME --format args         # as a docker build-arg list
  FREECAD_VERSION=latest $SCRIPT_NAME # == AUTO (FreeCAD only)
EOF
}

# CLI overrides (--build-arg / --set) and already-set environment variables take
# precedence over versions.json. So they are collected and applied only AFTER
# the file has been read - otherwise the file would overwrite them again.
declare -a OVERRIDE_KEYS=() OVERRIDE_VALS=()

record_override() {
  local arg=$1 key val
  case $arg in
    *=*) ;;
    *) die "--build-arg expects KEY=VALUE, got '$arg'" ;;
  esac
  key=${arg%%=*}
  val=${arg#*=}
  if ! is_known_key "$key"; then
    warn "unknown key '$key' will be ignored (whitelist)"
    return 0
  fi
  OVERRIDE_KEYS+=("$key")
  OVERRIDE_VALS+=("$val")
}

apply_overrides() {
  local i key
  for i in "${!OVERRIDE_KEYS[@]}"; do
    key="${OVERRIDE_KEYS[$i]}"
    printf -v "$key" '%s' "${OVERRIDE_VALS[$i]}"
    export "$key"
  done
  [ ${#OVERRIDE_KEYS[@]} -eq 0 ] || log "Overrides applied: ${OVERRIDE_KEYS[*]}"
}

main() {
  local arg
  while [ $# -gt 0 ]; do
    arg=$1
    case $arg in
      --versions-json)                 VERSIONS_JSON=${2:?--versions-json needs a value}; shift 2 ;;
      --mode)                          MODE=$(printf '%s' "${2:?--mode needs a value}" | tr 'A-Z' 'a-z'); shift 2 ;;
      --format)                        FORMAT=${2:?--format needs a value}; shift 2 ;;
      --build-arg|--set)               record_override "${2:?--build-arg needs a value}"; shift 2 ;;
      --freecad-tag)                   FREECAD_TAG=${2:?--freecad-tag needs a value}; shift 2 ;;
      --self-test)                     SELF_TEST=1; shift ;;
      -q|--quiet)                      QUIET=1; shift ;;
      -h|--help)                       usage; exit 0 ;;
      --)                              shift; break ;;
      *)                               die "unknown argument: '$arg' (--help)" ;;
    esac
  done

  if [ "$SELF_TEST" -eq 1 ]; then self_test; exit $?; fi

  # Force lowercase so that both the default variable and the value from
  # versions.json (resolveMode=PINNED) are accepted.
  MODE=$(printf '%s' "$MODE" | tr 'A-Z' 'a-z')
  case $MODE in
    pinned) ;;
    auto)   ;;
    *) die "--mode: '$MODE' (allowed: pinned|auto)" ;;
  esac

  # Capture environment variables as overrides first, then read versions.json,
  # then re-apply the overrides. Order:
  #   1. ENV      (e.g. FREECAD_VERSION=latest, as an ARG in the Dockerfile)
  #   2. file     (the checked-in pins)
  #   3. CLI      (--build-arg, highest priority)
  local k envv
  for k in $ALL_KEYS; do
    eval "envv=\${$k+x}"
    [ "$envv" = x ] || continue
    # Pass the value as its own argument (do not interpolate it into eval) -
    # otherwise the value stays the literal string '${VAR}'.
    eval "record_override \"\$k=\${$k}\""
  done

  read_versions_json "$VERSIONS_JSON"
  apply_overrides

  # "latest" is the documented shorthand for AUTO (FreeCAD only).
  if [ "$MODE" = pinned ] && [ "${FREECAD_VERSION,,}" = latest ]; then
    MODE=auto
    log "FREECAD_VERSION=latest -> mode AUTO (resolve live, not reproducible)"
  fi
  FREECAD_RESOLVE_MODE=$(printf '%s' "$MODE" | tr 'a-z' 'A-Z')

  log "== resolve-versions: mode=$FREECAD_RESOLVE_MODE  jq=$([ "$HAVE_JQ" -eq 1 ] && echo yes || echo 'no (sed-fallback)')  file=$VERSIONS_JSON"
  resolve_freecad
  resolve_uv
  resolve_opencode
  resolve_freecad_mcp

  log "== done: $NET_CALLS network call(s)"

  if [ "$STRICT" -eq 1 ]; then
    local k v
    for k in FREECAD_VERSION FREECAD_SHA256 FREECAD_PYTHON_TAG \
             UV_VERSION UV_SHA256 UV_PYTHON_VERSION \
             OPENCODE_VERSION OPENCODE_BINARY_SHA512 \
             FREECAD_MCP_VERSION FREECAD_MCP_WHEEL_SHA256 \
             FREECAD_MCP_SDIST_SHA256; do
      eval "v=\${$k-}"
      [ -n "$v" ] || die "internal error: $k is empty after resolution."
    done
  fi
  emit
}

main "$@"