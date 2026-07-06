# Native Windows Build Guide — AtomicDEX Legacy

> **Status: Working / tested.** Full KDF + desktop wallet build confirmed on
> Windows 10+ x86_64 with VS Build Tools 2022 and Qt 5.15.2.

This document describes how to reproduce a full native Windows build of the
AtomicDEX Legacy stack (KDF engine + Desktop Wallet) from first principles.

The reference script is `src/build-windows.ps1`.  The desktop wallet follows the
same process as `ci_tools_atomic_dex/ci_scripts/windows_script.ps1` (CIPIG CI).

---

## Prerequisites (what to install and why)

| Tool | Version | Required for | Install command |
|------|---------|--------------|-----------------|
| **Git for Windows** | any recent | cloning repos | `winget install Git.Git` |
| **Rust** (rustup) | 1.96+ | KDF engine | `winget install Rustlang.Rustup` |
| **CMake** | 4.3+ | desktop build system | `winget install Kitware.CMake` |
| **VS Build Tools 2022** | 17.14+ | MSVC C++ compiler | (see below) |
| **Windows SDK** | 10.0.26100+ | Windows headers/libs | (bundled with VS) |
| **LLVM/Clang** | 22.x | Ninja generator / linker | `scoop install llvm ninja` |
| **Protobuf** | 35.x | KDF protobuf codegen | `winget install Google.Protobuf` |
| **Python** | 3.x | vcpkg bootstrap | `scoop install python` |
| **Qt 5.15.2** | MSVC 2019 64-bit | desktop UI framework | (manual download) |
| **7zip** | any | archive extraction | `scoop install 7zip` |

### MSVC — manual step (largest download)

1. Download **Visual Studio 2022 Build Tools** from:
   https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022

2. Run the installer, select the **"Desktop development with C++"** workload
   (≈6 GB).  Inside that workload, ensure **Windows 10/11 SDK** (10.0.26100.0)
   is checked.

3. Verify MSVC is usable:
   ```
   & "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
   ```
   Should print a path like `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`.

### Qt 5.15.2 — manual step

The legacy desktop wallet requires **Qt 5.15.2 for MSVC 2019 64-bit** plus
the `qtcharts` and `qtwebengine` modules.

1. Go to https://download.qt.io/archive/qt/5.15/5.15.2/
2. Download `qt-opensource-windows-x86-msvc2019_64-5.15.2.exe`
3. Run the installer.  Select:
   - **Qt 5.15.2** → **MSVC 2019 64-bit**
   - Under that node check: `Qt Charts`, `Qt WebEngine`, `Qt WebEngine` (WebEngine itself)
4. Install to `C:\Qt\5.15.2\msvc2019_64`

**Friction**: Qt does not offer a command-line installer for 5.15.2 anymore;
you need to use the Qt Online Installer or the standalone offline installer.
The online installer hides older versions — you need an Qt Account (free) and
must check "Archive" in the filter to see 5.15.x.

### Rust targets

```
rustup target add x86_64-pc-windows-msvc
```

### scoop (for speed)

```
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
irm get.scoop.sh | iex
scoop install llvm ninja 7zip python
```

---

## Step 1 — Clone everything

```powershell
git clone https://github.com/anomalyco/legacy-atomicdex-builder.git
cd legacy-atomicdex-builder
```

The pinned commits live in `config/sources.json`:

| Component | Repo | Commit |
|-----------|------|--------|
| KDF | `KomodoPlatform/komodo-defi-framework` | `30c877c5` |
| Desktop wallet | `cipig/komodo-wallet-desktop` | `0d333c5` |
| Coins config | `cipig/coins` (branch `nogeo`) | latest |

---

## Step 2 — Build KDF engine

The script handles this automatically:

```powershell
.\src\build-windows.ps1 -KdfOnly
```

What it does internally:

