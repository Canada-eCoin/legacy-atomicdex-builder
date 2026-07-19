# STATUS

_Last updated: 2026-07-19 UTC_

All four platforms build and ship in CI. Releases are created
automatically on version tags (`v*`) with individual artifacts
and full provenance.

| Platform | Artifacts |
|---|---|
| Linux | KDF + AppImage (~187 MB) |
| macOS Intel | KDF + DMG (~146 MB) |
| Windows x86_64 | KDF + portable ZIP (~186 MB) |
| WASM | mm2_bg.wasm + mm2.js (~32 MB) |

## Build pathway status

| Pathway | Status | Notes |
|---|---|---|
| Linux native | Working / verified | Current known-good path for KDF + desktop AppImage builds. |
| Linux Docker | Working / verified + cached | CI Docker build with GHA cache backend. |
| macOS Intel/x86_64 | Working / verified + DMG | Desktop app builds, DMG created via macdeployqt + hdiutil. CI green. |
| macOS arm64 / Apple Silicon | Working / tested with WebEngine disabled | Native arm64 desktop app builds and runs. QtWebEngine-dependent chart/price widget disabled (Homebrew qt@5 limitation). |
| Windows native x86_64 | Working / verified + portable ZIP | Full KDF + Qt desktop build with portable ZIP output. CI green. |
| Windows native arm64 | Roadmap | Future target. |
| KDF WebAssembly | Working / verified + in releases | Docker wasm-pack build, CI green. mm2_bg.wasm + mm2.js in releases. |
| Deterministic / reproducible builds | Not done yet | Reproducibility work still outstanding. |

## Release posture

- Tag-based releases (`git tag v* && git push --tags`) build all four
  platforms and create a GitHub Release with individual artifacts.
- Each release includes SHA256 checksums and a full provenance table
  listing all pinned upstream sources.
- Linux AppImage confirmed working and tested.
- macOS DMG confirmed building in CI.
- Windows portable ZIP confirmed building in CI (installer EXE still TBD).
- WASM artifacts included in releases.
- macOS arm64 is not in CI (requires Apple Silicon runner) but the
  build script is tested on Mac mini M2.
- Deterministic output has **not** been locked down yet.

## Target roadmap

| Platform | Arch | Current shape | Eventual targets |
|---|---|---|---|
| Linux | x86_64 | KDF + AppImage + CI | KDF, Qt desktop, AppImage, checksums |
| macOS | x86_64 | KDF + DMG + CI | KDF, Qt desktop, DMG, checksums |
| macOS | arm64 | native path with QtWebEngine limitation | KDF, Qt desktop, DMG, checksums |
| Windows | x86_64 | KDF + portable ZIP + CI | KDF, Qt desktop, portable ZIP, installer EXE, checksums |
| Windows | arm64 | roadmap | KDF, Qt desktop, portable ZIP, installer EXE, checksums |
| KDF | wasm | CI green + in releases | wasm KDF artifact, checksums |

Recommended landing order:

1. ~~Linux x86_64 CI green~~
2. ~~Windows x86_64 KDF CI green~~
3. ~~macOS Intel CI green~~
4. ~~KDF wasm CI added~~
5. ~~Windows x86_64 desktop packaging~~
6. macOS arm64 polish
7. Windows ARM64 KDF
8. Windows ARM64 desktop packaging
9. signing / reproducibility / manifests
10. Windows installer EXE / macOS .pkg

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
