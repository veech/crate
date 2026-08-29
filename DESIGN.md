# slipmat — Design

Native macOS app: a DJ library manager fed by an acquisition pipeline.
Swift rewrite of `../djcopilot` (kept as the reference implementation; its
DESIGN.md holds the full acquisition rationale, which carries over).

## Identity

Two halves:

1. **Pipeline** — the ported djcopilot acquisition flow: SoundCloud Queue
   playlist, a YouTube queue playlist (by URL; items are pre-resolved since
   the video is the source), and Beatport keepers playlist in; resolve →
   fetch → normalize → file. Same state machine, same event log, same policies (rip first, buy
   keepers, 256k floor, credential-gated fetches, no external writes).
2. **Library** — repositories of local folders (genre folders), with
   **Inbox** as the pinned landing repo the pipeline files into. Tracks
   keep their source dossier. Integrated audition player (scrub to judge
   genre), inline tag editing on the selected row (title, artist, genre —
   title/artist edits also rename the file and feed the pipeline record so
   dedupe matches), multi-select, move between repos, context-menu actions.
   Imported files without source info are first-class rows, and can be
   back-matched to SoundCloud (search + duration gate + LLM adjudication).
   Find Source only records the discovery (`file_sources`); the row's
   icon-only Upgrade column then shows availability (lossy file + a source
   with a download), and the explicit Upgrade action enters the pipeline
   with `upgrade_path` set — normalize replaces the old rip in place,
   keeping folder and genre. The Source column stays pure identity:
   service plus page link.

**Analyze**: quality is live — an on-demand Library action ("Analyze
Quality") scoring tracks with Meta's audiobox-aesthetics model via a
uv-installed CLI (`uv tool install audiobox-aesthetics --with requests
--with torchcodec`; torchcodec needs Homebrew ffmpeg ≤7 dylibs). PQ shows
in the sortable Quality column (all four axes in the tooltip); scores live
in `file_analysis`, DB-only, never in tags, invalidated when an upgrade
replaces the audio. Still post-MVP: key (Camelot) and BPM. The pipeline's
spectral transcode warning is separate, existing normalize behavior.

## Architecture

- **SwiftPM package**, three targets: `SlipmatCore` (library: DB, clients,
  pipeline), `Slipmat` (SwiftUI app), `slipmatctl` (headless CLI for auth
  checks and cycles — the test surface).
- **No Python runtime.** External work is shell-outs to single-file
  binaries: `yt-dlp` (rips, probes; `--js-runtimes bun` always passed),
  `ffmpeg` (convert, tag/strip/art, spectral check). Dev resolves them from
  Homebrew paths; packaging bundles them in the .app (the Downie pattern),
  with yt-dlp updated independently of app releases.
- **Service clients are native URLSession**: SoundCloud api-v2, Beatport v4,
  YouTube Music InnerTube search (constants copied from the reference
  ytmusicapi: WEB_REMIX client, songs filter param
  `EgWKAQIIAWoMEA4QChADEAQQCRAF`), Anthropic Messages API with structured
  outputs (title split, match adjudication).
- **State**: SQLite via GRDB in `~/Library/Application Support/slipmat` —
  same schema as the reference (tracks, track_events, settings) plus
  `repos` and a `library_files` probe cache. Library reads folders straight
  from disk; the cache keys on path + mtime + size so rescans are cheap.
  All settings in the DB; no config file. Cookie files
  (Netscape format) in the auth dir, pasted via the settings UI.
- **Defaults**: manual mode (`poll_minutes` 0) — cycles run from the UI;
  collection dir `~/Downloads/Queue`; downloads dir `~/Downloads`;
  target format FLAC.
- **Anthropic key**: a setting pasted in the app (env var as CLI
  fallback). Stored plaintext in the app database — acceptable for a
  single-user machine; moving it to the Keychain is a packaging-time
  change, once the app is signed and its identity stops changing every
  build (unsigned dev builds would otherwise prompt on every rebuild).

## Decisions carried from the reference

- DRM is a hard boundary; CAPTCHA is a hard boundary (no SoundCloud queue
  drain — Datadome; playlist cleared by hand).
- Key/BPM (post-MVP) go in the DB only, never into tags. Normalize still
  writes exactly title + artist + art; the one tag added later is genre,
  typed by hand in Library — it must travel with the file into DJ software,
  so it lives in the file, not the DB.
- Buying stays manual on Beatport; purchases ingest from the downloads
  folder by track-id filename match and upgrade in place.

## Port map (reference file → here)

| Reference (djcopilot) | slipmat |
|---|---|
| db.py | Store.swift |
| settings.py | Store.swift (AppSettings) |
| soundcloud.py | SoundCloudClient.swift |
| beatport.py | BeatportClient.swift |
| ytm.py + ytmusicapi | YTMusicClient.swift + Matcher.swift |
| adjudicate.py | Anthropic.swift |
| fetch.py | YtDlp.swift |
| normalize.py | FFmpeg.swift |
| reconcile.py | Reconciler.swift |
| auth.py | AuthStatus.swift |
| web.py + React app | SwiftUI (Slipmat target) |

## Roadmap

1. Core port compiling + slipmatctl auth/cycle verified against live services.
2. SwiftUI shell: pipeline sections, run cycle, settings (cookies paste).
3. Library: repos + probe cache, Inbox, inline tag editing (title, artist,
   genre — written to the file; name edits rename), move/multi-select,
   context menu, audition player with scrubbing (AVAudioPlayer). Done.
4. Gate flow UI: open gate + select the downloaded file (gates rarely
   expose a copyable final URL — learned in reference testing; the
   paste-a-link flow is dead). Needs-review candidate picker.
5. Packaging: .app bundle via scripts/package.sh (ad-hoc signed; ffmpeg
   and yt-dlp still resolved from Homebrew). Remaining: bundled binaries,
   yt-dlp self-update, real signing + Keychain for the API key.
6. Analyze: quality shipped (audiobox-aesthetics via uv tool). Post-MVP:
   key (Camelot), BPM.
