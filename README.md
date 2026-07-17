# AtomicDEX Legacy Builder

> [!WARNING]
> This project is in a **very early first release** state.
> Tested paths: Linux, macOS Intel/x86_64, native macOS arm64 / Apple Silicon, and Windows.
> Native macOS arm64 builds run with the QtWebEngine-dependent chart/price widget disabled.
> Deterministic / reproducible builds are **not finished yet**.
> Please read [STATUS.md](./STATUS.md) before relying on any build pathway.
> Contributions and testers are welcome on **all platforms**.

Portable build scripts for producing verified Komodo/AtomicDEX legacy artifacts:

- **KDF engine** from `KomodoPlatform/komodo-defi-framework`
- **Desktop wallet AppImage** from `cipig/komodo-wallet-desktop` (`nogeo`)
- Optional **KDF WebAssembly** build

The build is **native-first**: each platform script is the source of truth.
Docker is available for clean-room Linux builds, but it is not required.

**Proven Linux build:** KDF engine (~65 MB) and desktop AppImage (~187 MB)
built from `cipig/nogeo` on ubuntu:22.04 / glibc 2.35. The artifacts run
on Debian 12+ and modern Linux systems.

**Tested macOS builds:** Intel/x86_64 desktop app, plus native arm64 / Apple
Silicon desktop app on Mac mini M2. The native arm64 path disables the
QtWebEngine-dependent chart/price widget because Homebrew `qt@5` does not
ship QtWebEngine on arm64.

**Tested Windows build:** Full KDF + desktop wallet build on Windows 10+
x86_64 with VS Build Tools 2022, Qt 5.15.2, and vcpkg. Detailed walkthrough
in [WINDOWS.md](./WINDOWS.md).

---

## Quick start

Use the command wrapper unless you have a reason to call a platform script directly:

```bash
# Auto-detect Docker or native build path
./commands/build/command.sh

# Build one target
./commands/build/command.sh kdf
./commands/build/command.sh desktop
./commands/build/command.sh wasm

# Force native scripts instead of Docker
./commands/build/command.sh native
./commands/build/command.sh native kdf
./commands/build/command.sh native desktop

# Clean generated artifacts
./commands/build/command.sh clean
./commands/build/command.sh clean --all   # also prune Docker BuildKit cache
```

Artifacts land in:

```text
output/<platform>/
```

Logs land in:

```text
logs/<platform>/
```

---

## Common workflows

### 1. Build everything on Linux

```bash
./commands/build/command.sh
```

If Docker is running, the wrapper uses the clean-room Docker path. If Docker
is unavailable, it falls back to the native Linux script.

To force native:

```bash
./commands/build/command.sh native
```

### 2. Build only KDF

```bash
./commands/build/command.sh kdf
```

Native equivalent:

```bash
src/build-linux.sh --kdf-only
```

### 3. Build only the desktop AppImage

```bash
./commands/build/command.sh desktop
```

Native equivalent:

```bash
src/build-linux.sh --desktop-only
```

Desktop builds expect KDF to already be available from a prior run.

### 4. Install the built Linux desktop wallet

```bash
./commands/install/command.sh linux
```

Default install prefix is `~/.local`, so the launcher is installed as:

```text
~/.local/bin/community-exchange
```

Install somewhere else:

```bash
./commands/install/command.sh linux --prefix /usr/local
```

### 5. Run without installing

```bash
chmod +x output/linux/komodo-wallet-desktop-x86_64.AppImage
./output/linux/komodo-wallet-desktop-x86_64.AppImage
```

---

## Native build scripts

Call these directly when you want full control or platform-specific flags.

### Linux

```bash
src/build-linux.sh                  # full build: KDF + desktop
src/build-linux.sh --kdf-only       # KDF only (~5 min cached)
src/build-linux.sh --desktop-only   # desktop only (~8 min cached, longer first run)
src/build-linux.sh --yes            # skip consent prompts
src/build-linux.sh --dry-run        # check dependencies and print plan
src/build-linux.sh --install-deps   # install missing dependencies only
```

