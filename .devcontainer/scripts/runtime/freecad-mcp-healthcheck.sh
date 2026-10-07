#!/bin/sh
#
# freecad-mcp-healthcheck.sh (WP-7.8, WP-7.9)
#
# Non-interactive, fast, bounded-by-timeout probe for the FreeCAD MCP XML-RPC
# server. The Dockerfile derives its HEALTHCHECK from this script:
#
#   HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
#     CMD ["/usr/local/bin/freecad-mcp-healthcheck.sh", "--timeout", "8", "--quiet"]
#
# Exit codes
#   0  OK    ping() answered (get_rpc_status() reported "running", or faulted
#            while the server clearly stayed alive)
#   1  FAIL  port closed, wrong host/port, ping() fault, or status != running
#   2  usage error
#
# Every socket call is bounded by an explicit timeout, so this can never hang a
# Docker healthcheck.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SHARE_DIR=${FREECAD_DEVBOX_SHARE_DIR:-/usr/local/share/freecad-devbox}
VERSIONS_JSON=${FREECAD_DEVBOX_VERSIONS_JSON:-$SHARE_DIR/versions.json}
. "$SCRIPT_DIR/versions.sh"

HOST=${FREECAD_MCP_HOST:-127.0.0.1}
PORT=${FREECAD_MCP_PORT:-9875}
TOKEN=${FREECAD_MCP_TOKEN:-}
TIMEOUT=${FREECAD_MCP_HEALTHCHECK_TIMEOUT:-5}
WAIT=0
QUIET=0
STRICT=0
JSON=0

C_RESET=''; C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''

usage() {
	cat <<'EOF'
freecad-mcp-healthcheck.sh — probe the FreeCAD MCP XML-RPC server

Usage:
  freecad-mcp-healthcheck.sh [--host H] [--port N] [--timeout SEC]
                             [--wait SEC] [--strict] [--json] [--quiet]

Options
  --host H     host to probe   (FREECAD_MCP_HOST,                default 127.0.0.1)
  --port N     port to probe   (FREECAD_MCP_PORT,                default 9875)
  --timeout S  per-call timeout in seconds
               (FREECAD_MCP_HEALTHCHECK_TIMEOUT,               default 5)
  --wait S     poll for up to S seconds before failing (default 0 = probe once)
  --strict     fail when get_rpc_status() errors too. Default is to accept it:
               a Fault response still proves the XML-RPC server answers.
  --json       machine-readable result on stdout
  --quiet      print nothing on success (for HEALTHCHECK)

Authentication
  If freecad_mcp_settings.json carries an auth_token, export FREECAD_MCP_TOKEN.
  It is sent as HTTP Basic with an empty username, which is exactly what the
  addon compares against auth_token (constant-time compare), i.e. the same as
  xmlrpc.client's  http://:TOKEN@host:port  URI form.

Exit: 0 OK, 1 FAIL, 2 usage error
EOF
}

die_usage() { printf 'error: %s\n' "$*" >&2; exit 2; }
log()  { printf '%s[healthcheck]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[healthcheck]%s %sWARN%s %s\n' "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }

emit_result() {
	# $1 exit code, $2 state (OK|WARN|FAIL), $3 message, $4 detail-json
	_rc=$1; _state=$2; _msg=$3; _detail=${4:-}

	if [ "$JSON" = "1" ]; then
		[ -n "$_detail" ] || _detail='null'
		printf '{"status":"%s","host":"%s","port":%s,"message":"%s","detail":%s}\n' \
			"$_state" "$HOST" "$PORT" "$_msg" "$_detail"
		return 0
	fi

	if [ "$QUIET" = "1" ] && [ "$_rc" = "0" ]; then
		return 0
	fi

	case "$_state" in
		OK)   printf '%s[healthcheck]%s %sOK%s   %s\n'   "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$_msg" ;;
		WARN) printf '%s[healthcheck]%s %sWARN%s %s\n'   "$C_CYAN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$_msg" ;;
		*)    printf '%s[healthcheck]%s %sFAIL%s %s\n'   "$C_CYAN" "$C_RESET" "$C_RED" "$C_RESET" "$_msg" >&2 ;;
	esac

	if [ -n "$_detail" ] && [ "$_detail" != "null" ]; then
		if command -v jq >/dev/null 2>&1; then
			printf '        detail: %s\n' "$(printf '%s' "$_detail" | jq -c . 2>/dev/null || printf '%s' "$_detail")"
		else
			printf '        detail: %s\n' "$_detail"
		fi
	fi

	if [ "$_rc" != "0" ]; then
		printf '        hints: FreeCAD running?      start-freecad-gui.sh\n' >&2
		printf '               auto_start_rpc?       $FREECAD_USER_DIR/freecad_mcp_settings.json\n' >&2
		printf '               allowed_ips/token?     same file (remote_enabled forces 0.0.0.0)\n' >&2
		printf '               who listens?           ss -ltnp | grep %s\n' "$PORT" >&2
	fi
	return 0
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--host)    HOST=${2:?--host needs a value};       shift 2 ;;
		--port)    PORT=${2:?--port needs a value};       shift 2 ;;
		--timeout) TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
		--wait)    WAIT=${2:?--wait needs a value};       shift 2 ;;
		--strict)  STRICT=1;                              shift ;;
		--json)    JSON=1;                                shift ;;
		-q|--quiet) QUIET=1;                              shift ;;
		-h|--help) usage; exit 0 ;;
		*)         printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$TIMEOUT" in ''|*[!0-9.]*) die_usage "invalid --timeout: $TIMEOUT" ;; esac
