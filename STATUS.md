# STATUS

_Last updated: 2026-07-17 UTC_

This project is in a **very early first release** state.

Right now, we have successfully built and tested **Linux**, **macOS Intel/x86_64**, **native macOS arm64 / Apple Silicon**, and **Windows** paths. The native arm64 macOS path works with the QtWebEngine-dependent chart/price widget disabled, because Homebrew `qt@5` does not ship the required QtWebEngine package surface on arm64. WASM and reproducibility still need real-world runs, fixes, and tester feedback.

**Contributions and testers are welcome on all platforms.**

## Build pathway status

| Pathway | Status | Notes |
|---|---|---|
| Linux native | Working / verified | Current known-good path for KDF + desktop AppImage builds. |
| Linux Docker clean-room | Working on Linux / early | Intended clean-room Linux build path; still needs broader validation. |
| macOS Intel/x86_64 | Working / tested | Desktop app builds and runs in the Intel/x86_64 build shape, including on Apple Silicon hosts via the Intel path. |
| macOS arm64 / Apple Silicon | Working / tested with WebEngine disabled | Native arm64 desktop app builds and runs on Mac mini M2. QtWebEngine-dependent chart/price widget is disabled because Homebrew `qt@5` does not provide QtWebEngine on arm64. |
| Windows native x86_64 | Working / tested for KDF; desktop automation incomplete | KDF builds natively with Rust. Desktop wallet builds with Qt5 + MSVC; full walkthrough in [WINDOWS.md](./WINDOWS.md). CI packaging parity is not finished yet. |
| Windows native arm64 | Roadmap | Future target. Build and packaging shape should mirror Windows x86_64 once toolchain and CI story are defined. |
| KDF WebAssembly | Experimental / unverified | Build path exists, but needs testing, verification, clearer release expectations, and CI wiring. |
| Deterministic / reproducible builds | Not done yet | Reproducibility work is still outstanding. |

## Release posture

- This is not a finished cross-platform release yet.
- Linux, macOS Intel/x86_64, native macOS arm64, and Windows x86_64 have working tested paths at varying levels of automation.
- Native macOS arm64 currently ships as a no-QtWebEngine profile: the QtWebEngine-dependent chart/price widget is disabled, but the desktop wallet build and runtime are working.
- The Apple Silicon limitation is specifically QtWebEngine availability in Homebrew `qt@5`, not the basic Apple Silicon toolchain or wallet build.
- Windows CI is currently focused on getting **KDF x86_64** stable first; portable ZIP / installer automation is still ahead.
- Windows arm64 is part of the roadmap and should be treated as a first-class future target, not an afterthought.
- KDF wasm should still be treated as an **early pathway under construction**, but it is a real eventual target and should be added to CI once the core matrix is stable.
- Deterministic output has **not** been locked down yet.

## Target roadmap

| Platform | Arch | Current shape | Eventual targets |
|---|---|---|---|
| Linux | x86_64 | KDF + AppImage path | KDF, Qt desktop, AppImage, checksums |
| macOS | x86_64 | KDF + desktop / DMG path | KDF, Qt desktop, DMG, checksums |
| macOS | arm64 | native path with QtWebEngine limitation | KDF, Qt desktop, DMG, checksums |
| Windows | x86_64 | KDF-only CI automation today | KDF, Qt desktop, portable ZIP, installer EXE, checksums |
| Windows | arm64 | roadmap | KDF, Qt desktop, portable ZIP, installer EXE, checksums |
| KDF | wasm | experimental path exists | wasm KDF artifact, checksums |

Recommended landing order:

1. Linux x86_64 CI green
2. Windows x86_64 KDF CI green
3. macOS Intel CI green
4. KDF wasm CI added
5. Windows x86_64 desktop packaging
6. macOS arm64 polish
7. Windows ARM64 KDF
8. Windows ARM64 desktop packaging
9. signing / reproducibility / manifests

## Help wanted

We welcome:

- platform testers on **Linux, macOS, and Windows**
- reproducibility / deterministic build help
- CI and validation improvements
- bug reports for missing dependencies, script issues, and packaging failures
- docs fixes from people walking the build paths for the first time

If you test a pathway and get it working, please report:

- host OS and version
- architecture
- exact command used
- whether you built KDF, desktop, or WASM
- artifact hashes and sizes
- any patches or local fixes needed
