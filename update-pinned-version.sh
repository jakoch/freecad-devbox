#!/bin/sh
#
# SPDX-License-Identifier: MIT
#
# update-pinned-version.sh — kurzer Wrapper fuer die Versions-Pflege.
#
# Die eigentliche Logik liegt in .devcontainer/scripts/build/update-versions.sh
# (unter build/, weil sie nicht ins Image gehoert). Dieses Skript existiert nur,
# damit man den langen Pfad nicht ausschreiben muss:
#
#   ./update-pinned-version.sh                          # Diff ansehen (Default)
#   ./update-pinned-version.sh --only opencode          # nur eine Komponente
#   ./update-pinned-version.sh --write --only opencode  # reviewed uebernehmen
#
# Ohne --write wird nichts geschrieben; das ist Absicht.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TARGET=$SCRIPT_DIR/.devcontainer/scripts/build/update-versions.sh

if [ ! -f "$TARGET" ]; then
	printf 'FEHLER: %s nicht gefunden.\n' "$TARGET" >&2
	printf 'Erwartet wird das Repo-Layout mit .devcontainer/scripts/build/.\n' >&2
	exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
	printf 'FEHLER: bash wird benoetigt (update-versions.sh ist ein bash-Skript).\n' >&2
	exit 1
fi

# Alle Argumente werden durchgereicht, der Exit-Code bleibt erhalten.
exec bash "$TARGET" "$@"