1. **Clones** the KDF repo at the pinned commit, including submodules.
2. **Sets up the MSVC environment** (LIB, INCLUDE, PATH) for `x86_64-pc-windows-msvc`.
3. **Finds protoc** (checks WinGet install location as fallback).
4. **Builds** with `cargo build --release -p mm2_bin_lib`.
5. **Copies** `target\x86_64-pc-windows-msvc\release\kdf.exe` → `output\windows\kdf.exe`.

Output: `output\windows\kdf.exe` (~78 MB).

### Friction / pitfalls

- **protoc not in PATH**: WinGet installs protoc silently but adds the path
  to a versioned folder (e.g. `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Google.Protobuf_35.0\bin`).
  The script scans for this but if the folder naming changes, protoc detection breaks.
  Workaround: set `$env:PROTOC = "path\to\protoc.exe"`.

- **MSVC LIB/INCLUDE not set**: The Rust linker needs `link.exe` from MSVC.
  If `cargo build` fails with `link.exe not found`, run from a **Developer
  Command Prompt** (or set `LIB` and `INCLUDE` manually as the script does).
  The script auto-detects VS 2022 Build Tools at the standard path and sets
  the environment.  If you installed to a non-standard location, set
  `$env:LIB` and `$env:INCLUDE` yourself.

- **KDF build time**: ~10-15 min on 8 cores.  Set `$env:BUILD_CPUS` or the
  script uses half of logical cores.

- **Cargo picks wrong linker**: If you have both MSVC and MinGW, Cargo may
  pick `x86_64-pc-windows-gnu` linker.  Make sure `rustup default
  stable-x86_64-pc-windows-msvc` is set.

---

## Step 3 — Build Desktop Wallet

The desktop wallet is a CMake + Ninja + vcpkg + Qt project.  This is the
complex part.

### 3.1 — Prepare source tree

```powershell
$BuildDir = ".build\desktop"

# Create build directory structure
New-Item -ItemType Directory -Force -Path "$BuildDir\atomic_defi_design\assets\images\coins"
New-Item -ItemType Directory -Force -Path "$BuildDir\assets\config"
New-Item -ItemType Directory -Force -Path "$BuildDir\assets\tools\kdf"

# Clone desktop wallet
git clone https://github.com/cipig/komodo-wallet-desktop -b nogeo "$BuildDir"
cd "$BuildDir"
git checkout 0d333c5
git submodule update --init --recursive

# Copy KDF binary
Copy-Item "..\..\output\windows\kdf.exe" "assets\tools\kdf"
```

### 3.2 — Bootstrap vcpkg

The project uses **manifest-mode vcpkg** (vcpkg.json) with custom overlay ports.

```powershell
$VcpkgDir = "ci_tools_atomic_dex\vcpkg-repo"
if (-not (Test-Path "$VcpkgDir\.git")) {
    git clone https://github.com/microsoft/vcpkg "$VcpkgDir"
}
& "$VcpkgDir\bootstrap-vcpkg.bat" -disableMetrics
```

**Friction**: The vcpkg baseline is pinned to commit `36393d1` in
`vcpkg.json`.  Bootstrapping checks out the *latest* vcpkg, not the baseline.
The baseline only affects which *port version* is resolved — the vcpkg tool
itself can be newer.

### 3.3 — Custom vcpkg triplet

Create `cmake\x64-windows-custom.cmake`:

```cmake
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE $ENV{VCPKG_BUILD_TYPE})
set(SPDLOG_WCHAR_FILENAMES ON)
```

This triplet is already in the repo.  It builds **dynamic CRT + dynamic libs**
with SPDLOG wide-char filename support (required on Windows).

### 3.4 — Custom overlay ports

The overlay ports live at `ci_tools_atomic_dex/vcpkg-custom-ports/ports/`:

- **libsodium** — A fork of the upstream vcpkg port with a critical fix:
  the original port used `vcpkg_msbuild_install` which does not work with
  custom triplets.  The overlay replaces it with a direct MSBuild invocation
  + manual `file(INSTALL)` for the build outputs.

