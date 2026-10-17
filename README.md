# Video Summarizer: a personal video-learning library for macOS

Paste a video link and get:
- an **mp3**,
- an **on-device transcript** with timestamps,
- an **AI summary** written by Claude,
- a permanent, searchable **history** of everything you've watched and learned.

You can use it three ways: a native macOS app (**Video Summarizer.app**), three **Raycast** commands, or a self-hosted **cobalt** web page for downloads.

This document explains what the project is, how every part works, where everything lives, how to rebuild it from scratch, and how it was built and why.

---

## Contents
1. [What this is](#1-what-this-is)
2. [Daily use](#2-daily-use)
3. [Architecture](#3-architecture)
4. [The pipeline, step by step](#4-the-pipeline-step-by-step)
5. [Inside the app](#5-inside-the-app)
6. [Where everything lives](#6-where-everything-lives)
7. [How it was built (the story and the decisions)](#7-how-it-was-built)
8. [Setting it up from scratch](#8-setting-it-up-from-scratch)
9. [Operations: start, stop, update, rebuild, restore](#9-operations)
10. [Troubleshooting](#10-troubleshooting)
11. [Testing](#11-testing)
12. [Limitations, privacy and next steps](#12-limitations-privacy-and-next-steps)

---

## 1. What this is

There's a problem with learning from long videos: watching takes time, and the knowledge disappears into your browser history. This project turns any video link into a durable, searchable library entry.

| Feature | Details |
|---|---|
| Download | Audio (mp3) or video (mp4), from YouTube and the other ~20 sites cobalt supports (TikTok, X, Instagram, SoundCloud, Vimeo, Reddit…) |
| Transcribe | **On your Mac**, with OpenAI's Whisper *large-v3-turbo* through whisper.cpp on the GPU. Free, offline, auto-detects the language, keeps timestamps |
| Summarize | **Claude Sonnet 5.5** through the Claude Code CLI, using your Claude account login (no API key). Formats: Standard, Brief, Detailed, Bullets, ADHD-Friendly. Languages: English, same as video, **Egyptian Arabic (Masri)**, Arabic (MSA), French, Spanish, German |
| History | SQLite database: every video, every summary version, transcript and file. Search, filters, sorting, favorites, stats |
| Never destructive | Re-downloading never overwrites (`… (2).mp3`), removing history never deletes files, failed regenerations never touch saved summaries |
| Safe cancel | Cancel, Quit, or even a crash stops the job's whole process tree and cleans up its temp files |
| Raycast | Works without the app open; the app picks up Raycast runs later |

---

## 2. Daily use

### The app: `~/Applications/Video Summarizer.app`
Open it from the Dock, Spotlight, Launchpad or Raycast. The layout follows the mockup:

```
┌────────────┬───────────────────────────────────────────────────────────────────────────┐
│ Home       │  Video Summarizer                                                    ⚙    │
│ History  ◀ │  🔗 [ paste a YouTube or video link …                        ] [ Paste ]   │
│ Favorites  │  [ 🧠 Summarize ]  [ ♪ Audio ]  [ 🎞 Video ]                               │
│ Downloads  │ ┌──── History ──────────────┐ ┌─ ✅ Saved … • 306 KB ──── [Show in Finder]─┐│
│ Settings   │ │ 🔎 Search your history…   │ └─────────────────────────────────────────────┘│
│            │ │ (All)(Summaries)(Audio)   │ ┌─ thumbnail ───────┐ ┌ Summary│Transcript│Dl ┐│
│ Your Stats │ │ (Downloads)(★ Favorites)  │ │ Title             │ │ ✨ AI Summary        ││
│  12 videos │ │ ▢ Title     [Summarized]  │ │ (j) channel       │ │ 🔑 Key points        ││
│  3h 10m    │ │ ▢ Title     [Audio]   ★ ⋮ │ │ 0:19 • uploaded … │ │  • …                 ││
│  14 summ.  │ │ ▢ Title     [Downloaded]  │ │ [Reopen][Copy]    │ │                      ││
│  4 videos  │ └───────────────────────────┘ └───────────────────┘ └──────────────────────┘│
└────────────┴───────────────────────────────────────────────────────────────────────────┘
```

- **Top bar (on every screen):** paste a link, then press **Summarize** (download → transcribe → summarize → save), **Audio** (mp3 only) or **Video** (mp4).
- **Home:** recent activity. **History:** everything. **Favorites:** starred items. **Downloads:** every saved file with its size and whether it still exists. **Settings** (⌘,): summary language and format, download folder, history retention, theme, *Import from Downloads Folder…*
- **Middle column:** search (titles, channels, links, summaries and transcripts), filter chips, sort menu, and rows with a status pill (Summarized / Audio / Downloaded / Failed / Interrupted), a ★, and a ⋮ menu (also on right-click). The menu has: open summary or transcript, copy, open the original link, open the file, show in Finder, favorite, process again, remove from history.
- **Right side:**
  - a **job banner**: live steps and **Cancel** while running; success with Show in Finder; failure with Details and Retry;
  - the **detail card**: thumbnail, title, channel and followers, duration, upload date, processed date, platform, language, original link;
  - the **tabs**:
    - **Summary:** rendered Markdown, version picker, Copy, Export `.md`, and **Regenerate**, which writes a new summary from the saved transcript in any format or language.
    - **Transcript:** `[mm:ss]` rows, search, Copy, Export `.txt`.
    - **Downloads:** every file of that video, with Missing badges and *Download Again*.
- **Keyboard:** ⌘L focus the link field · ⇧⌘V paste link · ⌘↩ Summarize · ⇧⌘A Audio · ⇧⌘D Video · ⌘. Cancel · ⌘F search history · ↑/↓ move through the list.

### Raycast
The script folder is `~/Desktop/Dev/video-summarizer/raycast`. Add it in Raycast → Settings → Extensions → **+** → *Add Script Directory*. It contains:

| Command | What it does |
|---|---|
| **Summarize Video** | link (or clipboard) → mp3 → transcript → summary, shown in Raycast |
| **Download Audio (mp3)** | saves to `~/Downloads/cobalt` |
| **Download Video (mp4)** | saves to `~/Downloads/cobalt` |
| Quicklink **Open in cobalt** | `http://localhost:9001/#{clipboard}`: opens cobalt's own web page with the link filled in |

Leaving the argument blank uses the clipboard. Raycast always uses the Standard prompt in English and always saves to `~/Downloads/cobalt`.

### The cobalt web page: http://localhost:9001
This is cobalt's own interface, running on your Mac. It's good for one-off downloads with format or quality options.

---

## 3. Architecture

```
            ┌──────────────────────┐        ┌───────────────────────────┐
            │  Video Summarizer.app│        │  Raycast script commands  │
            │  (SwiftUI, SQLite)   │        │  raycast/*.sh             │
            └──────────┬───────────┘        └─────────────┬─────────────┘
       runs its bundled│copy of the scripts               │ runs the scripts in this folder
       under a process │guard (lifeline)                  │
                       ▼                                  ▼
            ┌─────────────────────────────────────────────────────────────┐
            │ raycast/summarize.sh  ── scripts/cobalt-dl.sh ── yt-dlp     │
            │        │                       │  (fallback, 3 tries)       │
            │        │                       ▼                            │
            │        │          cobalt API  http://127.0.0.1:9000         │
            │        │          (Docker container in the Colima VM)       │
            │        ▼                                                    │
            │  whisper-cli  ←  ~/.config/watch/models/ggml-large-v3-turbo │
            │        ▼                                                    │
            │  claude -p --model sonnet  (→ Claude Sonnet 5.5, cloud)     │
            └───────┬─────────────────────────────────────────────────────┘
                    ▼
   ~/Downloads/cobalt/<name>.mp3 · .transcript.txt · .transcript.json · .summary.md
                    │
   app: reads them and saves to ~/Library/Application Support/Video Summarizer/history.sqlite
   Raycast: scripts/record-history.sh appends an event to …/inbox.jsonl → the app ingests it later

   cobalt web page  http://127.0.0.1:9001  (nginx container serving vendor/cobalt/web/build)
```

| Component | What / version (as built) | Where |
|---|---|---|
| Mac | Apple M4 Max, macOS 26.6.2, MDM-managed (Jamf, Santa in *monitor* mode, SentinelOne) | |
| Colima + Lima | 0.10.3 / 2.2.0. A Linux VM (Apple Virtualization, 2 CPU, 2 GB) running Docker. Started at login by `brew services` | `~/.colima`, `~/Library/LaunchAgents/sh.brew.colima.plist` |
| Docker CLI + Compose | 29.7.1 + Compose 5.6.0 (plugin via `cliPluginsExtraDirs`), context `colima` | `~/.docker/config.json` |
| cobalt API | `ghcr.io/imputnet/cobalt:11` (11.7.1). Downloads media, turns audio into mp3, streams it back ("tunnel") | container `cobalt`, port **127.0.0.1:9000** |
| cobalt web page | cobalt's SvelteKit static site, built from source at commit `a636575` (v11.7), served by `nginx:alpine` with COOP/COEP headers | container `cobalt-web`, port **127.0.0.1:9001**, files from `vendor/cobalt/web/build` |
| yt-dlp | 2026.08.19 (Homebrew), uses `deno` 2.9.7 to solve YouTube's JavaScript challenges | `/opt/homebrew/bin` |
| ffmpeg / ffprobe | 8.1.2. yt-dlp's mp3/mp4 conversion; the app's duration probe | `/opt/homebrew/bin` |
| whisper.cpp | 1.9.2 (`whisper-cli`, ggml 0.20.2, Metal GPU) | `/opt/homebrew/bin/whisper-cli` |
| Whisper model | `ggml-large-v3-turbo-q5_0.bin` (574 MB, 5-bit large-v3-turbo). Shared with the Claude Code *watch* skill | `~/.config/watch/models/` |
| Claude Code CLI | 2.1.299. `claude -p --model sonnet` → **claude-sonnet-5-5**, signed in with your Claude account | `~/.local/bin/claude` |
| The app | SwiftUI, Swift 6.3 compiler in Swift 5 mode, macOS 15+, built with Command Line Tools only (no Xcode), ad-hoc signed | `~/Applications/Video Summarizer.app` |
| History | SQLite 3.51 (WAL), daily verified backups | `~/Library/Application Support/Video Summarizer/` |

---

## 4. The pipeline, step by step

### 4.1 `scripts/cobalt-dl.sh <url> <audio|auto> <out-dir>`
It prints the saved file's path as its last stdout line, and progress on stderr.

1. Creates a private temp folder, `mktemp -d $TMPDIR/cobalt-dl.XXXXXX`.
   - `trap 'rm -rf "$tmp"' EXIT` deletes it on every exit.
   - `trap 'exit 143' TERM INT` turns Cancel into a normal exit, so the cleanup trap runs.
2. **cobalt first.** It sends `POST http://localhost:9000/` with `{"url":…, "downloadMode":"audio"|"auto", "audioFormat":"mp3", "filenameStyle":"pretty"}`.
   - On `tunnel` or `redirect`, it downloads into the temp folder.
   - **A 0-byte result counts as a failure.** For most YouTube videos cobalt says "tunnel" but streams nothing.
3. **yt-dlp fallback.** On any failure it prints `cobalt: <reason>, falling back to yt-dlp`, then:
   - runs `yt-dlp -x --audio-format mp3` (audio) or `-t mp4` (video) with `-P <temp>` and `--print after_move:filepath`;
   - tries **3 times**, because YouTube randomly returns 403 on about 1 in 6 tries;
   - prints `yt-dlp attempt N failed` after each failed try.
4. **Never overwrite.** `place()` moves the finished file into the output folder under a free name.
   - A name counts as taken if `<stem>.<ext>`, `.summary.md`, `.summary.md.part`, `.transcript.txt` or `.transcript.json` already exists.
   - If it's taken, the file becomes `<stem> (2).<ext>`, `(3)`, and so on.

Filenames: cobalt "pretty" names look like `Me at the zoo - jawed (youtube).mp3` and `… (240p, h264, youtube).mp4`; yt-dlp names look like `Title.mp3`.

### 4.2 `raycast/summarize.sh <url>`
The **marker lines** are a contract: the app parses them, so keep them exactly as they are.

```
⬇️  Downloading audio…            → runs scripts/cobalt-dl.sh <url> audio <out>
🎙️  Transcribing on-device…       → whisper-cli -np -l auto -m <model> -f <mp3> -otxt -oj -of "<base>.transcript"
🧠 Summarizing…                   → claude -p --model sonnet "$prompt" < <base>.transcript.txt | tee <base>.summary.md.part
                                    mv .part → <base>.summary.md   (a cancelled run never leaves a half summary)
📁 <path of the mp3>              → last line
```

- Output folder: `${VS_OUT_DIR:-~/Downloads/cobalt}`.
- The prompt is `${VS_SUMMARY_PROMPT:-<Standard>}`. Standard is exactly: *"Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways."*
- When **not** run by the app (`VS_FROM_APP` unset), it calls `scripts/record-history.sh summary <url> <mp3>` at the end.
- The scripts find each other relative to themselves (`root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)`), so the folder can move.
- whisper.cpp reads the mp3 directly (miniaudio), so there's no WAV conversion step.
  - `-oj` writes `transcript.json`: segments with millisecond offsets, plus `result.language`.
- Whisper's GPU startup messages go to a temp log, which is printed only if transcription fails.

### 4.3 `raycast/download-audio.sh` / `download-video.sh`
These run `cobalt-dl.sh` into `~/Downloads/cobalt`, then `record-history.sh audio|video`, then print `Saved <name>`.

### 4.4 `scripts/record-history.sh <kind> <url> <file>`
It appends one JSON line to `${VS_DATA_DIR:-~/Library/Application Support/Video Summarizer}/inbox.jsonl`.
- The line is `{"id": <uuidgen>, "kind", "url", "file", "at": <epoch>}`, built with **`jq -nc`**, so it's always valid JSON on one line, whatever is in the title.
- It's written under **`/usr/bin/lockf -k -t 5 inbox.jsonl.lock`** as a single `printf`, so parallel Raycast runs can't mix their lines together.
- It ends with `|| true`: Raycast never fails because of history, and never needs the app.

### 4.5 What leaves your Mac
- **The link:** cobalt or yt-dlp contact the video site.
- **The transcript text:** sent to Anthropic for the summary. The audio and video are never uploaded.
- **Your Drive:** `~/Desktop`, `~/Documents` and `~/Downloads` sync to your work Google Drive. That includes `~/Downloads/cobalt` (mp3/mp4) and this project folder.

Everything else stays local. Both containers listen only on 127.0.0.1, and the cobalt API's CORS only allows `http://localhost:9001`, so web pages you visit can't use your local cobalt.

---

## 5. Inside the app

### 5.1 Source map: `app/Sources/` (about 4,000 lines)

| File | Role |
|---|---|
| `App.swift` | `@main` entry (`--selftest` runs the tests and exits), Window and Settings scenes, menu commands and shortcuts, quit-during-job confirmation, first-launch window sizing, the window snapshot test hook |
| `AppModel.swift` | Shared state and every user action (start, retry, regenerate, favorite, remove, clear all, import, retention, copy…). Launch order: recover interrupted jobs → apply retention → daily backup → load → Raycast ingest → metadata backfill → offer import |
| `Models.swift` | `Video`, `Job`, `NewJob`, `VideoInfo`, `Segment`, `FileItem`, filters and sorts, the whisper JSON reader, `SummaryOutputs` (reads `<base>.summary.md/.transcript.*`), formatters |
| `SQLite.swift` | Small wrapper over the SQLite C API: parameterised queries, `transaction {}` (BEGIN IMMEDIATE / COMMIT / ROLLBACK) |
| `Database.swift` | `actor Database`, the single writer, off the main thread: schema and migrations, every query, stats, crash recovery, retention, corruption handling, rotating backups |
| `HistoryStore.swift` | What the views show (list, recent, files, stats, selection), loaded asynchronously |
| `JobController.swift` | Runs one job at a time through the scripts: steps, marker parsing, output checks, saving, metadata, regenerate, cancel |
| `ScriptRunner.swift` | `Paths` (where the bundled scripts are) and `RunningScript` (the bash **lifeline guard**, line streaming, cancel) |
| `Metadata.swift` | `VideoRef` (link → identity), `FileNames` (cobalt/yt-dlp filename parsing), `MetadataFetcher` (`yt-dlp -j`, `ffprobe`) |
| `Ingest.swift` | Reads the Raycast `inbox.jsonl` and ingests events (deduplicated by event ID) |
| `Importer.swift` | Read-only import of an existing downloads folder |
| `Prompts.swift` | Summary formats and languages, prompt building, `AppSettings`, `Appearance` |
| `SelfTest.swift` | 71 checks on throwaway data; `build.sh` refuses to install if any fail |
| `TestHooks.swift` | Test-only remote control (`VS_TEST_HOOKS=1`); see [Testing](#11-testing) |
| `Views/Theme.swift` | Dark and light palettes (`#0B1220`, `#101A2B`, `#131F30`, `#087CFF`, `#19C785`, …), applies the theme |
| `Views/Components.swift` | Card style, primary and secondary button styles, chips, search field, thumbnail, status pill, avatar, `FlowLayout`, `FileOps` (open, reveal, copy, export) |
| `Views/Markdown.swift` | Block Markdown renderer (headings, bullets, numbered lists, rules, inline styling), section icons (TL;DR → "✨ AI Summary", Key points → 🔑, takeaways → ✓), right-to-left detection |
| `Views/RootView.swift` | Window layout, title row, sidebar and stats card, top bar, notices, import and remove dialogs |
| `Views/CenterColumn.swift` | History/Favorites browser, rows, ⋮ actions, recent activity, downloads list, file rows |
| `Views/DetailViews.swift` | Job banner and step list, detail card, Summary / Transcript / Downloads tabs |
| `Views/SettingsView.swift` | The Settings window |

Other app files: `build.sh`, `Info.plist` (id `local.video-summarizer`, version 2.0), `make-icon.swift` (draws the gradient icon with the SF Symbol `waveform.and.magnifyingglass`), `tests/vsctl.swift`.

### 5.2 Video identity: one entry per video
`VideoRef.parse` turns a link into a **key**:
- **YouTube:** `youtube:<11-char id>`. It understands `watch?v=`, `youtu.be/`, `shorts/`, `embed/`, `live/`, `m.`, `music.` and `www.`.
- **Other sites:** `url:<host><path><query>`, without the fragment or a trailing slash.
- **Imported files:** `file:<normalised stem>`, because their URL is unknown.

A video can have any number of **jobs**: every summary version, every audio or video download, every failed or cancelled attempt. An imported entry merges into the real video once both its title and its channel match.

### 5.3 Database schema
Location: `~/Library/Application Support/Video Summarizer/history.sqlite`. Settings: WAL, `synchronous=NORMAL`, `foreign_keys=ON`, `busy_timeout=5000`, `user_version=1`.

```sql
videos(id PK, key UNIQUE, url, platform, title, channel, channel_followers, thumbnail_url,
       duration REAL, upload_date TEXT /*yyyyMMdd from the platform, never guessed*/,
       favorite, first_processed, last_processed, last_opened)
jobs(id PK, video_id → videos ON DELETE CASCADE,
     kind summary|audio|video, status running|succeeded|failed|cancelled|interrupted,
     source app|raycast|import, event_id UNIQUE /*Raycast event id → no duplicates*/,
     started, finished, file_path, file_size, summary_path, transcript_path,
     summary, summary_language, summary_format, transcript,
     transcript_segments /*JSON [{start,end,text}]*/, transcript_language, error /*last 40 output lines*/)
meta(key PK, value)   -- inbox_offset, import_offered, last_backup
```

Rules:
- **Summaries are append-only.** Regenerate inserts a new job and never edits an old one, so a failed regeneration loses nothing.
- **Every multi-row change is one transaction.**
- **Removing history deletes rows only, never files.**
- Unknown metadata stays NULL and shows as "—" or "unknown".

Filters:
- **Summaries:** has a succeeded summary.
- **Audio:** a succeeded audio job, or any `.mp3`.
- **Downloads:** a succeeded video job.
- **Favorites:** starred.

Search uses escaped `LIKE` over title, channel, URL, summary and transcript, with a 180 ms debounce.

Stats:
- **Videos processed:** distinct videos with any succeeded job.
- **Watch time summarized:** the sum of *known* durations of videos with a succeeded summary.
- **Summaries saved:** succeeded summary jobs.
- **Videos downloaded:** succeeded video jobs.

### 5.4 A job's life (`JobController.run`)
1. Parse the link. If it's bad, show an inline error and run nothing.
2. In one transaction, upsert the video and insert a `running` job. It appears in history at once.
3. Start `yt-dlp -j --skip-download` **in parallel**. It provides the title, channel, followers, duration, upload date, thumbnail and platform, and is saved as soon as it arrives, even if the job later fails.
4. Run the bundled `summarize.sh` (or `cobalt-dl.sh`) with `VS_FROM_APP=1`, `VS_OUT_DIR=<setting>` and `VS_SUMMARY_PROMPT=<format + language>`.
5. Update the steps from the marker lines. Only lines that **start with** the marker emoji count (🎙 U+1F399, 🧠 U+1F9E0, 📁 U+1F4C1), so summary text that mentions "summarizing" can't confuse it. The step label gets "(yt-dlp fallback)" when that line appears.
6. **Check the outputs before calling it a success.** The media file must exist with size > 0, and for Summarize the `.summary.md` must not be empty. Then save the summary, transcript, segments, language, paths and size.
7. Fill gaps with fallbacks: the title and channel from the filename, the duration from `ffprobe`, the YouTube thumbnail from `i.ytimg.com/vi/<id>/mqdefault.jpg`.
8. Show the success banner, or on failure the job's last 40 output lines with a Retry button. Each failure also says why: missing file, empty summary, and so on.

**Regenerate** writes the saved transcript to a private temp file, then runs `claude -p --model sonnet "<prompt>" < transcript > summary`, and saves the result as a new version. It never downloads or transcribes again.

### 5.5 The process guard: no orphans, ever
Every subprocess runs under a small bash guard (`ScriptRunner.swift`):
- The app passes a **lifeline**: a pipe on fd 3 whose write end only the app holds (marked close-on-exec, so no other child inherits it).
- A watcher waits on `read <&3`. That returns when the app closes the pipe (**Cancel / Quit**) or when the kernel closes it because **the app died** (crash, `kill -9`).
- The watcher then takes a snapshot of the job's process tree (recursive `pgrep -P` from the job's own process ID, **never by name**, so unrelated processes are safe). It stops it in stages:
  1. **SIGTERM** to everything, parents first, so scripts stop launching their next step.
  2. After 3 s, **SIGKILL** only the non-bash programs still alive (claude, yt-dlp, whisper…), so the scripts waiting on them can still run their **cleanup traps**.
  3. After 2 more seconds, SIGKILL whatever is left.
- SIGPIPE is ignored for the job. After a crash its output pipe has no reader, and a write must fail, not kill the script before its cleanup runs.
- At launch, any job still marked `running` becomes **`interrupted`**, with Retry. Quitting during a job asks first, then stops the tree.

### 5.6 Raycast ingest
- On launch, every 3 s, and whenever the app becomes active, `Ingestor` reads `inbox.jsonl` from the saved offset.
- It only reads **complete** lines; a partial line waits for the next read. Invalid lines are skipped and counted.
- If the file shrank, it starts over from 0.
- Each event becomes a succeeded job with `source=raycast`. A summary event also brings in the summary, transcript and segments from the files next to the mp3.
- **`event_id UNIQUE`** makes replays harmless: after a crash, an offset reset or a rewritten file, nothing is recorded twice.
- If recording fails, the offset is *not* saved, so the batch is retried.
- Metadata and the duration are filled in afterwards, so new entries appear right away.

### 5.7 Import (read-only)
- The first launch offers to import `~/Downloads/cobalt`; the same import is in Settings → *Import from Downloads Folder…*
- Files are grouped by stem:
  - `X.mp3 + X.summary.md + X.transcript.txt/.json` form one run;
  - cobalt's `(youtube)` / `(240p, h264, youtube)` suffixes and our `(2)` suffix are removed, so a video's audio, video and repeat runs land in **one entry**;
  - `Title - Channel` is split only when a platform suffix proves it's a cobalt name.
- Any run whose file is already known is skipped, so importing again adds nothing.
- It **never moves, renames, writes or deletes** a file; this was verified by checksum.
- URLs stay unknown, and the duration comes from `ffprobe`.

### 5.8 Backups and corruption
- **On launch, `PRAGMA quick_check`.** A damaged database is **moved aside** as `history.corrupt-<time>.sqlite` (never deleted) and a fresh one is started. The app tells you.
- **A daily backup, which never overwrites a good copy.** `VACUUM INTO` refuses an existing file, so it always works like this:
  1. Write a fresh `backups/history-<ms>.tmp`.
  2. Open it read-only and require `quick_check = ok`.
  3. Only then rotate with atomic `rename()`: `history-backup.sqlite → history-backup.prev.sqlite`, then `.tmp → history-backup.sqlite`.
  4. If the copy fails its check, it's deleted and both existing backups stay untouched.

### 5.9 Prompts
| Format | Instruction |
|---|---|
| **Standard** (default) | exactly the Raycast prompt above |
| Brief | one short paragraph, at most 4 sentences |
| Detailed | overview, a section per topic, useful details (names, numbers, tools), takeaways |
| Bullets | key points only |
| **ADHD-Friendly** | short simple headings, 2–4 single-idea bullets of about 12 words each, a final "⭐ Key takeaways" with the 3 most important points, no filler |

Language adds one sentence, except English, which keeps Standard identical to Raycast. **Masri** is defined as *"colloquial Egyptian dialect as spoken in Cairo, in Arabic script, not Modern Standard Arabic"*. Arabic text is shown right-to-left automatically.

### 5.10 Settings (UserDefaults, not history)
The keys are `summaryLanguage`, `summaryFormat`, `downloadDir` (empty means `~/Downloads/cobalt`), `retentionDays` (0 means forever; favorites are never pruned), `appearance` (Dark / System / Light) and `didSizeWindow2`. Any of them can be overridden per launch, which is how the tests use their own folders: `open -n "…/Video Summarizer.app" --args -downloadDir /tmp/x`.

---

## 6. Where everything lives

### This folder: `~/Desktop/Dev/video-summarizer/`
```
README.md            this guide
docker-compose.yml   cobalt API (:9000) + nginx web page (:9001), localhost only; `name: cobalt`
nginx.conf           static serving + COOP/COEP headers (cobalt's in-browser ffmpeg needs them)
scripts/
  cobalt-dl.sh       download via cobalt → yt-dlp fallback; temp dir, traps, never-overwrite naming
  record-history.sh  Raycast → app history event (jq -nc + lockf)
raycast/             Raycast script directory: summarize.sh, download-audio.sh, download-video.sh
app/
  Sources/           the SwiftUI app (see §5.1)
  tests/vsctl.swift  test remote control
  build.sh           compile → bundle scripts → self-test → icon → sign → install
  Info.plist, make-icon.swift
vendor/cobalt/       git clone of imputnet/cobalt @ a636575; web/build is what nginx serves  (git-ignored)
                     node_modules was removed to keep Drive sync small: see §9 to restore it
backups/             v1 backup tarball + checksums of ~/Downloads/cobalt from 2026-10-14   (git-ignored)
.git                 history: v1 checkpoint → scripts → 2.0 → fixes → this move
```

### Outside this folder
| What | Where |
|---|---|
| Installed app (with its **own copy** of `scripts/` and `raycast/summarize.sh` in `Contents/Resources/`) | `~/Applications/Video Summarizer.app` |
| History database, backups, Raycast inbox | `~/Library/Application Support/Video Summarizer/` |
| Downloads, transcripts, summaries | `~/Downloads/cobalt/` (or the folder in Settings) |
| Whisper model | `~/.config/watch/models/ggml-large-v3-turbo-q5_0.bin` |
| Docker VM | `~/.colima/` (the VM disk lives here; images and containers are inside it) |
| Colima autostart | `~/Library/LaunchAgents/sh.brew.colima.plist` (`brew services`) |
| Docker CLI config (compose plugin dir, context) | `~/.docker/config.json` |
| Raycast script directory + Quicklink | Raycast's own settings |
| Claude login | handled by the Claude Code CLI (`claude`) |

**Why the app carries its own copy of the scripts:** `~/Desktop` is a macOS privacy-protected folder, and the app is ad-hoc signed, so macOS would ask for Desktop access again after every rebuild. The bundled copy also means the installed app keeps working wherever this folder moves. The catch: **after editing a script here, run `app/build.sh`** before the app uses the change. Raycast uses the folder copy immediately.

---

## 7. How it was built

### 2026-10-13: the question, and choosing cobalt
- **The request:** install [imputnet/cobalt](https://github.com/imputnet/cobalt) and wire it to Raycast, so a YouTube link becomes mp3 → transcript → summary in one go.
- **First recommendation: skip cobalt.**
  - It only downloads; it doesn't transcribe or summarize.
  - It needs a Docker server running all the time.
  - YouTube is its weakest source.
  - yt-dlp was already installed and does the same job.
  - That first plan used yt-dlp, whisper.cpp (the model was already downloaded for the *watch* skill) and `claude -p`.
- **Decision:** you wanted cobalt anyway, for its web page and for other uses. So the plan became cobalt as the main downloader plus Raycast commands, with a yt-dlp fallback.
- **Proving Docker works on a managed Mac.** Colima's own logs showed its VM had booted and run from 2026-09-06 to 09-10. Santa was in *Monitor* mode (`limactl` showed as "Allowed"). No MDM profile mentioned VMs or Docker, `ghcr.io` gave pull tokens, and Colima needs no admin rights. There was a backup plan of running the cobalt API on Node with no Docker; it wasn't needed.
- **Building the stack:**
  1. `brew install docker-compose`, plus `cliPluginsExtraDirs` in `~/.docker/config.json` so `docker compose` works.
  2. `brew upgrade yt-dlp` (2026.07.04 → 2026.08.19).
  3. `brew services start colima`. The `colima` docker context existed but wasn't selected, so `docker context use colima`. Then `hello-world` passed.
  4. Built the web page: cobalt doesn't publish an image for it. `git clone`, then `corepack pnpm install --filter "@imput/cobalt-web..."`, then `WEB_DEFAULT_API=http://localhost:9000/ pnpm -C web build`. It's a static SvelteKit site, and its `_headers` file showed it needs COOP/COEP headers, so nginx sends them.
  5. Compose: both ports bound to `127.0.0.1`, `API_URL=http://localhost:9000/`, and **CORS locked to the web page** (`CORS_WILDCARD=0`, `CORS_URL=http://localhost:9001`). Verified: other origins get an allow-origin that doesn't match them.
- **How YouTube really behaved:**
  - cobalt worked for "Me at the zoo" but returned **"tunnel" with 0 bytes** for a 14-minute TED talk. Measured later: it worked on 2 of 5 videos, and every TED talk failed.
  - The helper was taught to treat empty files as failures and fall back to yt-dlp.
  - cobalt's suggested fix, the `yt-session-generator` container, was tried. Its Chromium timed out ("timeout waiting for outgoing API request"), its web server never started, and its repo was last updated in 2025-03, so it was **removed**.
  - yt-dlp itself hit random **403s, about 1 in 6 tries**, so it now retries up to 3 times. YouTube also throttles it to about 120 KiB/s.
- **Raycast:** three script commands plus a Quicklink.
  - Raycast doesn't load your shell profile, so every script exports `PATH`.
  - whisper-cli can read mp3 directly, which removed an ffmpeg WAV step.
  - A 14-minute talk took **1 min 33 s** end to end.
- **v1 of the app:** a ~200-line single-file SwiftUI window that ran the same scripts and parsed their markers.
  - Built with `swiftc` from the Command Line Tools, with an icon drawn in code and ad-hoc signing.
  - Tested by clicking it through System Events accessibility (which was allowed back then).

### 2026-10-14: Video Summarizer 2.0
- **Brief:** the dark mockup (sidebar, history browser, detail panel, stats), persistent history, search, filters, favorites, a transcript viewer, real stats, safe cancellation, Raycast capture.
- **Your revisions:**
  - non-destructive import;
  - the top toolbar on every screen;
  - Egyptian Arabic and ADHD-Friendly;
  - safe database writes, no duplicate Raycast events, recovery after restart;
  - `jq -nc` with locked appends;
  - backup rotation that never targets an existing file;
  - a force-quit test that checks for orphaned processes.
- **Protect first:** a tarball of v1, a checksum list of `~/Downloads/cobalt`, `git init` and a "checkpoint: v1 working" commit.
- **Script changes, all additive** (same arguments, markers and output): temp-folder downloads with traps, never-overwrite names, whisper `-oj`, `VS_OUT_DIR` / `VS_SUMMARY_PROMPT` / `VS_FROM_APP`, the atomic `.part` summary, and `record-history.sh`.
- **Why SQLite and not SwiftData:** SwiftData's `@Model` macro needs a compiler plugin that only ships with Xcode. The Command Line Tools have only the Observation, SwiftMacros and Testing plugins. `import SQLite3` works, so persistence is a small wrapper plus a single-writer actor.
- **How it was tested:**
  - The **selftest** (§11).
  - A **standalone guard harness**, which ran nested process trees and then cancelled them or `kill -9`'d the parent.
  - Accessibility scripting had been blocked by then ("osascript is not allowed assistive access", -25211). So the app got **test hooks**: distributed notifications that call the same model methods as the buttons, plus a JSON state dump.
  - A **window snapshot** via `cacheDisplay`, which works without Screen Recording permission.
- **Bugs the tests found, and the fixes:**
  - After a crash, the job's next write to its dead output pipe killed bash with **SIGPIPE** before its cleanup trap ran, leaving temp files. → The guard ignores SIGPIPE, so the job exits through its traps.
  - Cancelling while **claude** took more than 3 s to exit meant SIGKILL hit `summarize.sh` too, leaving a `.summary.md.part`. → Staged escalation: kill the programs first, give the scripts 2 s to clean up, then kill the rest.
  - Cancelled or crashed jobs left entries **"Untitled"**. → Metadata is saved as soon as it arrives, and a launch backfill fills the gaps.
  - **Disabled buttons looked enabled.** A ButtonStyle reads `isEnabled` from where the style was applied, not from the button. → It's now read in an inner view. (Naming that inner view `Body` collided with ButtonStyle's own `Body` type.)
  - Watch time showed "0 min" for 19 s (→ seconds under a minute). The banner was missing the duration (it was built before the metadata reload). Detail buttons wrapped onto two lines (→ smaller font, one line).
  - Version 2.0 inherited v1's tiny window. → It sizes itself once on first launch.
  - **The Downloads privacy prompt** blocks reads of `~/Downloads` until answered, which made Raycast ingest look stuck. Every rebuild re-asks, because of the ad-hoc signature.
  - Test mistakes, caught and corrected:
    - "search escapes %" was wrong, because the test transcript contains "50%". It now tests `_` instead.
    - `pgrep -x claude` matched the Claude Code session running the tests, so child processes are now checked by tree.
- **Measured results:** see §11.

### 2026-10-15: which model writes the summaries
`claude -p --model sonnet --output-format json` reports `modelUsage: claude-sonnet-5-5`. `sonnet` always means the newest Sonnet; change the word in `raycast/summarize.sh` and `JobController.swift` to pin a version or use Opus or Haiku.

### 2026-10-18: moved to `~/Desktop/Dev/video-summarizer`
1. `~/cobalt` was moved here. Its cobalt clone `src/` became `vendor/cobalt/`, and its `node_modules` (271 MB, ~26,000 files) was deleted, because Desktop syncs to Google Drive. The helper scripts went to `scripts/`, and `~/cobalt-backups` became `backups/`.
2. The scripts became location-independent. The app now **bundles** its scripts, which removed every hardcoded `~/cobalt` path.
3. Compose got `name: cobalt` and the new mount path, and `cobalt-web` was recreated. I checked first that the Colima VM can read files under Desktop.
4. Checked after the move: the self-test (71/71); Summarize in the app (run from the bundled scripts); Raycast `summarize.sh` from the new folder with no `~/cobalt`; both download scripts finding their helpers; your downloads and history unchanged.

---

## 8. Setting it up from scratch

On a new Mac, roughly in this order:

```bash
# 1. tools
brew install colima docker docker-compose yt-dlp ffmpeg whisper-cpp jq deno
#    (Node with corepack, e.g. via fnm, is only needed to rebuild the cobalt web page)

# 2. docker compose plugin + start the VM at every login
mkdir -p ~/.docker
cat > ~/.docker/config.json <<'EOF'
{ "auths": {}, "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"] }
EOF
brew services start colima
docker context use colima
docker run --rm hello-world

# 3. this project
cd ~/Desktop/Dev/video-summarizer          # or wherever you keep it

# 4. cobalt's web page (skip if vendor/cobalt/web/build already exists)
git clone https://github.com/imputnet/cobalt vendor/cobalt
git -C vendor/cobalt checkout a636575      # the version this was built and tested with
cd vendor/cobalt
COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm install --frozen-lockfile --filter "@imput/cobalt-web..."
WEB_DEFAULT_API=http://localhost:9000/ WEB_HOST=localhost COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm -C web build
cd ../..

# 5. start cobalt (API :9000, web page :9001)
docker compose up -d
curl -s localhost:9000/ | jq .cobalt.version       # → "11.7.1"
curl -sI localhost:9001/ | grep -i cross-origin    # → COOP + COEP headers

# 6. the Whisper model (574 MB)
mkdir -p ~/.config/watch/models
curl -L -o ~/.config/watch/models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin

# 7. Claude Code CLI, signed in to your Claude account
claude            # log in once, then quit

# 8. the app (needs Xcode Command Line Tools: xcode-select --install)
bash app/build.sh                                   # builds, self-tests, installs to ~/Applications
open ~/Applications/"Video Summarizer.app"
```

Then, in **Raycast:**
1. Settings → Extensions → **+** → *Add Script Directory* → choose this folder's `raycast/`.
2. *Create Quicklink*: name `Open in cobalt`, link `http://localhost:9001/#{clipboard}`.

On first use macOS asks for **Downloads** access (the app; Raycast) and **Desktop** access (Raycast, because it runs the scripts from here). Click **Allow**.

---

## 9. Operations

All commands run from this folder.

| Task | Command |
|---|---|
| Status | `docker ps` · `colima status` · `curl -s localhost:9000/ \| jq .cobalt.version` |
| Stop / start cobalt | `docker compose stop` / `docker compose up -d` (it also starts by itself at login) |
| Stop the VM completely | `colima stop` (Raycast and the app then use yt-dlp) |
| Update the cobalt API | `docker compose pull && docker compose up -d` (Watchtower, cobalt's usual auto-updater, was archived in 2025-12, so updates are manual) |
| Update yt-dlp (when YouTube breaks it) | `brew upgrade yt-dlp` |
| Update the cobalt web page | `git -C vendor/cobalt pull`, then rerun step 4 of §8. That reinstalls `node_modules` first, which is the one command that brings it back. nginx serves the new files immediately |
| Rebuild the app | `bash app/build.sh` (after editing `app/Sources` **or any script**). It refuses to install if the self-test fails |
| See a job's error | the banner's **Details**, or `sqlite3 ~/Library/Application\ Support/Video\ Summarizer/history.sqlite "select error from jobs where status='failed' order by id desc limit 1"` |
| cobalt logs | `docker logs --tail 50 cobalt` |
| Look at the history | `sqlite3 -header ~/Library/Application\ Support/Video\ Summarizer/history.sqlite "select title, channel, round(duration) from videos order by last_processed desc"` |
| Restore the history from a backup | Quit the app. Move `history.sqlite`, `-wal` and `-shm` aside. Copy `backups/history-backup.sqlite` (or `.prev`) to `history.sqlite`, then reopen the app |
| Save your work | `git add -A && git commit -m "…"` |

---

## 10. Troubleshooting

| Symptom | Cause, and what to do |
|---|---|
| A step says "(yt-dlp fallback)" | Normal for YouTube: cobalt often streams 0 bytes. yt-dlp takes over |
| "Processing failed" with `HTTP Error 403` three times | YouTube's bot checks. `brew upgrade yt-dlp`; retry later. The long-term fix is the `bgutil-ytdlp-pot-provider` plugin for yt-dlp |
| A job seems stuck at the start, or an import says "Importing…" forever | A macOS privacy prompt is waiting (Downloads or Desktop folder access), possibly behind other windows. Click **Allow**. Every rebuild of the app re-asks, because of the ad-hoc signature |
| Raycast: "command not found" | Raycast doesn't load your shell profile. The scripts export `PATH=/opt/homebrew/bin:~/.local/bin:…`; check the tools are installed there |
| Raycast commands vanished | The script directory moved. Re-add `raycast/` in Raycast settings |
| The web page shows nothing / localhost:9001 doesn't load | `colima status`; `docker compose up -d`; check `vendor/cobalt/web/build` exists |
| `docker: unknown command: docker compose` | `~/.docker/config.json` is missing `cliPluginsExtraDirs` |
| `Cannot connect to the Docker daemon` | `docker context use colima`, or `colima start` |
| A summary mentions "the watch skill" or offers follow-ups | `claude -p` loads your Claude Code skills and hooks. `--bare` would stop it but requires `ANTHROPIC_API_KEY`, which you don't use. It's harmless; edit the summary or regenerate |
| An empty or missing summary | The app never marks it saved (it checks the file). See Details; often a claude login problem: run `claude` in Terminal |
| History damaged | The app moves it aside as `history.corrupt-*.sqlite` and starts fresh. Restore from `backups/` (§9) |
| Arabic shows left-to-right | Right-to-left is detected from the first letter. Regenerate, or check the summary actually starts with Arabic text |

---

## 11. Testing

### The self-test: `app/build.sh` runs it on every build (71 checks)
- **Link parsing:** 6 YouTube link forms, rejecting non-video pages and non-http links, normalising other sites.
- **Filename parsing and grouping:** cobalt audio/video names, `(2)` repeats, yt-dlp names, file roles.
- **Prompts:** Standard is identical to the **bundled** `summarize.sh`; the bundled scripts exist and are executable; the Masri and ADHD prompts.
- **Markdown:** block parsing, right-to-left detection, duration and watch-time formatting.
- **Database:** one row per video, metadata wins over guesses, derived flags, search (summary, transcript, channel, misses, `_` and `%` escaping), filters, favorites, stats, a failed regeneration keeping the saved summary, interrupted-job recovery, Raycast event dedupe, the files list, merging imported duplicates, cascade delete that keeps files, retention keeping favorites, integrity.
- **Backups:** two rotations, both copies healthy, not due again within a day, a bad copy rejected with both backups byte-identical, no temp leftovers.
- **Corruption:** a garbage database file is moved aside, not deleted.
- **Inbox:** complete lines only, a bad line skipped, a partial line read once complete, a replay after an offset reset adds nothing.
- **Import:** 2 videos and 3 jobs from 8 files, a second scan finds nothing, files byte-identical, URLs left unknown.

Run it by hand: `~/Applications/"Video Summarizer.app"/Contents/MacOS/VideoSummarizer --selftest`

### End-to-end harness: drive the real app without touching your data
```bash
T=$(mktemp -d); mkdir -p "$T/data" "$T/out" "$T/shots"
swiftc app/tests/vsctl.swift -o "$T/vsctl"
open -n --env VS_DATA_DIR="$T/data" --env VS_SNAPSHOT_DIR="$T/shots" --env VS_TEST_HOOKS=1 \
  --env VS_WINDOW_SIZE=1640x960 ~/Applications/"Video Summarizer.app" --args -downloadDir "$T/out"
"$T/vsctl" "link https://www.youtube.com/watch?v=jNQXAC9IVRw"
"$T/vsctl" "start summary"          # or: start audio | start video
"$T/vsctl" state                    # → $T/shots/state.json (steps, banner, list, selection, jobs, files, stats)
"$T/vsctl" snapshot                 # → $T/shots/window.png
```
Commands: `link <url>`, `start summary|audio|video`, `cancel`, `select <title text>`, `favorite`, `search <text>`, `filter All|Summaries|Audio|Downloads|Favorites`, `sort <name>`, `section Home|History|Favorites|Downloads`, `tab Summary|Transcript|Downloads`, `regenerate <Format>|<Language>`, `import`, `declineImport`, `remove`, `clearAll`, `reload`, `settings`, `snapshot`, `state`.

`VS_DATA_DIR` keeps the history in the temp folder, and `-downloadDir` the files. `VS_SCRIPTS_DIR` points the app at another copy of the scripts.

### What has been verified on this Mac (2026-10-14 → 10-18)
- **Summarize** through the app: every step, metadata from yt-dlp, 3 timestamped segments, all files.
- **History survives** rebuilds and relaunches; opening an entry starts **no** processes.
- **Favorites** survive a relaunch; search, filters and sort work.
- **Re-downloading** creates `(2)` files and leaves the originals byte-identical.
- **Regenerate** in Masri + ADHD (real colloquial Egyptian, right-to-left). Cancelling a regeneration leaves the saved summaries unchanged.
- **Cancel** during download, transcription and summarization: every process in the tree gone within 3 s, no temp folders, no `.part` files, the job `cancelled`, a decoy process untouched.
- **`kill -9` of the app** during download and transcription: every process in the tree gone within 0.3 s, no orphans; after relaunch the job shows `interrupted` and the database passes `quick_check`.
- **Missing files:** badge shown, Open disabled, summaries kept.
- **Raycast** scripts with the app closed: 22 events ingested once; a replay and a truncated inbox add no duplicates; 20 parallel `record-history.sh` calls give 20 valid lines.
- Stats match SQL; the yt-dlp fallback works with cobalt stopped; Clear All and Remove keep files.
- **Import** of a copy of the real downloads folder: correct groups, a second import adds nothing, files byte-identical, a later URL run merges the entry.
- **After the move (10-18):** all of the above re-checked for the changed paths. The app runs `…/Video Summarizer.app/Contents/Resources/scripts/cobalt-dl.sh`.

### Not verified
- **Real mouse clicks and keyboard shortcuts.** Accessibility scripting is blocked in the terminal that ran the tests.
- **The Light theme**, the **save dialogs**, and how the **import alert** and the **Settings window** look (the window snapshot renders those blank).

---

## 12. Limitations, privacy and next steps

**Limitations**
- **YouTube through cobalt mostly fails** (0-byte tunnels), and yt-dlp is throttled and occasionally gets 403. It works, but it's slow.
- **Ad-hoc signing** means macOS re-asks for folder permissions after every rebuild.
- **Summaries can mention your Claude Code skills.** `--bare` needs an API key.
- **No download-quality option**, because the scripts don't take one.
- **No notes or tags.**
- **Imported entries** have no original link and use placeholder thumbnails.
- **Leftovers from cancelled jobs:** files a cancelled job *finished* (an mp3, a transcript) stay on disk but aren't in history; use Import to pick them up.
- **Raycast ignores the app's settings:** it always uses `~/Downloads/cobalt` with Standard in English.
- **One job at a time** in the app.

**Privacy and security**
- Both containers listen on 127.0.0.1 only, and the cobalt API's CORS only allows the local web page.
- The audio stays on your Mac; only the transcript goes to Anthropic.
- Your Desktop, Documents and Downloads sync to your **work Google Drive**. That includes downloaded media and this project folder.
- No secrets are stored in this project.

**Next steps**
1. A stable self-signed code-signing certificate, so permission grants survive rebuilds.
2. The `bgutil-ytdlp-pot-provider` plugin for yt-dlp: faster, more reliable YouTube.
3. Notes and tags on videos, and exporting a summary with its notes.
4. Clickable transcript timestamps that open the video at that moment.
5. A Raycast command to search the history.
