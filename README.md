# FreeCAD DevBox [![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/jakoch/freecad-devbox/release.yml?branch=main&style=flat&logo=github&label=Image%20published%20on%20GHCR)](https://github.com/jakoch/freecad-devbox)

A Docker-based development container for [FreeCAD CAD][freecad_website] with
[freecad-mcp][freecad_mcp] and [opencode][opencode_website] preinstalled, so a
running FreeCAD session can be steered from the command line.

It is designed especially for use with Visual Studio Code or any IDE
that supports the devcontainer standard. The images can also be used in CI workflows.

> **Quick Reference:** [Releases & tool versions](https://github.com/jakoch/freecad-devbox/releases) · [DockerHub](https://hub.docker.com/r/jakoch/freecad-devbox) · [GHCR](https://github.com/jakoch/freecad-devbox/pkgs/container/freecad-devbox) · [Changelog](CHANGELOG.md)

## Purpose

freecad-devbox provides a portable, standardized container with a ready-to-use
FreeCAD environment for parametric CAD.

The image bundles FreeCAD itself (as an extracted AppImage, no FUSE needed), an
MCP server that exposes a running FreeCAD session to the command line, and
opencode as its client. On top of that sits a curated set of FreeCAD workbench
addons for surfaces, sheet metal and print-optimized geometry.

Python can be executed inside the live FreeCAD session, so a model can be built,
measured, varied across a parameter grid and exported to STL without touching
the GUI.

The goal is an agent-driven parametric modelling environment: an AI agent works
against that live session to build, measure and export the model, while the GUI
stays available for inspection and for work that is done by hand.

## Available Images

[trixie-latest]:   https://ghcr.io/jakoch/freecad-devbox:trixie-latest
[unstable-latest]: https://ghcr.io/jakoch/freecad-devbox:unstable-latest
[forky-latest]:    https://ghcr.io/jakoch/freecad-devbox:forky-latest

| ⭣ Tag &nbsp;&nbsp; OS ⭢  | Debian 13 - Trixie | Debian sid - Unstable | Debian 14 - Forky |
|--------------------------|--------------------|------------------------|-------------------|
| Latest | [trixie-latest] <br> ![trixie-latest](https://ghcr-badge.egpl.dev/jakoch/freecad-devbox/size?color=%2344cc11&tag=trixie-latest&label=image+size) | [unstable-latest] <br> ![unstable-latest](https://ghcr-badge.egpl.dev/jakoch/freecad-devbox/size?color=%2344cc11&tag=unstable-latest&label=image+size) | [forky-latest] <br> ![forky-latest](https://ghcr-badge.egpl.dev/jakoch/freecad-devbox/size?color=%2344cc11&tag=forky-latest&label=image+size) |
| Support | stable, recommended | rolling, may break | testing, may break |
| Dockerfile | [13-trixie][trixie_dockerfile] | [sid-unstable][sid_dockerfile] | [14-forky][forky_dockerfile] |

**Trixie is the supported default.** The `sid` and `forky` legs exist to test the
images against newer package trees; both roll continuously, so a build may fail
without notice. Their CI failures are marked non-fatal. Debian 14 "forky" is
still *testing* and has no release date yet (expected 2027), which is why only
`debian:forky-slim` is published on Docker Hub and `debian:14-forky-slim` does
not exist.

All three images resolve every component from the same
[`.devcontainer/versions.json`](.devcontainer/versions.json), so they differ
only in the Debian base image.

You find the [versioning scheme for images below](#versioning-scheme-for-images).

## What is pre-installed?

Base: Debian 13 - Trixie

- **FreeCAD 1.1.4** — extracted AppImage at `/opt/freecad/1.1.4`, with
  `freecad` and `freecadcmd` wrappers on `PATH`
- **freecad-mcp 0.1.25** — MCP server plus the `FreeCADMCP` workbench, which
  auto-starts an XML-RPC server on `127.0.0.1:9875`
- **opencode 1.18.35** — command-line tool that drives FreeCAD over MCP
- **uv 0.12.23** — Python package manager
- **zsh, git, jq, ripgrep, fd, nano, build-essential**, Python 3
- **Xvfb, x11vnc, noVNC, fluxbox** — headless GUI with software rendering

### Workbench addons

Installed from pinned commits, verified against the addon's own `package.xml`:

| Addon | Version | Description |
|-------|---------|-------------|
| [CurvedShapes](https://github.com/chbergmann/CurvedShapesWorkbench) | 1.00.15 | NURBS surface from 2D curves |
| [Curves](https://github.com/tomate44/CurvesWB) | 0.6.81 | NURBS curves and surfaces, lofting and skinning |
| [AirPlaneDesign](https://github.com/FredsFactory/FreeCAD_AirPlaneDesign) | 0.4.1 | parametric panels, ribs and nacelles |
| [SheetMetal](https://github.com/shaise/FreeCAD_SheetMetal) | 0.8.24 | bend allowances and flat-pattern unfolding |
| [Rocket](https://github.com/davesrocketshop/Rocket) | 5.1.3 | nose cones, body tubes, filleted transitions |
| [Vars](https://github.com/mnesarco/Vars) | 0.0.2.beta7 | first-class document variables with decoupled dependencies |
| [CarteGrid](https://github.com/MarcBresson/CarteGrid) | 1.3.1 | batch-export a parameter grid from an `App::VarSet` |

CurvedShapes is a hard dependency of AirPlaneDesign, which imports it at module
level. Upstream labels AirPlaneDesign and Curves as experimental.

Every version above is pinned in [`.devcontainer/versions.json`](.devcontainer/versions.json)
and re-verified on each build. Inside the image:

```bash
show-tool-versions.sh          # expected vs installed, per component
compare-versions.sh --strict   # exit 1 on any drift
show-checksums.sh              # hashes of every build-verified artifact
show-tool-locations.sh         # where each tool lives
```

## Prerequisites

You need the following things to run this:

- Docker
- Visual Studio Code

## How to run this?

There are two ways of setting the container up.

Either by building the container image locally or by fetching the prebuilt container image from a container registry.

### Building the Container Image locally using VSCode

- **Step 1.** Get the source: clone this repository using git or download the zip

- **Step 2. (optional)** The repository contains multiple images.

  You select an image by modifying the `dockerfile` field in
  `.devcontainer/devcontainer.json`:

  By default `"./debian/13-trixie/Dockerfile"` is set.

  For an experimental image:
  - Debian sid set `./debian/sid-unstable/Dockerfile`
  - Debian 14 testing set `./debian/14-forky/Dockerfile`

- **Step 3.** In VSCode open the folder in a container (`Remote Containers: Open Folder in Container`):

   This will build the container image (`Starting Dev Container (show log): Building image..`)

   Which takes a while...

   Then, finally...

- **Step 4.**  Enjoy! :sunglasses:

### Fetching the prebuilt container images using Docker

This container image is published to the Github Container Registry (GHCR) and the Docker Hub (hub.docker.com).

You may find the Docker Hub repository here: https://hub.docker.com/r/jakoch/freecad-devbox

You may find the GHCR package here: https://github.com/jakoch/freecad-devbox/pkgs/container/freecad-devbox

In order to pull from GHCR add the prefix (`ghcr.io/`).

**Command Line**

You can install the container image from the command line:

```bash
docker pull ghcr.io/jakoch/freecad-devbox:trixie-latest
```

```bash
docker pull jakoch/freecad-devbox:trixie-latest
```

The other two images use the Debian codename in the tag:

```bash
docker pull ghcr.io/jakoch/freecad-devbox:unstable-latest   # Debian sid
docker pull ghcr.io/jakoch/freecad-devbox:forky-latest      # Debian 14, testing
```

**Dockerfile**

You might also use this container image as a base image in your own `Dockerfile`:

```bash
FROM ghcr.io/jakoch/freecad-devbox:trixie-latest
```

**Running the container**

The image ships a headless X server, so the FreeCAD GUI needs no display on the
host. For console-only work, skip the GUI entirely:

```bash
docker run --rm -it ghcr.io/jakoch/freecad-devbox:trixie-latest \
  /bin/zsh -c 'freecadcmd -c "print(App.Version())"'
```

For the GUI and opencode, see the two sections below.

### How to start FreeCAD and reach it through the browser?

The container's entrypoint is a **shell**. It prints the steps below and hands
you a prompt, but it does not start FreeCAD for you — a container is not a
long-running service. Start the desktop yourself.

**Step 1.** Start the container:

```bash
docker run --rm -it -p 6080:6080 ghcr.io/jakoch/freecad-devbox:trixie-latest
```

You land in a `zsh` prompt. The entrypoint has already verified the pins and
listed every tool location.

**Step 2.** Start the FreeCAD desktop, detached, so you get your prompt back:

```bash
start-freecad-gui.sh --detach
```

That brings up, in order: Xvfb on `:99` at 1920x1080x24 with llvmpipe software
rendering, the fluxbox window manager, the FreeCAD GUI, x11vnc on `5900`, and
noVNC on `6080`. A window manager is not optional — without one, dialogs end up
off-screen and appear to have vanished.

**Step 3.** Wait for the MCP RPC server, then open FreeCAD in a browser:

```bash
freecad-mcp-healthcheck.sh --wait 120
```

```
http://localhost:6080/vnc.html
```

The browser connects to noVNC, which forwards to x11vnc and the X display. You
are looking at the real FreeCAD GUI running inside the container; you can open
and save files there.

`--detach` returns before the RPC server is up, which is why step 3 waits for it
explicitly. Drop `--detach` and `start-freecad-gui.sh` stays in the foreground,
waits for the RPC server itself, and tells you when it is reachable.

Useful flags, all forwarded to `start-freecad.sh`:

```bash
start-freecad-gui.sh --help                # every option
start-freecad.sh --display :77            # different X display
start-freecad.sh --screen 1600x1200x24    # different resolution
start-freecad.sh --env-only -- freecadcmd -c 'print(App.Version())'
tail -f /tmp/freecad.log                   # FreeCAD's own log
```

If you only want a console, skip the GUI entirely:

```bash
docker run --rm -it ghcr.io/jakoch/freecad-devbox:trixie-latest \
  /bin/zsh -c 'freecadcmd -c "print(App.Version())"'
```

#### A note on the VNC ports

x11vnc runs with `-nopw`, i.e. **without a password**. Do not publish `5900` to
anything but localhost. To require a password, set `VNC_PASSWORD_FILE` to an
`x11vnc -rfbauth` file, which replaces `-nopw`.

Port `5900` is only needed for a native VNC client; `6080` (noVNC) is enough for
a browser.

### How to access opencode and steer FreeCAD with it?

opencode reaches the running FreeCAD through the **freecad-mcp** server, which
the addon auto-starts on `127.0.0.1:9875` once the GUI is up. Both share the
container, so no port needs to be published.

**Step 1.** Start the desktop as above (`start-freecad-gui.sh --detach`, then
`freecad-mcp-healthcheck.sh --wait 120`). opencode cannot connect until FreeCAD
is running and the RPC server answers.

**Step 2.** Check the wiring:

```bash
opencode mcp list
```

The `freecad` server should be listed as connected. If it is not, the RPC server
is not up yet — wait, or look at `tail -f /tmp/freecad.log`.

**Step 3.** Start opencode:

```bash
opencode
```

**Step 4.** Ask for something. It inspects the model before changing it:

> Open the document `wing.FCStd` and tell me the wing area and the aspect ratio.

> Model a 250 mm motor pod: a Rocket nose cone, 4 mm wall, with a flat base,
> and add two M3 mounting bosses 22 mm apart.

> Import the `NACA2412` profile from the UIUC database, scale it to a 180 mm
> chord and loft it into a symmetric wing panel with 2° dihedral.

The image ships a `cad-operator` preset with a FreeCAD-specific workflow:
inspect first, name every object up front, build PartDesign-first, constrain
every sketch, verify each step, and end with a real measurement rather than the
value that was requested.

#### What opencode can call

The MCP server exposes the FreeCAD session directly:

| Tool | Purpose |
|------|---------|
| `list_documents`, `get_objects`, `get_object` | inspect the open model |
| `create_document`, `create_object`, `edit_object`, `delete_object` | mutate it |
| `execute_code` | run Python in the live FreeCAD session |
| `execute_code_async`, `get_async_status` | long parametric rebuilds, without blocking |
| `execute_code_headless` | heavy pure geometry in a separate `freecadcmd` process |
| `get_view` | screenshot of the 3D view |
| `insert_part_from_library`, `get_parts_list` | standard fasteners |
| `run_fem_analysis` | FEM |
| `reload_document` | show a `.FCStd` that was rebuilt elsewhere |

For parametric edits, prefer `execute_code` over the typed tools: it can drive
expressions and recomputes, which `edit_object` does not model. Use
`execute_code_headless` for lofts, helices and big booleans — an OpenCascade
crash there only kills the helper process, not your GUI session and open
documents.

`execute_code` runs arbitrary Python with your privileges inside the container.
It has no sandbox on the bridge side.

#### Reaching FreeCAD from outside the container

`opencode` on the host cannot reach a container-local port. Two ways out:

**Publish the RPC port.** Add `-p 9875:9875`. Then point an MCP client at
`http://127.0.0.1:9875` and set `"remote_enabled": true` in
`~/.local/share/FreeCAD/freecad_mcp_settings.json`.

> ⚠️ **This is arbitrary code execution on your machine.** The default is
> `remote_enabled: false`, and with `remote_enabled: true` and an empty
> `auth_token`, *any* client that reaches port 9875 can run Python as your user.
> The entrypoint warns about exactly this at startup. Either keep the port on
> localhost, or set an `auth_token` in the settings file and export
> `FREECAD_MCP_TOKEN` in the client.

**Or keep it in the container.** Run opencode inside the container instead:

```bash
docker run --rm -it -p 6080:6080 ghcr.io/jakoch/freecad-devbox:trixie-latest \
  /bin/zsh -c 'start-freecad-gui.sh --detach && freecad-mcp-healthcheck.sh --wait 120 && opencode'
```

No port to publish, no auth token to manage. The opencode config is written on
first start and never overwritten, so your edits survive restarts.

### Fetching the prebuilt container images using a .devcontainer config

**Devcontainer.json**

You might use this container image in the `.devcontainer/devcontainer.json` file of your project:

```json
{
  "name": "My FreeCAD DevBox",
  "image": "ghcr.io/jakoch/freecad-devbox:trixie-latest"
}
```

### Notes for usage in CI/CD pipelines and .devcontainer configs

When using a rolling tag (e.g. `trixie-latest`), the build will always use the
most recent version of that image. As a result, included software may change
over time, which can introduce unexpected build failures.

To ensure stability and reproducibility, pin to a fixed release (e.g.
`trixie-1.0.0`) if bleeding-edge updates are not required.

#### Developer Notes

### Versioning Scheme for Images

The base URL for GHCR.io is: `ghcr.io/jakoch/freecad-devbox:{tag}`.

#### Scheduled Builds

The following container tags are created for scheduled builds:

- `ghcr.io/jakoch/freecad-devbox:{debian_codename}-{date}`

#### For git tag

The following container tags are created for git tags:

- `ghcr.io/jakoch/freecad-devbox:{debian_codename}-{{ version }}`
- `ghcr.io/jakoch/freecad-devbox:{debian_codename}-{{ major }}.{{ minor }}`

#### Latest

The container tag "latest" is applied to the latest build:

- `ghcr.io/jakoch/freecad-devbox:{debian_codename}-latest`

The codename is part of the tag, so the three Debian bases never collide on
`latest`.

### Building an image by hand

```bash
docker build -f .devcontainer/debian/13-trixie/Dockerfile -t freecad-devbox:trixie .
```

### License

- Open Source: MIT License.
- Copyright: Jens A. Koch and contributors.

<!-- Section for Reference Links -->

[freecad_website]: https://www.freecad.org/
[freecad_mcp]: https://github.com/neka-nat/freecad-mcp
[opencode_website]: https://opencode.ai/
[trixie_dockerfile]: https://github.com/jakoch/freecad-devbox/blob/main/.devcontainer/debian/13-trixie/Dockerfile
[sid_dockerfile]: https://github.com/jakoch/freecad-devbox/blob/main/.devcontainer/debian/sid-unstable/Dockerfile
[forky_dockerfile]: https://github.com/jakoch/freecad-devbox/blob/main/.devcontainer/debian/14-forky/Dockerfile