- **cpprestsdk** — Needed for compression features on Windows.

- **asyncplusplus** — Needed because the upstream port was removed from
  the vcpkg baseline.

#### libsodium overlay — the big friction point

The upstream `libsodium` port in vcpkg (baseline `36393d1`) has two bugs
on Windows:

1. **`vcpkg_msbuild_install` is broken for custom triplets** — it tries to
   read the triplet's .cmake file as a vcxproj.  The fix: use absolute paths
   to MSBuild and call `vcpkg_execute_required_process` directly instead.

2. **Output glob pattern is wrong** — The upstream portfile used:
   ```cmake
   file(GLOB_RECURSE REL_LIBS "${rel_dir}/bin/x64/Release/*/${lib_linkage}/*.lib")
   ```
   where `${lib_linkage}` = `DLL`.  But the actual MSBuild output folder is
   named `dynamic`, not `DLL`.  Fix: use `${lib_suffix}` which resolves to
   `dynamic`.

3. **Relative paths in vcxproj are too deep** — The stock libsodium vcxproj
   references headers via `../../../../src/libsodium/...`.  Four levels of
   `..` hit the filesystem root on some Windows configurations.  Fix: replace
   the relative path with an absolute path in the portfile:
   ```cmake
   string(REPLACE "../../../../src/libsodium/" "${rel_dir}/src/libsodium/" VCPROJ_CONTENT "${VCPROJ_CONTENT}")
   ```

4. **Hardcoded MSBuild path** — `vcpkg_msbuild_install` uses the
   `MSBUILD_EXE` variable which is NOT available in portfile context.
   The overlay hardcodes:
   ```cmake
   set(MSBUILD_PATH "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe")
   ```
   If your VS Build Tools are installed elsewhere, change this path.

5. **Must add libsodium to "overrides" in vcpkg.json** — Even with the
   overlay port, vcpkg will prefer the baseline version unless you add:
   ```json
   "overrides": [
     {
       "name": "libsodium",
       "version": "1.0.22",
       "port-version": 0
     }
   ]
   ```
   This is already set in `vcpkg.json`.

### 3.5 — Install vcpkg dependencies

```powershell
$env:VCPKG_BUILD_TYPE = "Release"
$env:VCPKG_BINARY_SOURCES = "clear;files,C:\Users\$env:USERNAME\AppData\Local\vcpkg\archives,readwrite"

& "$VcpkgDir\vcpkg.exe" install --triplet x64-windows-custom
```

This installs: boost, openssl, nlohmann-json, range-v3, fmt, spdlog,
date, asyncplusplus, asio, cpprestsdk, entt, refl-cpp, strong-type,
tl-expected, libsodium.

Takes ≈10-20 minutes on first run (building libsodium from source).
Subsequent runs are instant (binary cache).

### 3.6 — Build wally

```powershell
# Pre-built wally is needed. The project expects it at:
#   .build/desktop/libwally-core/
mkdir -Force "$BuildDir\libwally-core"
# See ci_tools_atomic_dex for the build script; or copy prebuilt DLL:
# wally.dll, wally.lib → libwally-core/
```

**Friction**: wally is NOT built by vcpkg or CMake — it must be built
separately.  The CMakeLists.txt expects headers at
`${CMAKE_SOURCE_DIR}/libwally-core/include` and the lib at
`${CMAKE_SOURCE_DIR}/libwally-core/lib`.  On CI, wally is pre-built and
included in the repo.  For a from-scratch build, you need to cross-compile
wally for Windows or extract it from a known-good CI artifact.

The easiest workaround: copy from a previous successful build:
```
xcopy /E /I known-good-build\libwally-core .build\desktop\libwally-core\
```

### 3.7 — Configure CMake