The Linux script detects `apt`, `dnf`, `pacman`, or `zypper`, explains
missing dependencies, and asks before installing anything unless `--yes` or
`BUILD_YES=1` is set.

### macOS

```bash
src/build-mac.sh                    # wrapper: host default (Intel on x86_64, arm on arm64)
src/build-mac.sh --arch intel       # force Intel/x86_64 desktop path
src/build-mac.sh --arch arm         # force native arm64 desktop path
src/build-mac-intel.sh              # direct Intel/x86_64 path
src/build-mac-arm.sh                # direct native arm64 path
src/build-mac.sh --yes              # skip consent prompts
src/build-mac.sh --dry-run          # check dependencies and print plan
```

Requires Xcode CLI tools. The Intel/x86_64 path builds the full QtWebEngine desktop shape. The native arm64 / Apple Silicon path is tested on Mac mini M2 and disables the QtWebEngine-dependent chart/price widget because Homebrew `qt@5` does not provide QtWebEngine on arm64.

### Windows

```powershell
src/build-windows.ps1               # full: KDF + desktop guidance
src/build-windows.ps1 -KdfOnly      # KDF only
src/build-windows.ps1 -Yes          # skip prompts
src/build-windows.ps1 -DryRun       # check dependencies and print plan
```

KDF builds natively with Rust. Desktop wallet builds with Qt5 + MSVC;
full walkthrough in [WINDOWS.md](./WINDOWS.md).

---

## Docker clean-room builds

The Dockerfile lives at `src/Dockerfile`, so direct Docker commands must pass
`-f src/Dockerfile`.

```bash
# KDF only
docker build --target kdf \
  -f src/Dockerfile \
  -o output/linux \
  .

# Desktop AppImage
docker build --target desktop \
  -f src/Dockerfile \
  -o output/linux \
  .

# Everything
docker build --target all \
  -f src/Dockerfile \
  -o output/linux \
  .
```

WASM uses a separate Dockerfile:

```bash
docker build \
  -f src/Dockerfile.kdf-wasm \
  -o output/wasm \
  .
```

In normal use, prefer the wrapper:

```bash
./commands/build/command.sh wasm
```

`src/docker-build.sh` is the inner script called by the Dockerfile. You
usually do not run it directly.

---

## GitHub Actions CI

A starter workflow now lives at:

```text
.github/workflows/build.yml
```

Current CI is **manual-only** via `workflow_dispatch`. Nothing runs on push or PR —
you trigger builds from the Actions tab or via the CLI helper:

```bash
./commands/ci/trigger.sh linux          # Linux only
./commands/ci/trigger.sh linux wasm     # Linux + WASM
./commands/ci/trigger.sh all            # everything
./commands/ci/trigger.sh windows --no-wait  # fire and forget
```

Current CI shape:

- **Linux:** full Docker build (`output/linux/`)
- **macOS Intel:** native Intel/x86_64 build (`output/mac-intel/`)
- **Windows:** **KDF-only** native build (`output/windows/`)
- **WASM:** Docker Wasm build via `wasm-pack` (`output/wasm/`)

Notes:

- No automatic triggers — every build is manual via the Actions tab or `./commands/ci/trigger.sh`.
- Windows desktop installer / portable zip are **not automated by this repo yet**.
- macOS CI is pinned to an **Intel runner** because that is the better-validated
  full desktop build path.
- Each CI job uploads both its `output/<platform>/` artifacts and its
  `logs/<platform>/` build logs.
- All four platform toggles default to **on** — uncheck what you want to skip.

### For forks

If you fork this repo and want CI to work, you need to:

1. **Enable Actions** — GitHub disables Actions on forks by default.
   Go to your fork → Settings → Actions → General → "Allow all actions".

