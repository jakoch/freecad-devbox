# Changelog

All changes to the project will be documented in this file.

- The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
- The date format is YYYY-MM-DD.
- The upcoming release version is named `vNext` and links to the changes between latest version tag and git HEAD.

## [vNext] - unreleased

## [0.1.0] - 2026-10-07

Initial release. Container images for FreeCAD with freecad-mcp and opencode
preinstalled, plus a set of workbench addons.

### Added

- images for three Debian bases, all resolving every component from the same
  `.devcontainer/versions.json`:
  - `.devcontainer/debian/13-trixie` — Debian 13, the supported default
  - `.devcontainer/debian/sid-unstable` — rolling release, `continue-on-error` in CI
  - `.devcontainer/debian/14-forky` — Debian 14 *testing*, no release date yet
    (expected 2027). Only `debian:forky-slim` is published on Docker Hub;
    `debian:14-forky-slim` does not exist yet.
- workbench addons, installed into every candidate user directory because
  FreeCAD moved its user directory in 1.1:
  - CurvedShapes — NURBS surface from 2D curves
  - Curves — NURBS curves and surfaces, lofting and skinning
  - AirPlaneDesign — parametric panels, ribs and nacelles
  - SheetMetal — bend allowances and flat-pattern unfolding
  - Rocket — nose cones, body tubes, filleted transitions
  - Vars — first-class document variables with decoupled dependencies
  - CarteGrid — batch-export a parameter grid from an `App::VarSet`
- `.gitignore`, excluding two unmaintained local Dockerfile experiments
- cspell dictionary entries for the addon and Debian codename names

### Changed

- pins live in `.devcontainer/versions.json` and are verified at build time:
  FreeCAD, uv and opencode by SHA256 or SRI, freecad-mcp by wheel and sdist
  hash, each workbench addon by full commit SHA
- workbench addons are verified twice on install: `git rev-parse HEAD` must
  equal the pinned commit, and the addon's own `package.xml` version must
  equal the pinned `packageVersion`
- the Dockerfile smoke test imports each addon's probe module, which is the
  check that catches a workbench whose dependency is missing
- `release.yml` adapted from cpp-devbox to this repository:
  - collapsed to one image per matrix leg
  - removed the Vulkan SDK variant and both build stages, which do not exist here
  - removed the aggregate step and the `publish-docs` job, which referenced
    a `website/` directory and `build-tools/` scripts absent from this repo
  - replaced the missing `devbox-test/build.sh` with a drift check, a geometry
    check and the addon probes, run against the built image
  - retained the codename tag prefix, so the three matrix legs do not collide
    on `latest` and on semver tags
  - build failures on the `sid` and `forky` legs are non-fatal
- `dependabot.yml`: the docker ecosystem pointed at `./devcontainer`, which
  does not exist, so it had never matched anything. Now lists each Dockerfile
  directory. Its docker ecosystem only reads Dockerfiles at the root of the
  given directory, hence one entry per variant.
- `README.md`: documents the three images and their support status
- `devcontainer.json`: lists the two experimental Dockerfiles

### Fixed

- `release.yml` called `show-tool-versions.sh json`; the script takes
  `-f json` and rejected the positional argument. The runtime scripts are
  already on `PATH` via `/usr/local/bin`, so no bind mount is needed at all
- `release.yml` mounted `.devcontainer/scripts`, but the scripts live in
  `.devcontainer/scripts/runtime`
- Dockerfile progress output used `${ref:0:12}`, a bashism. `RUN` uses
  `/bin/sh`, which is dash on Debian, and it aborted the build

<!-- Section for Reference Links -->

[vNext]: https://github.com/jakoch/freecad-devbox/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jakoch/freecad-devbox/releases/tag/v0.1.0