```powershell
$env:QT_INSTALL_CMAKE_PATH = "C:/Qt/5.15.2/msvc2019_64"

cmake -S . -B build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_PREFIX_PATH=C:/Qt/5.15.2/msvc2019_64/lib/cmake
```

**Important**: The `QT_INSTALL_CMAKE_PATH` env var must point to the **Qt
root** (`C:/Qt/5.15.2/msvc2019_64`), NOT the cmake subdirectory.  The CMake
build uses this to find `windeployqt.exe`.

**Friction**: The custom vcpkg triplet `x64-windows-custom` is automatically
selected on Windows via `vcpkg_prerequisites.cmake`:
```cmake
if (WIN32)
    set(VCPKG_TARGET_TRIPLET "x64-windows-custom")
endif ()
```

If cmake configure fails with "triplet not found", verify:
- `cmake/x64-windows-custom.cmake` exists
- `VCPKG_OVERLAY_TRIPLETS` in `vcpkg_prerequisites.cmake` points to the
  `cmake/` directory

### 3.8 — Build

```powershell
cmake --build build -- -j8
```

**First build** is slow (≈5-10 min) because it compiles the QRC resources
(which now include 484 coin icon PNGs) and links the full Qt application.

**Subsequent builds** are fast — only changed files recompile.

The result is at `build/bin/komodo-wallet.exe` (≈16 MB, plus all deployed
Qt/C++ DLLs in the same directory ≈extra 200 MB).

### 3.9 — Coin icons — a critical Windows fix

The `CMakeLists.txt` had a bug where coin icons were only deployed on UNIX:

```cmake
if (UNIX)
    file(COPY ${jl777-coins_SOURCE_DIR}/icons/ DESTINATION
         ${CMAKE_CURRENT_SOURCE_DIR}/atomic_defi_design/assets/images/coins/)
else ()
    # ⚠ THIS WAS MISSING — icons never copied on Windows
endif ()
```

The CMake function `dex_generate_qrc()` (in `cmake/dex_generate_qrc.cmake`)
auto-generates `qml.qrc` by scanning `atomic_defi_design/assets/` with
`GLOB_RECURSE`.  On UNIX the icons were copied before the scan; on Windows
they weren't — leading to a build with zero coin icons in the QRC.

**Fix** — add to the `else ()` branch:
```cmake
file(COPY ${jl777-coins_SOURCE_DIR}/icons/
     DESTINATION ${CMAKE_CURRENT_SOURCE_DIR}/atomic_defi_design/assets/images/coins/)
```

This fix has been applied in this repo's `CMakeLists.txt`.

---

## Step 4 — Run the wallet

```powershell
cd build\bin
.\komodo-wallet.exe
```

The app will:
1. Extract the bundled `kdf.exe` to `%APPDATA%\atomic_qt\<version>\tools\kdf\`
2. Extract coins config to `%APPDATA%\atomic_qt\<version>\config\`
3. Launch the Qt UI

Coin icons load from the compiled-in QRC (`qrc:///assets/images/coins/`).

---

## Project layout (desktop build tree)

```
.build\desktop\
├── CMakeLists.txt              # root build file
├── vcpkg.json                  # manifest mode deps
├── cmake\
│   ├── x64-windows-custom.cmake   # custom vcpkg triplet
│   ├── vcpkg_prerequisites.cmake  # vcpkg toolchain setup
│   └── dex_generate_qrc.cmake     # auto-generates QRC from assets/
├── ci_tools_atomic_dex\
│   ├── vcpkg-repo\                 # vcpkg clone
│   ├── vcpkg-custom-ports\ports\  # overlay ports
│   │   ├── libsodium\
│   │   ├── cpprestsdk\
│   │   └── asyncplusplus\
│   └── ci_scripts\
│       └── windows_script.ps1     # CIPIG CI reference
├── atomic_defi_design\
│   ├── assets\
│   │   ├── qml.qrc               # auto-generated by dex_generate_qrc()
│   │   ├── images\coins\         # 484 PNGs (copied from coins repo)
│   │   ├── images\               # generic UI icons
│   │   ├── config\               # coins.json at configure time
│   │   └── tools\kdf\            # kdf.exe at configure time
│   ├── Dex\                       # QML source
│   │   └── qml.qrc               # auto-generated
│   └── imports\                   # JS imports
├── libwally-core\                # pre-built wally (not in repo)
├── src\                           # C++ source + main.cpp
└── build\                         # CMake build output
    └── bin\
        ├── komodo-wallet.exe
        ├── assets\               # runtime assets (copied from atomic_defi_design)
        └── *.dll                 # Qt + vcpkg DLLs deployed by windeployqt
```

