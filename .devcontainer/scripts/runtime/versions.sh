#!/bin/sh

versions_flat_json() {
	jq -c '{
		FREECAD_RESOLVE_MODE: .resolveMode,
		FREECAD_VERSION: .freecad.version,
		FREECAD_SHA256: .freecad.sha256,
		FREECAD_PYTHON_TAG: .freecad.pythonTag,
		FREECAD_ARCH: .freecad.arch,
		FREECAD_INSTALL: .freecad.install,
		UV_VERSION: .uv.version,
		UV_SHA256: .uv.sha256,
		UV_PYTHON_VERSION: .uv.pythonVersion,
		UV_ARCH: .uv.arch,
		OPENCODE_VERSION: .opencode.version,
		OPENCODE_BINARY_SHA512: .opencode.binaryPackage.integrity,
		OPENCODE_INSTALL: .opencode.install,
		OPENCODE_ARCH: .opencode.arch,
		FREECAD_MCP_VERSION: .freecadMcp.version,
		FREECAD_MCP_WHEEL_SHA256: .freecadMcp.wheel.sha256,
		FREECAD_MCP_SDIST_SHA256: .freecadMcp.sdist.sha256
	}' "$1"
}

freecad_version_from_home() {
	_versions_home=${1%/}
	_versions_name=${_versions_home##*/}
	if [ "$_versions_name" = squashfs-root ]; then
		_versions_parent=${_versions_home%/*}
		_versions_name=${_versions_parent##*/}
	fi
	printf '%s' "$_versions_name"
}

version_pin() {
	_versions_json=$1
	_versions_key=$2
	[ -f "$_versions_json" ] || return 0
	case $_versions_key in
		FREECAD_RESOLVE_MODE|FREECAD_VERSION|FREECAD_SHA256|FREECAD_PYTHON_TAG|FREECAD_ARCH|FREECAD_INSTALL|\
		UV_VERSION|UV_SHA256|UV_PYTHON_VERSION|UV_ARCH|\
		OPENCODE_VERSION|OPENCODE_BINARY_SHA512|OPENCODE_INSTALL|OPENCODE_ARCH|\
		FREECAD_MCP_VERSION|FREECAD_MCP_WHEEL_SHA256|FREECAD_MCP_SDIST_SHA256) ;;
		*) return 2 ;;
	esac
	versions_flat_json "$_versions_json" | jq -r --arg key "$_versions_key" '.[$key] // empty'
}

load_version_pins() {
	_versions_rows=$(versions_flat_json "$1" | jq -r 'to_entries[] | [.key, (.value // "" | tostring)] | @tsv') || return
	while IFS="$(printf '\t')" read -r _versions_key _versions_value; do
		case $_versions_key in
			FREECAD_RESOLVE_MODE|FREECAD_VERSION|FREECAD_SHA256|FREECAD_PYTHON_TAG|FREECAD_ARCH|FREECAD_INSTALL|\
			UV_VERSION|UV_SHA256|UV_PYTHON_VERSION|UV_ARCH|\
			OPENCODE_VERSION|OPENCODE_BINARY_SHA512|OPENCODE_INSTALL|OPENCODE_ARCH|\
			FREECAD_MCP_VERSION|FREECAD_MCP_WHEEL_SHA256|FREECAD_MCP_SDIST_SHA256)
				export "$_versions_key=$_versions_value"
				;;
		esac
	done <<EOF
$_versions_rows
EOF
}