# syntax=docker/dockerfile:1
#
# SPDX-License-Identifier: MIT
#
# FreeCAD DevBox — Debian 13 (trixie)
# ===========================================================================
# Standard image: FreeCAD + freecad-mcp + opencode, preinstalled and prewired.
#
#   docker build -f .devcontainer/debian/13-trixie/Dockerfile -t freecad-devbox:trixie .
#   docker run --rm -it -p 6080:6080 freecad-devbox:trixie
#
#   FreeCAD 1.1.4        AppImage, extracted to /opt/freecad/<version> (no FUSE)
#   freecad-mcp 0.1.25   Python server (/opt/uv/venvs) + workbench (Mod/FreeCADMCP)
#   7 workbench addons   pinned by commit, cloned into Mod/<dir> for both users
#   opencode 1.18.35     /usr/local/bin/opencode
#   uv 0.12.23           /usr/local/bin/{uv,uvx}
#   Xvfb + x11vnc + noVNC, llvmpipe software rendering, zsh
#
# Pins: .devcontainer/versions.json is the only source of truth. Every download
# is verified against the SHA256/SRI recorded there and any mismatch fails the
# build. No "latest" on purpose; refresh with scripts/build/update-versions.sh.
#
# Before you edit:
#   * The AppImage bundles Qt6, X11/xcb, GL/EGL, fontconfig and Python 3.11, so
#     only the Mesa driver, fontconfig+fonts, dbus and an X server come from the
#     system. That is why there are no Qt6/libxcb packages here.
#   * /usr/local/bin/{freecad,freecadcmd} mirror AppRun's environment (PYTHONHOME,
#     Qt platform plugin, fontconfig, certs). Without them Qt loads the Wayland
#     plugin and crashes when the main window appears.
# ===========================================================================

ARG DEBIAN_VERSION_NAME=trixie

FROM debian:${DEBIAN_VERSION_NAME}-slim

ARG DEBIAN_VERSION=13
ARG DEBIAN_VERSION_NAME=trixie
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

# Downloads only; not part of the runtime environment.
ARG CURL_OPTIONS="--silent --show-error --location --fail --retry 5 --retry-all-errors --retry-delay 3 --retry-max-time 60 --connect-timeout 20"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    PYTHONUNBUFFERED=1 \
    XDG_RUNTIME_DIR=/tmp/runtime-${USER_UID} \
    FREECAD_DEVBOX_SHARE_DIR=/usr/local/share/freecad-devbox \
    FREECAD_DEVBOX_VERSIONS_JSON=/usr/local/share/freecad-devbox/versions.json \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe \
    QT_X11_NO_MITSHM=1 \
    DISPLAY=:99

# ---------------------------------------------------------------------------
# 1) Systempakete + unprivilegierter Benutzer
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash bash-completion ca-certificates curl file git jq less nano \
        procps ripgrep fd-find sudo tar tzdata xz-utils zsh \
        build-essential pkg-config python3 python3-dev python3-venv \
        fontconfig fonts-dejavu-core dbus dbus-x11 \
        libgl1-mesa-dri libglx-mesa0 mesa-utils \
        xvfb x11-utils x11vnc xauth fluxbox novnc websockify; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb; \
    \
    groupadd --force --gid "${USER_GID}" "${USERNAME}"; \
    useradd --create-home --shell /usr/bin/zsh --uid "${USER_UID}" --gid "${USER_GID}" "${USERNAME}" 2>/dev/null \
        || usermod --shell /usr/bin/zsh "${USERNAME}"; \
    printf '%s ALL=(root) NOPASSWD:ALL\n' "${USERNAME}" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"; \
    mkdir -p /usr/local/share/freecad-devbox/scripts /opt/uv; \
    # Pre-create ~/.config + ~/.cache owned by the user: FreeCAD SIGSEGVs \
    # cryptically if ~/.config exists but belongs to root (docker-exec trap). \
    home=$(getent passwd "${USERNAME}" | cut -d: -f6); \
    mkdir -p /workspaces "$home/.config" "$home/.cache"; \
    chown -R "${USER_UID}:${USER_GID}" "$home/.config" "$home/.cache" /workspaces