---

## Troubleshooting guide

### "MSBuild.exe not found"

The libsodium overlay portfile hardcodes the MSBuild path:
```
C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe
```
If your MSBuild is elsewhere (e.g. full VS, not Build Tools), edit
`ci_tools_atomic_dex/vcpkg-custom-ports/ports/libsodium/portfile.cmake`
and update the `MSBUILD_PATH` variable.

### "libsodium.lib not found" during link

Check `vcpkg_installed/x64-windows-custom/lib/libsodium.lib` exists.
If not, the MSBuild build of libsodium failed.  Look at logs in
`ci_tools_atomic_dex/vcpkg-repo/buildtrees/libsodium/`.

Common cause: the MSBuild solution has the wrong platform toolset.
The portfile sets `/p:PlatformToolset=v143`.  If you have VS 2019 (v142),
change to `v142`.

### "coin icons not showing" in the wallet

Check whether 484 PNGs exist in the output:
```powershell
# In QRC (compiled into exe)
Select-String "images/coins" atomic_defi_design\assets\qml.qrc | Measure-Object

# At runtime (file system, accessible only as qrc:///)
# The images are compiled INTO the exe, not shipped as loose files
```

If missing, re-run cmake configure to regenerate `qml.qrc` and rebuild.

### "windeployqt.exe not found"

The `src/CMakeLists.txt` (line 145) looks for:
```cmake
$ENV{QT_INSTALL_CMAKE_PATH}/bin/windeployqt.exe
```

Set `$env:QT_INSTALL_CMAKE_PATH` to `C:/Qt/5.15.2/msvc2019_64` (the Qt root,
not `lib/cmake`).

### vcpkg build fails with "error: unknown triplet"

Verify `cmake/x64-windows-custom.cmake` exists and contains valid CMake.
The file must be picked up by the `VCPKG_OVERLAY_TRIPLETS` setting in
`vcpkg_prerequisites.cmake`.

### "fatal error: sodium.h: No such file or directory"

libsodium headers were not installed.  Check
`vcpkg_installed/x64-windows-custom/include/sodium.h`.  If missing,
re-run:
```
vcpkg install libsodium --triplet x64-windows-custom
```

If it says "already installed", delete the `vcpkg_installed` directory and
re-install.

### "wally not found" at CMake configure time

The CMakeLists.txt expects wally at `${CMAKE_SOURCE_DIR}/libwally-core/`.
If missing, create the directory and provide `wally.lib` + `wally.dll` +
headers.  See `.github/workflows/` or a known-good CI run for the
pre-built artifact URL.

---

## Reference: what build-windows.ps1 automates

The script at `src/build-windows.ps1` handles:

1. **Platform detection** — Windows version, architecture, available
   package managers (choco / winget).

2. **Dependency check** — Verifies git, rustup/cargo, cmake, MSVC or
   MinGW, OpenSSL, protoc.

3. **KDF clone + build** — Checks out pinned commit, sets up MSVC env,
   builds with cargo, copies output.

4. **Desktop guidance** — Prints manual build steps (the desktop part
   was considered too complex to fully automate).

To run: `.\src\build-windows.ps1 -KdfOnly`
