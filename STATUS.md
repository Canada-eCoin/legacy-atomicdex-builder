# STATUS

_Last updated: 2026-07-02 UTC_

This project is in a **very early first release** state.

Right now, we have only **successfully built and verified the Linux path**. The other build pathways are present as scaffolding or early implementation, but they still need successful real-world runs, fixes, and tester feedback.

**Contributions and testers are welcome on all platforms.**

## Build pathway status

| Pathway | Status | Notes |
|---|---|---|
| Linux native | Working / verified | Current known-good path for KDF + desktop AppImage builds. |
| Linux Docker clean-room | Working on Linux / early | Intended clean-room Linux build path; still needs broader validation. |
| macOS native | Unverified | Script exists, but this path still needs successful builds and platform testing. |
| Windows native | Unverified | Script exists; KDF path is drafted, desktop path still needs real validation and cleanup. |
| KDF WebAssembly | Experimental / unverified | Build path exists, but needs testing, verification, and clearer release expectations. |
| Deterministic / reproducible builds | Not done yet | Reproducibility work is still outstanding. |

## Release posture

- This is not a finished cross-platform release yet.
- Linux is the only platform we currently consider proven.
- macOS, Windows, and WASM should be treated as **early pathways under construction**.
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
