# crate

Native Swift rewrite of `../djcopilot`. The old repo is the debugged reference
implementation — when porting behavior, read the reference file first and match
its semantics (resolver rules, event strings, state machine) unless a decision
in DESIGN.md says otherwise.

## Build and run

- `swift build` — build everything (SwiftPM package; Xcode opens Package.swift).
- `swift run cratectl auth|cycle|ytm-search <q>` — headless CLI for testing.
- `swift run Crate` — the app.
- Package the app: `./scripts/package.sh` (produces `dist/Crate.app`).
- Quality analysis needs `uv tool install audiobox-aesthetics --with requests --with torchcodec`, plus `brew install ffmpeg@7` (torchcodec's dylibs; the main ffmpeg is unpinned).

## Conventions

- Swift 6 toolchain, language mode 5 (revisit strict concurrency later).
- External tools (yt-dlp, ffmpeg, deno/bun) are shell-outs found via
  Binaries.find: bundle path first, then Homebrew paths. Never a Python
  runtime.
- Always pass `--js-runtimes bun` to yt-dlp (deno stays preferred when
  present; bun is the smaller bundling target).
- All user settings live in the SQLite settings table. No config files.
- State lives in ~/Library/Application Support/crate. The first Crate run moves
  an existing slipmat state directory there.
- Conventional Commits, single line, no body, no co-author trailers.
- Commit each logical unit as it's completed.
