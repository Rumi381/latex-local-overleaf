# latex-local-overleaf

Portable, toolkit-native launcher for running Overleaf Community Edition locally with a single `work` command.

## Why this repo

Use this if you want:
- A local Overleaf CE environment you can run quickly on any Docker-enabled machine.
- A reproducible startup flow (`work start`) instead of manual toolkit steps.
- Practical TeX hardening for projects that need broader package coverage.

This repo is **not**:
- A cloud sync service across machines.
- A drop-in replacement for all overleaf.com hosted features.
- A filesystem mirror where browser edits are continuously written to normal project folders.

## Clone and Start

Clone with submodules (recommended):

```bash
git clone --recurse-submodules https://github.com/Rumi381/latex-local-overleaf.git
cd latex-local-overleaf
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

## Quick Start (60 seconds)

1. Open a terminal at the repo root.
2. Start the stack:

Windows:
```powershell
.\work.cmd start
```

Linux/macOS:
```bash
./work start
```

3. Wait for `Overleaf is ready` and open:
- `http://localhost:8080/launchpad`
4. On first run with fresh local state, register the first account (email + password).
   - This first account becomes the local admin user.
   - You only see this setup step on a fresh instance (for example, new machine or cleared Docker volumes).

First start can take significantly longer because the local hardened TeX image may be built.

## Platform Prerequisites

### Windows

- Docker Desktop running
- Git
- WSL with bash available
- Use `work.cmd` / `work.ps1` entrypoints

### Linux

- Docker + Docker Compose plugin
- Git
- Bash
- Use `./work`

### macOS (Supported but not tested)

- Docker Desktop running
- Git
- Bash
- Use `./work`

macOS is supported by the current script path, but this repo is not yet CI-validated on macOS.

## Command Guide

Use `work` directly on Linux/macOS and `work.cmd` on Windows.

| Command | When to use | Why / expected outcome | Typical example |
|---|---|---|---|
| `start` | Begin or resume editing session | Ensures config/image baseline, starts services, waits for UI | `./work start` |
| `stop` | Pause local stack | Stops Overleaf containers cleanly | `./work stop` |
| `restart` | Services are running but unstable | Restarts compose services without full teardown | `./work restart` |
| `status` | Verify runtime health | Shows service states and UI reachability check | `./work status` |
| `logs [args...]` | Diagnose compile/runtime issues | Tails toolkit-managed logs (`web`, `clsi` by default) | `./work logs -n 200 web clsi` |
| `doctor` | Environment sanity check | Runs toolkit diagnostics for dependencies/config | `./work doctor` |
| `self-check` | Confirm repo config + image baseline | Prints pin/config/runtime checks including TeX baseline validity | `./work self-check` |
| `toolkit update <ref>` | Intentionally move toolkit version pin | Checks out toolkit at chosen ref and updates local pin | `./work toolkit update <ref>` |
| `tex install <package...>` | You know missing TeX package names | Installs packages into hardened image and recreates sharelatex container | `./work tex install rsfs` |
| `tex install-missing <file...>` | Error shows missing TeX file names | Resolves files to packages, installs them, recreates sharelatex container | `./work tex install-missing rsfs10.tfm` |
| `images prune` | Free disk used by stale ShareLaTeX tags | Removes unused `sharelatex/sharelatex:*` tags per config policy | `./work images prune` |

## Project Workflow

### Start new project

- Open Overleaf UI (`/launchpad`) and create a blank project.

### Upload an existing project

- Upload a ZIP from **any folder** on your machine through the Overleaf UI.
- No repo-specific staging folder is required.

### Daily use

- Start: `work start`
- Work in browser UI
- Stop when done: `work stop`

## Where Projects Are Stored

Overleaf project state is stored in local Docker volumes on each machine:
- `overleaf-data`
- `mongo-data`
- `redis-data`

Implications:
- Restart persistence: **Yes** (projects remain after stop/start).
- Cross-machine auto-sync: **No** (each machine has its own local state).

## TeX Package Strategy

- Default baseline is hardened to `scheme-full` (configured in `work.config`).
- True in-compile auto-install is intentionally disabled for reproducibility and stability.
- Recommended recovery flow for missing-file errors:
  1. Copy missing file name from compile log.
  2. Run `work tex install-missing <file>`.
  3. Recompile.

## Configuration (work.config)

Primary settings:
- `TOOLKIT_PATH`, `TOOLKIT_REPO`, `TOOLKIT_REF`
- `OVERLEAF_HOST`, `OVERLEAF_PORT`
- `OVERLEAF_APP_NAME` (UI branding title, default `Overleaf`)
- `BASE_OVERLEAF_IMAGE_TAG`, `OVERLEAF_IMAGE_TAG`
- `TEXLIVE_PACKAGES`, `TEXLIVE_REQUIRED_SCHEME`, `TEXLIVE_CHECK_FILES`
- `AUTO_PRUNE_SHARELATEX_IMAGES` (`1` default)
- `KEEP_BASE_OVERLEAF_IMAGE` (`0` default)

## Troubleshooting FAQ

### Why can local behavior differ from overleaf.com?

Local CE runs with your local image and configuration. overleaf.com uses a managed hosted environment that may have different package/runtime coverage and service settings.

### What should I do when compile says a file/package is missing?

Use:
- `work tex install-missing <missing-file>` (preferred)
- or `work tex install <package>` if you already know the package name.

Then recompile.

### Why do multiple `sharelatex/sharelatex` images sometimes appear?

One tag is the active runtime image; others can be base/legacy tags from previous hardening cycles. Use `work images prune` to clean extras. Auto-pruning is enabled by default.

### `Toolkit is not a git checkout and has CRLF scripts` on Windows clone

This usually indicates a broken toolkit checkout state from line-ending conversion or partial submodule init.

Use:
- `git submodule update --init --recursive`
- then run `work start` again

Current `work` logic is submodule-safe and auto-heals common CRLF checkout issues.
If recovery is still needed manually, run:
- `wsl -e bash -lc "cd /mnt/<drive>/<path>/overleaf-toolkit && git config core.autocrlf false && git config core.eol lf && git reset --hard && git clean -fd"`

### Why do I sometimes see TeX Live frozen warnings (`ipaex`, `TLPDB.pm`)?

The internal baseline checks now suppress non-fatal `tlmgr info` warning noise in normal `work` flows.
Real compile failures are still shown in Overleaf UI and `work logs`.

## Roadmap (Future Goals, Not Implemented Yet)

- Optional sync workflows for moving project state between machines.
- Centralized self-hosted mode with multi-user account management.
- Stronger ops/security hardening guidance for broader team deployments.
- Better backup/restore ergonomics for local Overleaf state.

## Contributing

Contributions are welcome via issues and pull requests.

High-value contributions:
- Cross-platform validation (especially macOS test confirmation).
- Improvements to portability, observability, and recovery ergonomics.
- Well-scoped proposals for roadmap items with clear tradeoffs.

When proposing new features, include:
- user problem,
- expected workflow,
- operational impact,
- rollback/failure considerations.

## License

This repository is licensed under the GNU Affero General Public License v3.0.
See [`LICENSE`](LICENSE).