2. **Actions permissions** — the workflow uses `actions: write` for the
   BuildKit GHA cache backend. Under Settings → Actions → General →
   Workflow permissions, select **"Read and write permissions"**.

3. **Windows builds need GITHUB_TOKEN** — the Windows job passes
   `GITHUB_TOKEN` to the build script for authenticated `git clone` of
   the upstream KDF repo. Without this, shared GitHub runner IPs hit
   unauthenticated rate limits and the clone fails. Forks get this
   automatically (GitHub provides `secrets.GITHUB_TOKEN` to all repos),
   but you must have Actions enabled per step 1 above.

4. **macOS runners** — the macOS Intel job runs on `macos-15-intel`.
   If your fork/account doesn't have access to macOS runners (private
   repos on free plans), that job will stay queued indefinitely. Uncheck
   `macos` when triggering, or remove the job from your fork's copy of
   the workflow.

### Current cache posture

- **Linux Docker builds:** the Dockerfile uses BuildKit cache mounts for
  Cargo, KDF target output, desktop build output, and vcpkg installed state.
- **GitHub Actions cross-run cache:** wired via `docker buildx build` with
  `--cache-from type=gha --cache-to type=gha,mode=max`. Heavy layers (Cargo
  registry, KDF target dir, apt packages) persist across runs when upstream
  sources haven't changed.
- **macOS / Windows hosted runners:** currently mostly cold-start each run.

### Target roadmap

| Platform | Arch | Current shape | Eventual targets |
| --- | --- | --- | --- |
| Linux | x86_64 | KDF + AppImage path | KDF, Qt desktop, AppImage, checksums |
| macOS | x86_64 | KDF + desktop / DMG path | KDF, Qt desktop, DMG, checksums |
| macOS | arm64 | native path with QtWebEngine limitation | KDF, Qt desktop, DMG, checksums |
| Windows | x86_64 | KDF-only automation | KDF, Qt desktop, portable ZIP, installer EXE, checksums |
| Windows | arm64 | roadmap | KDF, Qt desktop, portable ZIP, installer EXE, checksums |
| KDF | wasm | CI added, early Docker build path | wasm KDF artifact, checksums |

Recommended landing order:

1. Linux x86_64 CI green
2. Windows x86_64 KDF CI green
3. macOS Intel CI green
4. ~~KDF wasm CI added~~
5. Windows x86_64 desktop packaging
6. macOS arm64 polish
7. Windows ARM64 KDF
8. Windows ARM64 desktop packaging
9. signing / reproducibility / manifests

---

## What the build does

1. Detects platform, package manager, and architecture.
2. Checks required dependencies and explains what is missing.
3. Requests consent before installing dependencies, unless consent is pre-approved.
4. Clones pinned upstream repositories from `config/sources.json`.
5. Applies numbered patches from `config/patches/` if that directory exists.
6. Builds the requested target with numbered progress steps.
7. Writes artifacts and checksums to `output/<platform>/`.
8. Writes logs and install breadcrumbs to `logs/<platform>/`.

---

## Output

Typical Linux output:

```text
output/linux/
├── kdf                                      65 MB   KDF engine
├── kdf.sha256
├── komodo-wallet-desktop-x86_64.AppImage   187 MB  desktop wallet
├── komodo-wallet-desktop.sha256
└── komodo-wallet-desktop                    25 MB   raw binary fallback
```

Verify a checksum:

```bash
cat output/linux/kdf.sha256
sha256sum output/linux/kdf
```

The two hashes should match.

---

## Configuration

Copy the sample environment file when you need overrides:

```bash
cp env.sample .env
```

