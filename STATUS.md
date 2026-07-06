# STATUS

_Last updated: 2026-07-06 UTC_

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
| Windows native | Working / tested | KDF builds natively with Rust. Desktop wallet builds with Qt5 + MSVC; full walkthrough in [WINDOWS.md](./WINDOWS.md). |
| KDF WebAssembly | Experimental / unverified | Build path exists, but needs testing, verification, and clearer release expectations. |
| Deterministic / reproducible builds | Not done yet | Reproducibility work is still outstanding. |

## Release posture

- This is not a finished cross-platform release yet.
- Linux, macOS Intel/x86_64, native macOS arm64, and Windows have working tested paths.
- Native macOS arm64 currently ships as a no-QtWebEngine profile: the QtWebEngine-dependent chart/price widget is disabled, but the desktop wallet build and runtime are working.
- The Apple Silicon limitation is specifically QtWebEngine availability in Homebrew `qt@5`, not the basic Apple Silicon toolchain or wallet build.
- WASM should still be treated as an **early pathway under construction**.
- Deterministic output has **not** been locked down yet.

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
