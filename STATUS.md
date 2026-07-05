# STATUS

_Last updated: 2026-07-05 UTC_

This project is in a **very early first release** state.

Right now, we have a **successfully built and verified Linux path**, plus a **working but still narrowly validated macOS Intel/x86_64 desktop path**. Other build pathways are still present as scaffolding or early implementation and need more real-world runs, fixes, and tester feedback.

**Contributions and testers are welcome on all platforms.**

## Build pathway status

| Pathway | Status | Notes |
|---|---|---|
| Linux native | Working / verified | Current known-good path for KDF + desktop AppImage builds. |
| Linux Docker clean-room | Working on Linux / early | Intended clean-room Linux build path; still needs broader validation. |
| macOS native | Working / narrow validation | macOS desktop path now works in the current Intel/x86_64 build shape (including Apple Silicon hosts building the Intel app path). Native arm64 macOS support is still in progress; current Apple Silicon work is blocked at the QtWebEngine layer because Homebrew `qt@5` does not provide the required QtWebEngine package surface. |
| Windows native | Unverified | Script exists; KDF path is drafted, desktop path still needs real validation and cleanup. |
| KDF WebAssembly | Experimental / unverified | Build path exists, but needs testing, verification, and clearer release expectations. |
| Deterministic / reproducible builds | Not done yet | Reproducibility work is still outstanding. |

## Release posture

- This is not a finished cross-platform release yet.
- Linux is the clearest proven path right now.
- macOS currently works in the Intel/x86_64 desktop build shape, but **native arm64 macOS is still under construction**.
- Current Apple Silicon blocker: Homebrew `qt@5` on arm64 provides Qt 5.15.x and `macdeployqt`, but does **not** provide the QtWebEngine CMake/runtime pieces this desktop app currently expects.
- That means the present native arm64 issue is **QtWebEngine availability/integration**, not the basic Apple Silicon toolchain itself.
- Windows and WASM should still be treated as **early pathways under construction**.
- macOS was reworked to mirror the upstream CIPIG GitHub Actions path more closely, but that currently means following the Intel-oriented Qt/Desktop shape rather than a native arm64 one.
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