Common variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `BUILD_YES` | unset | Set to `1` to skip consent prompts. |
| `BUILD_CPUS` | auto | CPU cores for compilation. Linux defaults to about 1/3 of cores. |
| `OUTPUT_DIR` | `./output` | Artifact directory. Platform is appended by scripts. |
| `LOG_DIR` | `./logs` | Build log directory. Platform is appended by scripts. |
| `BUILD_DIR` | `./.build` | Upstream clone and compile cache. |
| `INSTALL_PREFIX` | `~/.local` | Install prefix used by `commands/install`. |
| `KDF_REPO` / `KDF_COMMIT` | `config/sources.json` | Override KDF source pin. |
| `DESKTOP_REPO` / `DESKTOP_COMMIT` | `config/sources.json` | Override desktop source pin. |
| `SOURCE_DATE_EPOCH` | current time | Set for reproducible byte-identical output. |

See `env.sample` for all supported variables and platform-specific settings.

---

## Source pins

Current pins are in `config/sources.json`.

| Component | Source | Pin |
| --- | --- | --- |
| KDF | `KomodoPlatform/komodo-defi-framework` | `30c877c5` |
| Desktop | `cipig/komodo-wallet-desktop`, branch `nogeo` | `0d333c5` |
| Linux base | ubuntu:22.04 | glibc 2.35 |

Environment variables can override these pins for local experiments or CI.

---

## Repository layout

```text
atomicdex-legacy-builder/
├── commands/
│   ├── build/command.sh         main entry point
│   ├── install/command.sh       install artifacts to system paths
│   └── update/command.sh        pull latest pipeline changes
├── config/
│   ├── sources.json             pinned upstream repos and commits
│   ├── platforms.json           per-platform toolchain pins
│   └── patches/                 optional numbered patch files
├── src/
│   ├── build-linux.sh           native Linux build
│   ├── build-mac.sh             macOS build dispatcher
│   ├── build-mac-intel.sh       Intel/x86_64 macOS build
│   ├── build-mac-arm.sh         native arm64 macOS build
│   ├── build-windows.ps1        native Windows build
│   ├── _build-lib.sh            shared shell helpers
│   ├── docker-build.sh          inner Docker build script
│   ├── Dockerfile               Linux multi-stage Docker build
│   └── Dockerfile.kdf-wasm      KDF → WebAssembly build
├── output/                      build artifacts, gitignored
├── logs/                        build logs, gitignored
├── .build/                      upstream clones/cache, gitignored
├── env.sample                   documented environment variables
└── README.md
```

---

## Design principles

- **Native first:** platform scripts are the source of truth; Docker wraps the
  Linux path for clean-room builds.
- **Pinned inputs:** upstream repos and commits are declared in
  `config/sources.json`.
- **Patch, do not fork:** local changes should live as numbered patches in
  `config/patches/` when a source delta is needed.
- **Human-readable failure:** scripts explain missing tools and suggested fixes.
- **Consent before install:** dependency installation is explicit unless
  `--yes` / `BUILD_YES=1` is used.
- **Visible progress:** long builds print numbered steps and write logs.
- **Verifiable output:** artifacts ship with sha256 files for independent
  rebuild comparison.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `cmake: command not found` | `src/build-linux.sh --install-deps && src/build-linux.sh` |
| `qtbase5-dev not found` | Re-run with `--install-deps`. Qt5 is large; the script explains before installing. |
| `GLIBC_2.38 not found` | Rebuild on ubuntu:22.04 / glibc 2.35 for wider compatibility. |
| Build uses too much CPU | Set a lower cap: `BUILD_CPUS=2 src/build-linux.sh`. |
| Docker out of disk | Run `docker system prune -a` if you are comfortable deleting Docker cache/images. |
| macOS: `xcode-select` error | Run `xcode-select --install`. |
| Windows: Qt/WebEngine link errors | See [WINDOWS.md](./WINDOWS.md) troubleshooting — most common causes are MSVC toolset version mismatch and libsodium overlay port path. |

---

## See also

- `https://kingofalldata.com/juno/briefs/2026-06-09-ecoincore-exchange-sovereign-dex-arc.md` — master architecture brief