# ---------------------------------------------------------------------------
# 2) Pins, runtime scripts, opencode template
#    Only scripts/runtime/ ships; scripts/build/ is host-side tooling.
# ---------------------------------------------------------------------------
COPY .devcontainer/versions.json /usr/local/share/freecad-devbox/versions.json
COPY .devcontainer/opencode/opencode.json /usr/local/share/freecad-devbox/opencode.json
COPY .devcontainer/requirements-freecad-mcp.lock /opt/uv/requirements-freecad-mcp.lock
COPY .devcontainer/scripts/runtime/ /usr/local/share/freecad-devbox/scripts/

RUN set -eux; \
    chmod 0755 /usr/local/share/freecad-devbox/scripts/*.sh; \
    for f in /usr/local/share/freecad-devbox/scripts/*.sh; do \
        ln -sf "$f" "/usr/local/bin/$(basename "$f")"; \
    done; \
    chmod a+r /usr/local/share/freecad-devbox/versions.json /opt/uv/requirements-freecad-mcp.lock

# ---------------------------------------------------------------------------
# 3) uv from the official tarball, verified against the pin (no "curl | sh")
# ---------------------------------------------------------------------------
RUN set -eux; \
    vj=/usr/local/share/freecad-devbox/versions.json; \
    uv_ver=$(jq -r '.uv.version' "$vj"); \
    uv_sha=$(jq -r '.uv.sha256' "$vj"); \
    uv_arch=$(jq -r '.uv.arch' "$vj"); \
    test -n "$uv_ver" && test -n "$uv_sha"; \
    case "$uv_arch" in \
      x86_64|aarch64) ;; \
      *) echo "unknown uv.arch: '$uv_arch'" >&2; exit 1 ;; \
    esac; \
    asset="uv-${uv_arch}-unknown-linux-gnu.tar.gz"; \
    base="https://github.com/astral-sh/uv/releases/download/${uv_ver}"; \
    cd /tmp; \
    curl $CURL_OPTIONS -o "${asset}.sha256" "${base}/${asset}.sha256"; \
    grep -qF " ${asset}" "${asset}.sha256" || { echo "uv sidecar checksum does not belong to ${asset}" >&2; exit 1; }; \
    test "$(awk '{print $1; exit}' "${asset}.sha256")" = "$uv_sha" || { echo "Pin uv.sha256 != Sidecar" >&2; exit 1; }; \
    curl $CURL_OPTIONS -o "${asset}" "${base}/${asset}"; \
    echo "${uv_sha}  ${asset}" | sha256sum -c -; \
    mkdir -p /usr/local/uv; \
    tar -xzf "${asset}" -C /usr/local/uv --strip-components=1; \
    rm -f "${asset}" "${asset}.sha256"; \
    ln -sf /usr/local/uv/uv  /usr/local/bin/uv; \
    ln -sf /usr/local/uv/uvx /usr/local/bin/uvx; \
    chmod -R a+rX /usr/local/uv; \
    uv --version | grep -q "${uv_ver}"

# ---------------------------------------------------------------------------
# 4) opencode from the npm registry (SRI-verifiable; GitHub has no checksums)
#    Self-contained binary; no nodejs/npm needed in the image.
# ---------------------------------------------------------------------------
RUN set -eux; \
    vj=/usr/local/share/freecad-devbox/versions.json; \
    oc_ver=$(jq -r '.opencode.version' "$vj"); \
    oc_sri=$(jq -r '.opencode.binaryPackage.integrity' "$vj"); \
    oc_arch=$(jq -r '.opencode.arch' "$vj"); \
    test -n "$oc_ver" && test -n "$oc_sri"; \
    # versions.json uses Debian arch names (x86_64), npm uses x64/arm64. Only \
    # binaryPackage is verified: the meta package is just a postinstall script \
    # and the binary is self-contained (no nodejs). \
    case "$oc_arch" in \
      x86_64|amd64|x64) plat="opencode-linux-x64" ;; \
      aarch64|arm64) plat="opencode-linux-arm64" ;; \
      *) echo "unknown opencode.arch: '$oc_arch'" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl $CURL_OPTIONS -O "https://registry.npmjs.org/${plat}/-/${plat}-${oc_ver}.tgz"; \
    got=$(python3 -c 'import base64,hashlib,sys; print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1],"rb").read()).digest()).decode())' "${plat}-${oc_ver}.tgz"); \
    test "$got" = "$oc_sri" || { echo "opencode SRI mismatch"; echo "  expected $oc_sri"; echo "  got      $got"; exit 1; }; \
    tar -xzf "${plat}-${oc_ver}.tgz" package/bin/opencode; \
    install -m 0755 package/bin/opencode /usr/local/bin/opencode; \
    rm -rf package "${plat}-${oc_ver}.tgz"; \
    test "$(opencode --version)" = "${oc_ver}"

# ---------------------------------------------------------------------------
# 5) freecad-mcp: venv with hash pinning from the lockfile
#    /opt/uv/venvs/<name> is intentional: the drift scripts look for dist-info there.
# ---------------------------------------------------------------------------
RUN set -eux; \
    vj=/usr/local/share/freecad-devbox/versions.json; \
    mcp_ver=$(jq -r '.freecadMcp.version' "$vj"); \
    mcp_sha=$(jq -r '.freecadMcp.wheel.sha256' "$vj"); \
    lock=/opt/uv/requirements-freecad-mcp.lock; \
    test -n "$mcp_ver" && test -n "$mcp_sha"; \
    grep -q "^freecad-mcp==${mcp_ver} " "$lock" || { echo "lockfile does not pin freecad-mcp==${mcp_ver}" >&2; exit 1; }; \
    grep -qF "$mcp_sha" "$lock" || { echo "lockfile does not contain the wheel sha256 pin" >&2; exit 1; }; \
    \
    UV_CACHE_DIR=/tmp/uv-cache uv venv --python /usr/bin/python3 /opt/uv/venvs/freecad-mcp; \
    UV_CACHE_DIR=/tmp/uv-cache uv pip install --python /opt/uv/venvs/freecad-mcp/bin/python \
        --require-hashes -r "$lock"; \
    ln -sf /opt/uv/venvs/freecad-mcp/bin/freecad-mcp /usr/local/bin/freecad-mcp; \
    rm -rf /tmp/uv-cache; \
    \
    python3 -c 'import sys; assert sys.version_info >= (3, 12), sys.version; print("MCP-Python", sys.version.split()[0])'; \
    find /opt/uv/venvs/freecad-mcp -maxdepth 5 -type d -name "freecad_mcp-${mcp_ver}.dist-info" | grep -q . \
        || { echo "freecad_mcp ${mcp_ver} not in the venv" >&2; exit 1; }; \
    freecad-mcp --help >/dev/null; \
    if python3 -c 'import freecad_mcp' 2>/dev/null; then \
        echo "ERROR: freecad_mcp importable from system python (addon runs in FreeCAD python 3.11)" >&2; exit 1; \
    fi; \
    chmod -R a+rX /opt/uv/venvs

# ---------------------------------------------------------------------------
# 6) FreeCAD: download, verify, extract (no FUSE), build wrappers,
#    install MCP workbench + auto_start_rpc into both user dirs
# ---------------------------------------------------------------------------
RUN set -eux; \
    vj=/usr/local/share/freecad-devbox/versions.json; \
    fc_ver=$(jq -r '.freecad.version' "$vj"); \
    fc_sha=$(jq -r '.freecad.sha256' "$vj"); \
    fc_py=$(jq -r '.freecad.pythonTag' "$vj"); \
    fc_arch=$(jq -r '.freecad.arch' "$vj"); \
    test -n "$fc_ver" && test -n "$fc_sha" && test -n "$fc_py"; \
    case "$fc_arch" in \
      x86_64|aarch64) ;; \
      *) echo "unknown freecad.arch: '$fc_arch'" >&2; exit 1 ;; \
    esac; \
    asset="FreeCAD_${fc_ver}-Linux-${fc_arch}-${fc_py}.AppImage"; \
    base="https://github.com/FreeCAD/FreeCAD/releases/download/${fc_ver}"; \
    cd /tmp; \
    curl $CURL_OPTIONS -o "${asset}-SHA256.txt" "${base}/${asset}-SHA256.txt"; \
    test "$(grep -cvE '^[[:space:]]*(#|$)' "${asset}-SHA256.txt")" -eq 1 || { echo "sidecar: unexpected line count" >&2; exit 1; }; \
    grep -qF " ${asset}" "${asset}-SHA256.txt" || { echo "sidecar checksum does not belong to ${asset}" >&2; exit 1; }; \
    test "$(awk '{print $1; exit}' "${asset}-SHA256.txt")" = "$fc_sha" || { echo "Pin freecad.sha256 != Sidecar" >&2; exit 1; }; \
    curl $CURL_OPTIONS -o "${asset}" "${base}/${asset}"; \
    echo "${fc_sha}  ${asset}" | sha256sum -c -; \
    \
    dest="/opt/freecad/${fc_ver}"; \
    rm -rf "$dest"; \
    mkdir -p "$dest"; \
    cd "$dest"; \
    chmod +x "/tmp/${asset}"; \
    # --appimage-extract creates ./squashfs-root -> exactly the target layout \
    # /opt/freecad/<version>/squashfs-root. No FUSE, no /dev/fuse needed. \
    "/tmp/${asset}" --appimage-extract >/dev/null; \
    rm -f "/tmp/${asset}" "/tmp/${asset}-SHA256.txt"; \
    fc="$dest/squashfs-root"; \
    for p in usr/bin/freecad usr/bin/freecadcmd usr/lib usr/lib/qt6/plugins/platforms usr/ssl/cacert.pem; do \
        test -e "$fc/$p" || { echo "AppImage incomplete: $p missing" >&2; exit 1; }; \
    done; \
    chmod -R a+rX "$dest"; \
    \
    for bin in freecad freecadcmd; do \
        { \
            printf '%s\n' \
                '#!/bin/bash' \
                '# Generated at build time; mirrors the AppRun environment.' \
                'set -euo pipefail'; \
            printf 'FREECAD_ROOT="%s"\n' "$fc"; \
            printf '%s\n' \
                'export APPIMAGE_EXTRACT_AND_RUN=0' \
                'export FREECAD_ROOT' \
                'export PYTHONHOME="${FREECAD_ROOT}/usr"' \
                'export PATH_TO_FREECAD_LIBDIR="${FREECAD_ROOT}/usr/lib"' \
                'export LD_LIBRARY_PATH="${FREECAD_ROOT}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"' \
                'export QT_PLUGIN_PATH="${FREECAD_ROOT}/usr/lib/qt6/plugins${QT_PLUGIN_PATH:+:${QT_PLUGIN_PATH}}"' \
                'export QT_QPA_PLATFORM_PLUGIN_PATH="${FREECAD_ROOT}/usr/lib/qt6/plugins/platforms${QT_QPA_PLATFORM_PLUGIN_PATH:+:${QT_QPA_PLATFORM_PLUGIN_PATH}}"' \
                'export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"' \
                'export FONTCONFIG_FILE="${FONTCONFIG_FILE:-/etc/fonts/fonts.conf}"' \
                'export FONTCONFIG_PATH="${FONTCONFIG_PATH:-/etc/fonts}"' \
                'export SSL_CERT_FILE="${FREECAD_ROOT}/usr/ssl/cacert.pem"'; \
            printf 'exec "${FREECAD_ROOT}/usr/bin/%s" "$@"\n' "$bin"; \
        } > "/usr/local/bin/${bin}"; \
        chmod 0755 "/usr/local/bin/${bin}"; \
    done; \
    test "$(freecadcmd --version | head -n1 | awk '{print $2}')" = "${fc_ver}" \
        || { echo "freecadcmd reports a different version than pinned" >&2; exit 1; }; \
    \
    mcp_ver=$(jq -r '.freecadMcp.version' "$vj"); \
    mcp_sdist_sha=$(jq -r '.freecadMcp.sdist.sha256' "$vj"); \
    test -n "$mcp_sdist_sha"; \
    sdist_url=$(curl $CURL_OPTIONS "https://pypi.org/pypi/freecad-mcp/${mcp_ver}/json" \
        | jq -r '.urls[] | select(.packagetype == "sdist") | .url'); \
    test -n "$sdist_url" || { echo "no sdist for freecad-mcp ${mcp_ver}" >&2; exit 1; }; \
    cd /tmp; \
    curl $CURL_OPTIONS -o freecad-mcp-sdist.tar.gz "$sdist_url"; \
    echo "${mcp_sdist_sha}  freecad-mcp-sdist.tar.gz" | sha256sum -c -; \
    rm -rf /tmp/fcmcp && mkdir -p /tmp/fcmcp; \
    tar -xzf freecad-mcp-sdist.tar.gz -C /tmp/fcmcp --strip-components=1; \
    src="/tmp/fcmcp/addon/FreeCADMCP"; \
    test -f "$src/InitGui.py" || { echo "addon: InitGui.py missing" >&2; exit 1; }; \
    grep -q '<subdirectory>./</subdirectory>' "$src/package.xml" \
        || { echo "addon: package.xml without <subdirectory>./</subdirectory> - FreeCAD would load nothing" >&2; exit 1; }; \
    test "$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$src/package.xml" | head -n1)" = "${mcp_ver}" \
        || { echo "addon version != PyPI pin ${mcp_ver}" >&2; exit 1; }; \
    \
    printf '%s\n' \
        '{' \
        '  "remote_enabled": false,' \
        '  "allowed_ips": "127.0.0.1",' \
        '  "auto_start_rpc": true,' \
        '  "auth_token": ""' \
        '}' > /tmp/fdev-settings.json; \
    for u in "${USERNAME}" root; do \
        home=$(getent passwd "$u" | cut -d: -f6); \
        test -n "$home" || continue; \
        # Cover both layouts: FreeCAD 1.0 reads <base>/, 1.1 reads <base>/v1-1/. \
        for d in "$home/.local/share/FreeCAD" "$home/.local/share/FreeCAD/v1-1"; do \
            mkdir -p "$d/Mod"; \
            rm -rf "$d/Mod/FreeCADMCP"; \
            cp -R "$src" "$d/Mod/FreeCADMCP"; \
            cp /tmp/fdev-settings.json "$d/freecad_mcp_settings.json"; \
        done; \
        chown -R "${u}:${u}" "$home/.local" 2>/dev/null || true; \
    done; \
    rm -rf /tmp/fcmcp /tmp/freecad-mcp-sdist.tar.gz /tmp/fdev-settings.json

# ---------------------------------------------------------------------------
# 6b) Workbench addons (airframe + 3D-print toolchain)
#
#     Driven by .addons[] in versions.json. Git is the transport, so the pin is
#     a full commit SHA rather than a tag: tags move, commits do not. Each entry
#     is fetched at depth 1 and then verified twice - `git rev-parse HEAD` must
#     equal the pinned ref, and the <version> in the addon's own package.xml must
#     equal the pinned packageVersion. The second check catches the case a ref
#     check alone cannot: a repo that moved the pinned version to different code.
#
#     Installed into every candidate user dir (vscode + root, 1.0 and 1.1 layouts),
#     the same loop as the MCP addon above, because FreeCAD's user dir moved in
#     1.1 and guessing wrong means "workbench silently missing".
#
#     .git is stripped after the checkout: the ref is already recorded in
#     versions.json, and keeping it would leave 7 nested repos in the image.
#
#     Curves needs numpy+scipy and Rocket needs FreeCAD 1.0+; both hold for the
#     pinned FreeCAD, and step 8 proves it by importing the probes.
# ---------------------------------------------------------------------------
RUN set -eux; \
    vj=/usr/local/share/freecad-devbox/versions.json; \
    jq -e '.addons | type == "array" and length > 0' "$vj" >/dev/null \
        || { echo "versions.json: .addons missing or empty" >&2; exit 1; }; \
    n=$(jq '.addons | length' "$vj"); \
    i=0; \
    while [ "$i" -lt "$n" ]; do \
        name=$(jq -r ".addons[$i].name" "$vj"); \
        repo=$(jq -r ".addons[$i].repo" "$vj"); \
        ref=$(jq -r ".addons[$i].ref" "$vj"); \
        mod=$(jq -r ".addons[$i].modDir" "$vj"); \
        pver=$(jq -r ".addons[$i].packageVersion" "$vj"); \
        i=$((i + 1)); \
        printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$' \
            || { echo "addon $name: ref is not a 40-hex commit SHA: '$ref'" >&2; exit 1; }; \
        printf '%s\n' "$repo" | grep -Eq '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
            || { echo "addon $name: repo is not a plain github.com URL: '$repo'" >&2; exit 1; }; \
        printf '%s\n' "$mod" | grep -Eq '^[A-Za-z0-9._-]+$' \
            || { echo "addon $name: modDir is not a safe directory name: '$mod'" >&2; exit 1; }; \
        \
        src="/tmp/addon-$mod"; \
        rm -rf "$src"; mkdir -p "$src"; cd "$src"; \
        git init -q .; \
        git remote add origin "$repo"; \
        git fetch -q --depth 1 origin "$ref"; \
        git checkout -q --detach FETCH_HEAD; \
        got=$(git rev-parse HEAD); \
        test "$got" = "$ref" \
            || { echo "addon $name: fetched $got but versions.json pins $ref" >&2; exit 1; }; \
        test -f package.xml \
            || { echo "addon $name: no package.xml at $ref - not a FreeCAD addon" >&2; exit 1; }; \
        got_ver=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' package.xml | head -n1); \
        test "$got_ver" = "$pver" \
            || { echo "addon $name: package.xml says version $got_ver, versions.json pins $pver" >&2; exit 1; }; \
        rm -rf .git; \
        \
        for u in "${USERNAME}" root; do \
            home=$(getent passwd "$u" | cut -d: -f6); \
            test -n "$home" || continue; \
            for d in "$home/.local/share/FreeCAD" "$home/.local/share/FreeCAD/v1-1"; do \
                mkdir -p "$d/Mod"; \
                rm -rf "$d/Mod/$mod"; \
                cp -R "$src" "$d/Mod/$mod"; \
            done; \
            chown -R "${u}:${u}" "$home/.local" 2>/dev/null || true; \
        done; \
        \
        cd /tmp; rm -rf "$src"; \
        printf 'addon %-16s %-14s %s\n' "$name" "$pver" "$(printf '%s' "$ref" | cut -c1-12)"; \
    done; \
    rm -rf /tmp/addon-*

# ---------------------------------------------------------------------------
# 7) zsh config for the user
# ---------------------------------------------------------------------------
RUN set -eux; \
    home=$(getent passwd "${USERNAME}" | cut -d: -f6); \
    printf '%s\n' \
        '# FreeCAD DevBox' \
        'HISTFILE="${HOME}/.zsh_history"' \
        'HISTSIZE=50000' \
        'SAVEHIST=50000' \
        'setopt HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS' \
        'alias l="ls -lah"' \
        'alias ll="ls -lah"' \
        'alias ..="cd .."' \
        'alias freecad-devbox="entrypoint.sh"' \
        '' \
        '# X server + GUI:   start-freecad-gui.sh   (noVNC on http://localhost:6080)' \
        '# console only:     start-freecad.sh --env-only -- freecadcmd -c "print(1)"' \
        '# versions + pins:  show-tool-versions.sh / show-tool-locations.sh' \
        > "${home}/.zshrc"; \
    chown "${USER_UID}:${USER_GID}" "${home}/.zshrc"

# ---------------------------------------------------------------------------
# 8) Smoke test: everything the container starts must actually start
#
#    The addon probe loop is the interesting one. It imports each `probe` module
#    from versions.json by name, which is the check that would have caught
#    AirPlaneDesign failing to load because CurvedShapes was missing. Addons with
#    probe=null are GUI-only (their modules construct QWidgets and abort
#    freecadcmd); for those we only assert the Mod directory is present.
# ---------------------------------------------------------------------------
RUN set -eux; \
    freecadcmd --version | head -n1; \
    freecadcmd -c 'import FreeCAD, Part; assert Part.makeBox(1, 1, 1).Volume > 0; print("FreeCAD headless OK")'; \
    opencode --version; \
    uv --version; \
    uvx --version; \
    freecad-mcp --help >/dev/null; \
    entrypoint.sh --help >/dev/null; \
    for t in freecad freecadcmd opencode uv uvx Xvfb x11vnc fluxbox websockify python3 jq; do \
        command -v "$t" >/dev/null || { echo "$t not in PATH" >&2; exit 1; }; \
    done; \
    \
    vj=/usr/local/share/freecad-devbox/versions.json; \
    jq -r '.addons[] | [.name, .modDir, (.probe // "")] | @tsv' "$vj" > /tmp/probe.tsv; \
    n_probe=0; n_legacy=0; \
    for u in "${USERNAME}" root; do \
        home=$(getent passwd "$u" | cut -d: -f6); \
        test -n "$home" || continue; \
        legacy="$home/.local/share/FreeCAD/Mod"; \
        current="$home/.local/share/FreeCAD/v1-1/Mod"; \
        # FreeCAD >= 1.1 only ever reads v1-1; the legacy dir exists purely so an
        # older FreeCAD would still find the addons. Probing it would prove
        # nothing about the pinned version, so only assert that it is populated.
        test -d "$legacy" || { echo "$u: no legacy Mod dir $legacy" >&2; exit 1; }; \
        n_legacy=$((n_legacy + 1)); \
        # XDG_DATA_HOME is how FreeCAD locates its user dir, so pointing it at
        # .../.local/share makes the probe import through the same sys.path
        # FreeCAD builds at startup rather than a hand-rolled sys.path.insert.
        xdg=$(dirname "$(dirname "$(dirname "$current")")"); \
        while IFS="$(printf '\t')" read -r name mod probe; do \
            test -d "$legacy/$mod" \
                || { echo "addon $name: $legacy/$mod missing" >&2; exit 1; }; \
            if [ "$u" = "${USERNAME}" ]; then \
                test -d "$current/$mod" \
                    || { echo "addon $name: $current/$mod missing" >&2; exit 1; }; \
                if [ -n "$probe" ]; then \
                    XDG_DATA_HOME="$xdg" PROBE="$probe" freecadcmd -c \
                        'import os, sys; __import__(os.environ["PROBE"]); print("probe ok:", os.environ["PROBE"])' \
                        || { echo "addon $name: probe import of $probe failed" >&2; exit 1; }; \
                    n_probe=$((n_probe + 1)); \
                fi; \
                printf 'verified %-16s %-16s %s\n' "$name" "$mod" "${probe:-<gui-only>}"; \
            fi; \
        done < /tmp/probe.tsv; \
    done; \
    rm -f /tmp/probe.tsv; \
    test "$n_probe" -gt 0 \
        || { echo "no addon had a probe - the check would pass vacuously" >&2; exit 1; }; \
    test "$n_legacy" -ge 1 \
        || { echo "legacy Mod dir check never ran" >&2; exit 1; }

LABEL org.opencontainers.image.title="FreeCAD DevBox (Debian ${DEBIAN_VERSION} ${DEBIAN_VERSION_NAME})" \
      org.opencontainers.image.description="FreeCAD + freecad-mcp + opencode, preconfigured. Component versions are pinned in /usr/local/share/freecad-devbox/versions.json" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/debian:${DEBIAN_VERSION_NAME}-slim"

# FREECAD_HOME is deliberately not an ENV: it tracks the pinned version, which
# is only read from versions.json at build time. The wrappers export their own
# FREECAD_ROOT and the runtime scripts resolve it; a literal here would be a
# second pin that can drift.

WORKDIR /workspaces
USER ${USERNAME}

# 9875 = addon XML-RPC, 5900 = VNC, 6080 = noVNC
EXPOSE 9875 5900 6080

# Health: the RPC server should answer. FreeCAD not running is not a failure -
# the container is a shell, not a long-running service.
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD freecad-mcp-healthcheck.sh --quiet \
        || (pgrep -x freecad >/dev/null 2>&1 && exit 1 || exit 0)

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh", "-l"]