case "$WAIT"    in ''|*[!0-9]*)  die_usage "invalid --wait: $WAIT" ;; esac
case "$PORT"    in ''|*[!0-9]*)  die_usage "invalid --port: $PORT" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die_usage "port out of range: $PORT"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${FREECAD_DEVBOX_COLOR:-auto}" != "never" ]; then
	C_RESET=$(printf '\033[0m')
	C_RED=$(printf '\033[31m')
	C_YELLOW=$(printf '\033[33m')
	C_GREEN=$(printf '\033[32m')
	C_CYAN=$(printf '\033[36m')
fi

command -v python3 >/dev/null 2>&1 ||
	die_usage "python3 is required for the XML-RPC probe but was not found in PATH"

# Expected addon version: purely informational. An Addon/PyPI mismatch is drift
# for compare-versions.sh to report, not a health failure.
EXPECTED_VERSION=$(version_pin "$VERSIONS_JSON" FREECAD_MCP_VERSION)

# ---------------------------------------------------------------------------
# One bounded python process per attempt. Emits three tab-separated fields:
#   <state>\t<message>\t<detail-json>      state = ok | warn | fail
# ---------------------------------------------------------------------------
probe() {
	python3 - "$HOST" "$PORT" "$TIMEOUT" "$TOKEN" "$EXPECTED_VERSION" <<'PY'
import json, socket, sys, xmlrpc.client

host, port = sys.argv[1], int(sys.argv[2])
timeout, token, expected = float(sys.argv[3]), sys.argv[4], sys.argv[5]
detail = {}


def emit(state, message):
    # Tabs are stripped from the message so the three fields stay unambiguous.
    print("%s\t%s\t%s" % (state, message.replace("\t", " "),
                          json.dumps(detail, sort_keys=True, default=str) if detail else "null"))


# 1) TCP connect: bounded, independent of any XML-RPC framing.
try:
    with socket.create_connection((host, port), timeout=timeout):
        pass
except OSError as exc:
    emit("fail", "tcp connect to %s:%d failed: %s" % (host, port, exc))
    sys.exit(1)

# 2) XML-RPC proxy. The addon compares the Basic-auth *password* against
#    auth_token and ignores the username, which is what ""@ gives us.
url = "http://%s%s:%d" % ((":%s@" % token) if token else "", host, port)
try:
    proxy = xmlrpc.client.ServerProxy(url, allow_none=True)
    proxy("transport").timeout = timeout
except Exception as exc:
    emit("fail", "cannot build XML-RPC proxy: %s: %s" % (type(exc).__name__, exc))
    sys.exit(1)

# 3) ping() -> liveness.
try:
    pong = proxy.ping()
except Exception as exc:
    emit("fail", "XML-RPC ping() failed: %s: %s" % (type(exc).__name__, exc))
    sys.exit(1)
if pong is not True:
    emit("fail", "ping() answered %r, expected True" % (pong,))
    sys.exit(1)
detail["ping"] = True

# 4) get_rpc_status(): richer picture. A Fault here still proves liveness,
#    because the server parsed the call and produced an XML-RPC error.
state = "ok"
message = "XML-RPC server on %s:%d answered ping() and get_rpc_status()" % (host, port)
try:
    status = proxy.get_rpc_status()
except Exception as exc:
    detail["status_error"] = "%s: %s" % (type(exc).__name__, exc)
    state = "warn"
    message = ("ping() ok but get_rpc_status() faulted (%s) - server is alive, "
               "tool contract may differ" % (type(exc).__name__,))
else:
    detail["status"] = status
    if isinstance(status, dict):
        for key in ("rpc_server", "gui_dispatch", "addon_version",
                    "protocol_version", "async_jobs_running"):
            if key in status:
                detail[key] = status[key]
        if status.get("rpc_server") is not None and status.get("rpc_server") != "running":
            emit("fail", "get_rpc_status() reports rpc_server=%r" % (status["rpc_server"],))
            sys.exit(1)
        if status.get("success") is False:
            emit("fail", "get_rpc_status() reports success=false")
            sys.exit(1)

if expected and detail.get("addon_version") and detail["addon_version"] != expected:
    detail["version_mismatch"] = "pin %s, addon reports %s" % (expected, detail["addon_version"])

emit(state, message)
PY
}

# ---------------------------------------------------------------------------
# retry loop
# ---------------------------------------------------------------------------
max_attempts=1
if [ "$WAIT" -gt 0 ]; then
	max_attempts=$(( WAIT / 2 + 1 ))
fi

attempt=0
while :; do
	attempt=$(( attempt + 1 ))
	state=''; message=''; detail='null'
	line=''
	if line=$(probe); then :; else :; fi
	# probe always prints exactly one line, even when it exits non-zero.
	# The message is tab-free and the detail is one line of JSON, so plain
	# field cuts are exact here.
	if [ -n "$line" ]; then
		state=$(printf '%s\n' "$line" | cut -f1)
		message=$(printf '%s\n' "$line" | cut -f2)
		detail=$(printf '%s\n' "$line" | cut -f3-)
	else
		state=fail
		message="probe produced no output (python3 missing? interpreter broken?)"
	fi

	case "$state" in
		ok)
			emit_result 0 OK "$message" "$detail"
			exit 0
			;;
		warn)
			if [ "$STRICT" = "1" ]; then
				emit_result 1 FAIL "$message (--strict)" "$detail"
				exit 1
			fi
			emit_result 0 WARN "$message" "$detail"
			exit 0
			;;
		*)
			if [ "$attempt" -ge "$max_attempts" ]; then
				emit_result 1 FAIL "$message" "$detail"
				exit 1
			fi
			if [ "$WAIT" -gt 0 ]; then
				log "attempt $attempt/$max_attempts failed, retrying in 2s: $message"
			fi
			sleep 2
			;;
	esac
done