# Video Buddy: a personal video-learning library for macOS

*Watch smarter. Learn faster.* (Called **Video Summarizer** until version 2.1; the project folder, data folder and bundle ID keep that name.)

Paste a video link and get:
- an **mp3**,
- an **on-device transcript** with timestamps,
- an **AI summary** written by Claude,
- a permanent, searchable **history** of everything you've watched and learned,
- **playlists kept together** as collections, like albums in Apple Music (3.1): a 36-episode series is one collection of 36 episodes everywhere in the app.

You can use it three ways: a native macOS app (**Video Buddy.app**), three **Raycast** commands, or a self-hosted **cobalt** web page for downloads.

It also works **offline**, for example on a plane: downloaded videos play inside the app, saved summaries and transcripts stay readable and searchable, and transcription runs on the Mac. Anything that needs the internet waits in a queue until you're back online.

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
| Download | Audio (mp3) or video (mp4), from YouTube and the other ~20 sites cobalt supports (TikTok, X, Instagram, SoundCloud, Vimeo, Reddit…). Video quality setting: 720p / 1080p / Best |
| Transcribe | **On your Mac**, with OpenAI's Whisper *large-v3-turbo* through whisper.cpp on the GPU. Free, offline, auto-detects the language, keeps timestamps |
| Summarize | **Claude Sonnet 5.5** through the Claude Code CLI, using your Claude account login (no API key). Formats: Standard, Brief, Detailed, Bullets, ADHD-Friendly. Languages: English, same as video, **Egyptian Arabic (Masri)**, Arabic (MSA), French, Spanish, German |
| History | SQLite database: every video, every summary version, transcript and file. Search, filters, sorting, favorites, stats |
| Never destructive | Re-downloading never overwrites (`… (2).mp3`), removing history never deletes files, failed regenerations never touch saved summaries |
| Safe cancel | Cancel, Quit, or even a crash stops the job's whole process tree and cleans up its temp files |
| Raycast | Works without the app open; the app picks up Raycast runs later |
| Watch offline (2.1) | Built-in player in the detail panel: full screen, Picture in Picture, speed 0.75×–2×, ±10 s. **Resumes where you stopped.** The transcript highlights the line being spoken, and clicking a line jumps there |
| Offline mode (2.1) | Detects when there's no internet, including Wi-Fi that's "connected" but stuck at a login page. Downloads and summaries **wait in the queue** and start by themselves when you're back online. "On this Mac" filter, thumbnails saved locally, *Make Available Offline* |
| Queue (2.1) | Add as many jobs as you like; they run one at a time and are **saved in the history**, so the queue survives quitting and crashes. Pause, resume, remove, clear |
| Playlists (2.1) | Paste a YouTube playlist link: a preview with checkboxes, then Summarize / Audio / Video for all of them. **My Playlists**: create, add, drag to reorder, **Play All**, *Make All Available Offline* |
| Video Buddy look (3.0) | Black, grey and red, after Apple Music's dark theme (`design/reference.png`). Library \| big player \| AI panel, summaries as **TL;DR / Key Points / Action Takeaways cards**, a **mini-player** along the bottom in every section, a **Queue** section with **Failed → Retry**, *Continue watching* on Home, playlist artwork, the video's **description and tags** in *About this video* |

---

## 2. Daily use

### The app: `~/Applications/Video Buddy.app`
Open it from the Dock, Spotlight, Launchpad or Raycast. The layout follows `design/reference.png` (screenshots of the real app are in `design/screenshots/`):

```
┌──────────────┬──────────────────────────────────────────────────────────────────────────────┐
│ ▶ Video Buddy│ 🔗 [ Paste a YouTube or video link…     📋 ] [🎥 Video] [♪ Audio] [✨ Summarize] ☑ + Transcript │
│ Watch smarter│ ┌ Processing: <title>  ✔ Download ━━ ◉ Transcribe ━━ ③ Summary ── ④ Save   [Cancel] ┐ │
│              │ └──────────────────────────────────────────────────────────────────────────┘ │
│ ■ Home       │ 🔎 Search…   [≡]   ┌───────────────────────────┐ ┌ Summary Transcript Downloads ┐│
│   Library    │ (All)(Summaries)   │        16:9 player        │ │ ┌ 📄 TL;DR ─────────────┐ ││
│   Favorites  │ (Audio)(Video)     │      ▶  (Apple controls)  │ │ │ …                     │ ││
│   Playlists  │ (Offline)(♥)       └───────────────────────────┘ │ └───────────────────────┘ ││
│   Downloads  │ Continue watching   Title                   ★   │ ┌ ☰ Key Points ─────────┐ ││
│   Queue    ③ │ ▢ ━━━━━━──         (A) Channel • 423K subs      │ │ ① …  ② …  ③ …         │ ││
│   Settings   │ ▢ Title      ★     🕘 45:07 📅 Dec 15 ▶ YouTube  │ └───────────────────────┘ ││
│ My Playlists+│   Channel    ⋮     [▶ Play][Finder][Link][♥][⋯] │ ┌ 💡 Action Takeaways ──┐ ││
│ ▢ Series 35  │   45:07 [Summarized] About this video ▾          │ │ ✔ …  ✔ …              │ ││
│ Learning Stats│                    description… Show more · tags│ └───────────────────────┘ ││
│ 36 · 4 · 35  │ ┌ ▢ Title  ⏮ ⏯ ⏭  0:09 ━━━━●━━━━ 0:14   🔊 ━━●  ☰  ✕ ┐ (mini-player)            │
└──────────────┴──────────────────────────────────────────────────────────────────────────────┘
```

- **Top bar (every screen), in this order: link field → Video → Audio → Summarize → + Transcript.**
  - **Video** and **Audio** are the charcoal buttons; **Summarize** (download → transcribe → summarize → save) is the red one. Their actions and shortcuts are the same as before; only the order changed in 3.0.
  - The paste button is the 📋 icon inside the field (or ⇧⌘V); ✕ clears the field.
  - **☑ + Transcript**: when it's ticked, Audio and Video also transcribe the file on this Mac afterwards, with no summary and no Claude. So you choose *just the media* (to watch, or listen) or *media + transcript* (for topics you'll want to read or search). Summarize always makes its transcript. The checkbox is remembered between launches, and the playlist preview has the same one.
  - Narrow windows show the buttons as icons only, in the same order.
- **Sidebar:** the logo, **Home · Library · Favorites · Playlists · Downloads · Queue · Settings** (the selected one in dark red; **Queue** has a red badge with the number of jobs waiting plus the one running), **My Playlists** (artwork = the first video's thumbnail, the name and "N videos", **+** for a new one, right-click to rename or delete), and **Learning Stats** from the database: videos processed, summaries generated, **videos offline** (entries with a *video* file on this Mac; audio-only doesn't count, 3.1), learning time (the length of the videos you've summarized). Under ~1360 points wide it folds to icons; the button at the bottom folds it by hand.
- **Every section keeps the player and the AI panel**; only the left column changes:
  - **Home:** **Your Playlists** (3.1: album-style cards with the artwork, name, "N videos • M offline", a red ▶ and *Continue: episode N*; click a card to open the playlist), **Continue watching** (up to 3 entries you stopped part-way through, with a red progress bar and, for a playlist, "playlist • Episode N"; click to resume), then the library list.
  - **Library:** everything. **Favorites:** starred entries.
  - **Playlists**, **Downloads**, **Queue:** see below. **Settings** uses the whole area (also ⌘, in its own window).
- **Grouped | All Videos (3.1)**, under the search field in Home, Library and Favorites (remembered between launches; Grouped by default):
  - **Grouped:** each playlist is one collapsible **album row**: artwork, name, "36 videos • 34 offline", a chevron, and a red ▶ (**Continue** where you are in it, else **Play All**). Click the row to open it: its episodes in playlist order with **episode numbers**, each a normal row (open, ★, play, summarize, transcribe, download, ⋮). Everything that's in no playlist is under **Individual Videos**. A video in two playlists shows under both; it's still one record.
  - Search, the chips and Favorites work the same in both modes: grouped shows what matches *under its playlist* ("4 of 36 videos"), and groups open by themselves while you search. Searching a **playlist's name** finds all its videos.
  - **All Videos:** the flat list, as in 3.0.
  - Thumbnails show how far you got: a red bar part-way, a ✓ when finished, nothing before you start.
- **The library list:** search (titles, channels, links, summaries, transcripts and, from 3.1, playlist names), the **≡** button (sort: recent, oldest, duration, title, plus *Clear All History…* with its confirmation), the chips **All · Summaries · Audio · Video · Offline · ♥** (Favorites), and rows with the thumbnail, title, channel, duration, a status pill, ★ and ⋮ (also on right-click). The selected row is dark red with a red border. ↑/↓ move through the list.
  - **Status pills:** Processing, Queued, **Summarized**, **Available Offline** (a video file is on this Mac right now), **Audio Offline** (3.1: only an mp3 is here), **File missing** (it was downloaded but isn't there any more), Cancelled, Interrupted, Failed. A small ⬇ badge on a summarized entry's thumbnail means it's on this Mac too.
  - The ⋮ menu: Play, open summary or transcript, copy summary / transcript / link, open the original link, open the file, Show in Finder, favorite, Add to Playlist ▸, **Show in Playlist “…”** (3.1), Make Available Offline, Transcribe on This Mac, Process Again, Remove from Library.
- **The video column:** the 16:9 player (Apple's own controls over the picture: play/pause, scrubbing, time, volume, **full screen**, **Picture in Picture**), then ±10 s and the **speed** menu (0.75×–2×), the title with ★, for a playlist video a red **"Episode 4 of 36 • playlist"** link (3.1, opens the playlist), the channel's initial, name and subscribers, duration · upload date · platform, and **Play · Show in Finder · Copy Link · Favorite · ⋯**.
  - **About this video:** the platform's description (3 lines, *Show more*) and its tags. *Show more* also shows the processed date, transcript language, the original link and *Make Available Offline*. Entries saved before 3.0 have no description yet: **Load details** reads it with yt-dlp (metadata only, nothing is downloaded, no AI).
  - Your place is saved every few seconds, on pause and on quit, so the next play **resumes** there (the last 5% of a video, at most 10 s, counts as finished and starts over). mp4/m4v/mov/mp3/m4a/aac/wav play inside; other formats open in QuickTime/VLC. For an mp3 the picture stays and the mini-player has the controls.
- **The AI panel:** **Summary · Transcript · Downloads** (red underline).
  - **Summary:** the Markdown split into **cards** at its headings: **TL;DR**, **Key Points** (numbered red circles), **Action Takeaways** (red ticks), and any other section (red dots). A summary without headings (Brief, Bullets) is one card. Above the cards: the version picker, format • language, Copy, Export `.md`, and **Regenerate** (any format or language, from the saved transcript). Arabic and Masri summaries lay out right-to-left, cards included.
  - **Transcript:** timestamped rows, search, Copy, Export `.txt`. While the video plays, the spoken line is highlighted and kept in view (*Follow playback*); **click a line to jump there**.
  - **Downloads:** every file of that video with its format (MP4/MP3), size, Available/Missing, Open, Show in Finder and *Download Again* for a missing file.
  - There's no Chapters tab: the app doesn't save chapter data yet.
- **The processing strip** (under the top bar, only when there's work): the job's thumbnail and *"Processing: title"*, its **real stages** in order (✔ done, a moving bar on the one running, numbers for the ones to come: Summarize has 4, Audio/Video and Transcribe have 2), **Queue (N)** and a red **Cancel**. No percentages or time estimates, because the scripts don't report any. The same strip shows success (Show in Finder), failure (Details, Retry), cancelled, *"Queue paused"* (Resume) and *"Waiting for internet"*.
- **The mini-player** (bottom, in every section while something is loaded): thumbnail, title and channel, or for a playlist **"4 of 36 • playlist"** (3.1) (click to show that entry), ⏮ (back to the start, or in the first 3 seconds to the previous Play All item), ⏯, ⏭ (the next Play All item), a red position slider, the times, **volume**, **Up Next** (the Play All list) and ✕. It drives the same player as the video column, so only one thing ever plays.
- **Queue section:** *Running now* (stages and Cancel), *Waiting* (numbered, remove one, **Pause/Resume**, **Clear**; 3.1: consecutive jobs from one playlist sit under a header such as *"Series • 1 downloading • 5 queued • 2 failed • 34 of 36 offline"*, rows say "Episode 8 • Download video", and the numbers stay the real queue order) and **Failed** (the latest failed or interrupted job of each kind per entry, with **Retry**; it leaves the list once it's retried or done again).
- **Downloads section (3.1):** *"N videos offline • N files • size • free space"*, search (also by playlist name), **All · Available · Missing**, then the files **grouped by playlist** (then *Individual Downloads*). A playlist's header: *"34 of 36 videos downloaded • 2 missing • 22.9 GB"*, *Available offline / Partly offline*, and ⬇ **Download Missing**. Inside, **one row per video** with each of its files as a line (MP4 • 692.8 MB • Available, MP3 • Missing → *Download Again*), so two downloads of one video are still one video. Counts are unique videos, and an mp3 never counts as the video being offline.
- **Settings:** summary language and format, download folder, **video quality**, history retention, *Import from Downloads Folder…*, *Show Database in Finder*, theme (Dark / System / Light).
- **Offline (2.1):** with no internet a strip says what still works. Video / Audio / Summarize still accept links: they go into the queue and start when you're back online. *Transcribe on this Mac* works offline for any entry with a local mp3 or mp4, and a summary of a saved transcript can be requested offline and runs later.
- **Queue (2.1):** the buttons never block; extra jobs wait their turn. **Cancel** stops the current job and pauses the queue; **Resume** continues.
- **Playlists (2.1, collections since 3.1):**
  - Paste a playlist link (`youtube.com/playlist?list=…`) and press Summarize, Audio or Video. The preview lists every video with its number, duration and **what you already have** (*On this Mac*, *Audio on this Mac*, *In library*), with private and deleted videos greyed out. Only videos **not in your library at all** are ticked, so pasting a playlist you already downloaded never downloads it again. **Save to** picks the playlist with the same YouTube link automatically (or a new one, or any other). Saving links *every* library video of that YouTube playlist to it by its video ID, ticked or not; ticked ones are queued. With nothing ticked the button is **Link N Library Videos**, which downloads nothing.
  - A watch link that's part of a playlist (`watch?v=…&list=…`) asks: **Just This Video** or **Whole Playlist…**
  - **The playlist page** (Playlists, a card on Home, or *My Playlists*): large artwork, the name, *"36 videos • 26h 45m • 34 downloaded"*, **Play All**, **Continue Ep N**, **Download N Missing** (only videos with no video file here, after a confirmation with the total length and free disk space; ones already queued are left out), **Add Videos** (tick library videos, or **From Folder…** to tick the ones whose files are in a folder you choose), and ⋯ → Rename, **Check Against YouTube…**, Open on YouTube, Delete. Below: the numbered episodes; drag to reorder.
  - **Check Against YouTube** reads the playlist's saved link (metadata only) and opens the same preview with **nothing ticked**: *Link N Library Videos* adds the videos you already have by their YouTube ID. Your order stays: each new one goes next to its YouTube neighbour.
  - **Play All / Continue / ▶ on any playlist video** play inside that playlist: ⏭ and ⏮ move through its episodes on this Mac, Up Next lists the rest. A video in no playlist plays on its own, as before. **Continue** resumes the episode you stopped in; if you finished it, the next one on this Mac you haven't finished.
  - Deleting a playlist never touches its videos, summaries, history or files. Any video's ⋮ menu has *Add to Playlist ▸* and, inside a playlist, *Remove from This Playlist*.
- **Keyboard (unchanged in 3.0):** ⌘L focus the link field · ⇧⌘V paste link · ⌘↩ Summarize (and Return in the link field) · ⇧⌘A Audio · ⇧⌘D Video · ⌘. Cancel · ⌘F search the library · ↑/↓ move through the list · **⌘K play/pause · ⌘[ back 10 s · ⌘] forward 10 s** (Playback menu; ⌘[ and ⌘] were chosen over ⌘←/⌘→ so the link field keeps its normal cursor keys).

### Trying 4.0: `~/Applications/Video Buddy 4.0 Preview.app` (branches `feature/4.0-phase1-browser` → `phase2-tabs` → `phase3-watch-later` → `phase4-offline-hub` only)
A separate app for trying the YouTube browser before it reaches the real one.
- **Open it:** Finder → Applications, or Spotlight "Video Buddy 4.0". It opens straight into the **YouTube** section. Quit and reopen it like any app.
- **Telling the two apart:**
  - the icon has an amber **PREVIEW** band;
  - the menu bar and window title say *Video Buddy 4.0 Preview*;
  - the sidebar says **"4.0 Preview · downloads off"**;
  - 3.1 has no YouTube section.
- **Isolated:**
  - bundle ID `local.video-summarizer.preview`, process `VideoBuddyPreview`;
  - library and downloads in `~/Library/Application Support/Video Buddy 4.0 Preview/`;
  - its own settings domain and its own WebKit data (cookies, sign-in) under that bundle ID;
  - it never reads 3.1's library, downloads folder or Raycast inbox.
- **Locked queue:** nothing it queues ever runs. No downloads, transcripts or AI summaries, and Resume is hidden; this is checked by self-tests inside the bundle before it installs.
- **Samples:** its library holds 7 labelled samples (`[fixture: …]`) so the bar's "already here" states can be tried, e.g. *Me at the zoo* → Play Offline. *Clear All History* in the preview removes them.
- **Tabs (Phase 2):**
  - **Open and close:** ⌘T new tab, ⌘W closes the tab (not the window), ⌘⇧T reopens the last closed tab (the last 20, until you quit).
  - **Switch:** click a tab, ⌃Tab / ⌃⇧Tab or ⌘⇧] / ⌘⇧[, ⌘1–⌘8, ⌘9 for the last tab.
  - **Arrange:** drag a tab to move it; right-click a tab for Duplicate, Move Left / Right, Close.
  - **Links:** ⌘-click or middle-click a YouTube link to open it in a tab behind (⌘⇧-click: in front). Links that open a new window open a tab. The page's right-click menu says *Open Link in New Tab* and has no Download items.
  - **What a tab shows:** the video's thumbnail and title, a green check when the video is on this Mac, a clock when it's queued, a speaker while it plays (click it to pause).
  - **The bar** above the page is always about the **active** tab's video; a click that arrives after you switched tabs (or after the page moved on) queues nothing and says so.
  - **Sleeping tabs:** at most 4 tabs keep a web page loaded; the others sleep and reload where they were (history and scroll position) when you select them. Tabs opened behind and restored tabs start asleep. Idle tabs out of sight use no CPU.
  - **Restart:** your tabs come back after quitting or a crash (`browser/tabs.json` in the preview's data folder: addresses, titles and WebKit's saved history; no cookies). They wake one at a time as you select them.
  - **Background audio:** Settings → YouTube → *Keep YouTube audio playing in background tabs and other sections* (off by default). Either way only one thing plays at a time.
- **Watch Later (Phase 3):**
  - **Save:** on a YouTube video, **Save to Watch Later** (first in the bar) or ⌘D; right-click any tab, even one asleep, for Save / Remove. Nothing is downloaded; one video is never saved twice (watch, youtu.be, Shorts and `&list=` links are the same video).
  - **Saved:** the bar then says **In Watch Later** (click: the page; right-click: remove).
  - **The page** (sidebar → Watch Later): search, sort (newest, oldest, title, channel, longest), select several (⌘A, ⇧/⌘-click) for Open in Tabs or Remove, Delete to remove, right-click for more. Each row shows its thumbnail, channel, duration, when you added it, and what this Mac has (video, audio only, summary, queued, downloading, failed, file missing, not downloaded), with **Play Offline**, **Play Audio** or **Open in YouTube**.
  - **Titles:** the page's own, the library's, or a lookup's (yt-dlp metadata, nothing downloaded); until then "Getting details…" or "Title unavailable", with the video's link.
  - **Offline:** everything shows from the saved details and thumbnail copies; Open in YouTube waits for internet; Play Offline works.
  - **Separate from the Library:** Clear All History, removing a library video and retention keep Watch Later; removing from Watch Later never touches files. To download a saved video, open it and use the bar (it asks for your authorization as before).
- **Offline Hub (Phase 4), in Downloads:**
  - **Ready / Problems / Preparing / All:** every registered file (downloaded, from Raycast or imported) with its quality, size and length, and its video's summary and transcript. **Check Files** runs the quick check (it opens and plays on this Mac); right-click a file for the **deep check** (every frame decoded). Neither changes a file, and the quick check never claims "no corruption".
  - **Problems:** a missing file shows **Relink…** when a file of the same name and size is in the downloads folder, and **Locate…** otherwise; the record (and the resume position) changes only after you confirm. Damaged and missing files offer Download Again.
  - **Prepare for Offline** (Downloads, Watch Later's selection bar, a playlist's Prepare Missing, the playlist import sheet): each video checked one at a time, video, audio and summary shown separately, Video or Audio, **Declare…** per video, sizes known / ≈ / unknown, quality per batch ("up to 720p", "720p (its best)"), the keep-free reserve, totals and whether they fit. Only **Queue N Downloads** queues, and each row is checked again then.
  - **The download checks everywhere in the app:** the link field and its shortcuts, Make Available Offline, Download Again, Process Again and Retry go through the same checks as the browser bar for YouTube videos; the database itself refuses a YouTube download without a declaration; the queue checks once more before it starts one. On-device work and other sites are unchanged.
  - **Settings → Downloads:** keep 5 / 10 / 20 / 50 GB free (best effort for unknown sizes), and **Download only on Wi-Fi or Ethernet** (it can't recognise every metered network; see the note there).
  - **In the Preview nothing downloads:** queued items wait.
- **Rebuild:** `app/tools/preview.sh` (on the branch). `app/tools/preview.sh --test DIR` builds the same app as *Video Buddy 4.0 Test*, under its own identity, for test runs.
- **Remove:** `app/tools/preview.sh --remove` (its WebKit store through WebKit on a fresh launch, then its data folder and the app).

### Before a flight (2-minute checklist)
1. Online: for each video you want, press **Video** (or *Make Available Offline*, or *Make All Available Offline* on a playlist). Tick **+ Transcript** first if you'll want to search what was said. Use **Summarize** too if you want to read the summary. Settings → Video quality → **720p** fits about twice as much.
2. Check **Downloads**: the files are there, and the free space is enough.
3. Filter **Offline**: that's exactly what you can watch offline.
4. On the plane: press ▶, read summaries, search transcripts, *Transcribe on this Mac* for audio-only entries. New downloads and summaries queue up and run when you land.

### Raycast
The script folder is `~/Desktop/Dev/video-summarizer/raycast`. Add it in Raycast → Settings → Extensions → **+** → *Add Script Directory*. It contains:

| Command | What it does |
|---|---|
| **Summarize Video** | link (or clipboard) → mp3 → transcript → summary, shown in Raycast |
| **Download Audio (mp3)** | saves to `~/Downloads/cobalt` |
| **Download Video (mp4)** | saves to `~/Downloads/cobalt` |
| Quicklink **Open in cobalt** | `http://localhost:9001/#{clipboard}`: opens cobalt's own web page with the link filled in |

Leaving the argument blank uses the clipboard. Raycast always uses the Standard prompt in English and always saves to `~/Downloads/cobalt`.

**Playlist links** (`youtube.com/playlist?list=…`) stop at once with *"Playlist link: paste it into the Video Buddy app to pick videos"*. Paste them into the app instead. A video link that's part of a playlist (`watch?v=…&list=…`) still works and downloads just that video.

### The cobalt web page: http://localhost:9001
This is cobalt's own interface, running on your Mac. It's good for one-off downloads with format or quality options.

---

## 3. Architecture

```
            ┌──────────────────────┐        ┌───────────────────────────┐
            │  Video Buddy.app     │        │  Raycast script commands  │
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
            │  scripts/transcribe.sh → whisper-cli (model in ~/.config/…) │
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
| The app | **Video Buddy 3.0**, SwiftUI, Swift 6.3 compiler in Swift 5 mode, macOS 15+, built with Command Line Tools only (no Xcode), ad-hoc signed, bundle ID `local.video-summarizer` | `~/Applications/Video Buddy.app` |
| History | SQLite 3.51 (WAL), schema version 3, daily verified backups | `~/Library/Application Support/Video Summarizer/` |
| Player | AVKit `AVPlayerView` (floating controls) + AVFoundation (resume, speed, volume, full screen, Picture in Picture), one player shared with the mini-player | inside the app |
| Online/offline detection | Network framework `NWPathMonitor`, plus one quick request to `youtube.com/generate_204` before a network job (catches captive Wi-Fi) | inside the app |

---

## 4. The pipeline, step by step

### 4.1 `scripts/cobalt-dl.sh <url> <audio|auto> <out-dir>`
It prints the saved file's path as its last stdout line, and progress on stderr.

0. **Playlist guard.** A YouTube link with `list=` but no video in it (`playlist?list=…`, `watch?list=…`) is refused with `Playlist link: paste it into the Video Buddy app to pick videos` on stderr and exit code 2. This happens before anything is created or downloaded.
   - Why: yt-dlp ignores `--no-playlist` for such links and goes through every video in the list.
   - Not refused: links that name a video (`v=`, `youtu.be/<id>`, `/shorts/<id>`, `/live/<id>`), even with `list=`, and every other site.
   - The app never sends these links here: it opens its playlist preview instead (§5.14).
1. Creates a private temp folder, `mktemp -d $TMPDIR/cobalt-dl.XXXXXX`.
   - `trap 'rm -rf "$tmp"' EXIT` deletes it on every exit.
   - `trap 'exit 143' TERM INT` turns Cancel into a normal exit, so the cleanup trap runs.
2. **cobalt first.** It sends `POST http://localhost:9000/` with `{"url":…, "downloadMode":"audio"|"auto", "audioFormat":"mp3", "filenameStyle":"pretty"}`.
   - On `tunnel` or `redirect`, it downloads into the temp folder.
   - **A 0-byte result counts as a failure.** For most YouTube videos cobalt says "tunnel" but streams nothing.
3. **yt-dlp fallback.** On any failure it prints `cobalt: <reason>, falling back to yt-dlp`, then:
   - runs `yt-dlp -x --audio-format mp3` (audio) or `-t mp4` (video) with `-P <temp>` and `--print after_move:filepath`;
   - with a quality setting, video also gets `-S "vcodec:h264,res:<720|1080>,acodec:aac"` (keeps H.264/AAC so the built-in player can play it);
   - tries **3 times**, because YouTube randomly returns 403 on about 1 in 6 tries;
   - prints `yt-dlp attempt N failed` after each failed try.
4. **Never overwrite.** `place()` moves the finished file into the output folder under a free name.
   - A name counts as taken if `<stem>.<ext>`, `.summary.md`, `.summary.md.part`, `.transcript.txt` or `.transcript.json` already exists.
   - If it's taken, the file becomes `<stem> (2).<ext>`, `(3)`, and so on.

**Video quality (2.1):** the app passes `VS_VIDEO_QUALITY=720|max` (nothing for the 1080p default). cobalt gets `"videoQuality"` in its request, yt-dlp the `-S` above. **When it's unset, as from Raycast, the request is byte-for-byte what it always was.**

Filenames: cobalt "pretty" names look like `Me at the zoo - jawed (youtube).mp3` and `… (240p, h264, youtube).mp4`; yt-dlp names look like `Title.mp3`.

### 4.2 `raycast/summarize.sh <url>`
The **marker lines** are a contract: the app parses them, so keep them exactly as they are.

```
⬇️  Downloading audio…            → runs scripts/cobalt-dl.sh <url> audio <out>
🎙️  Transcribing on-device…       → scripts/transcribe.sh <mp3>  (prints this marker; see 4.6)
🧠 Summarizing…                   → claude -p --model sonnet "$prompt" < <base>.transcript.txt | tee <base>.summary.md.part
                                    mv .part → <base>.summary.md   (a cancelled run never leaves a half summary)
📁 <path of the mp3>              → last line
```

- Output folder: `${VS_OUT_DIR:-~/Downloads/cobalt}`.
- The prompt is `${VS_SUMMARY_PROMPT:-<Standard>}`. Standard is exactly: *"Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways."*
- When **not** run by the app (`VS_FROM_APP` unset), it calls `scripts/record-history.sh summary <url> <mp3>` at the end.
- The scripts find each other relative to themselves (`root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)`), so the folder can move.
- Since 2.1 the transcription step is `scripts/transcribe.sh`, filtered through `grep --line-buffered -v '^/'` so its final path line isn't shown. The marker still appears the moment transcription starts, so Raycast and the app see exactly the same lines as before.

### 4.3 `raycast/download-audio.sh` / `download-video.sh`
These run `cobalt-dl.sh` into `~/Downloads/cobalt`, then `record-history.sh audio|video`, then print `Saved <name>`.

### 4.4 `scripts/record-history.sh <kind> <url> <file>`
It appends one JSON line to `${VS_DATA_DIR:-~/Library/Application Support/Video Summarizer}/inbox.jsonl`.
- The line is `{"id": <uuidgen>, "kind", "url", "file", "at": <epoch>}`, built with **`jq -nc`**, so it's always valid JSON on one line, whatever is in the title.
- It's written under **`/usr/bin/lockf -k -t 5 inbox.jsonl.lock`** as a single `printf`, so parallel Raycast runs can't mix their lines together.
- It ends with `|| true`: Raycast never fails because of history, and never needs the app.

### 4.6 `scripts/transcribe.sh <audio or video file>` (2.1)
The on-device transcript, used by `summarize.sh` and by the app's *Transcribe on this Mac*. It works without internet.
1. Prints `🎙️  Transcribing on-device…`.
2. If `<base>.transcript.txt` already exists, it's **reused, never overwritten**, and its path is printed.
3. mp3/wav/flac/ogg go straight to whisper. Video files (mp4…) are first converted with `ffmpeg -vn -ac 1 -ar 16000` to a WAV in a private temp folder.
4. `whisper-cli -np -l auto -m <model> -otxt -oj` writes into the temp folder, and the results are **moved next to the media only when complete**. A cancelled run leaves nothing half-written. `VS_WHISPER_MODEL` overrides the model.
5. The last line is the path of `<base>.transcript.txt`.

Temp folder plus `EXIT`/`TERM` traps, the same safety as `cobalt-dl.sh`. A 19-second mp4 took 2.8 s.

### 4.5 What leaves your Mac
- **The link:** cobalt or yt-dlp contact the video site.
- **The transcript text:** sent to Anthropic for the summary. The audio and video are never uploaded.
- **Your Drive:** `~/Desktop`, `~/Documents` and `~/Downloads` sync to your work Google Drive. That includes `~/Downloads/cobalt` (mp3/mp4) and this project folder.

Everything else stays local. Both containers listen only on 127.0.0.1, and the cobalt API's CORS only allows `http://localhost:9001`, so web pages you visit can't use your local cobalt.

---

## 5. Inside the app

### 5.1 Source map: `app/Sources/` (about 7,700 lines)

| File | Role |
|---|---|
| `App.swift` | `@main` entry (`--selftest` runs the tests and exits), Window and Settings scenes, menu commands and shortcuts, quit-during-job confirmation, first-launch window sizing, the window snapshot test hook |
| `AppModel.swift` | Shared state and every user action (start, retry, regenerate, favorite, remove, clear all, import, retention, copy…). Launch order: recover interrupted jobs → apply retention → daily backup → load → Raycast ingest → metadata backfill → offer import |
| `Models.swift` | `Video`, `Job`, `NewJob`, `VideoInfo`, `Segment`, `FileItem`, filters and sorts, the whisper JSON reader, `SummaryOutputs` (reads `<base>.summary.md/.transcript.*`), formatters |
| `SQLite.swift` | Small wrapper over the SQLite C API: parameterised queries, `transaction {}` (BEGIN IMMEDIATE / COMMIT / ROLLBACK) |
| `Database.swift` | `actor Database`, the single writer, off the main thread: schema and migrations, every query, stats, crash recovery, retention, corruption handling, rotating backups |
| `HistoryStore.swift` | What the views show (list, recent, files, stats, selection, 3.0: *Continue watching* and the Failed list; 3.1: every entry, playlist memberships, video-offline vs any-offline sets, watch states, Continue per playlist), loaded asynchronously. **4.0 P3:** Watch Later and its saved keys, entries by key, and `FolderWatcher` (FSEvents, recursive) that reloads when media files change |
| `JobController.swift` | **The queue runner (2.1):** enqueue from a link or an entry, `pump()` runs queued jobs one at a time (network jobs wait while offline), pause/resume/remove/clear, Cancel (pauses the queue). Per action: download/summarize via the scripts, *transcribe* via `transcribe.sh`, *resummarize* via `claude -p`. Steps, marker parsing, output checks, saving, metadata, thumbnails |
| `NetworkMonitor.swift` | `NWPathMonitor` + captive-Wi-Fi check → `isOnline`; test override `VS_FORCE_OFFLINE` |
| `Playback.swift` | One `AVPlayer` for the app: play/pause/seek/skip/speed/volume, resume positions per file, Play All list with next/previous (3.0), saves on pause/stop/quit |
| `Thumbnails.swift` | Saves thumbnails to the app's cache (web image, or a frame of the local video via `AVAssetImageGenerator`). **4.0 P3:** Watch Later's own copies in `watch-later/<id>.jpg` (kept only while the item is saved) |
| `Playlists.swift` | `PlaylistLink` (playlist and watch-in-playlist links), `PlaylistImport` (`yt-dlp --flat-playlist -J` + parsing), playlist types; 3.1: `PlaylistOrder` (merge new members without moving existing ones, positions between neighbours, the Continue rule) and `Grouping` (grouped lists, queue runs) |
| `ScriptRunner.swift` | `Paths` (where the bundled scripts are) and `RunningScript` (the bash **lifeline guard**, line streaming, cancel) |
| `Metadata.swift` | `VideoRef` (link → identity), `FileNames` (cobalt/yt-dlp filename parsing), `MetadataFetcher` (`yt-dlp -j`, `ffprobe`) |
| `Ingest.swift` | Reads the Raycast `inbox.jsonl` and ingests events (deduplicated by event ID) |
| `Importer.swift` | Read-only import of an existing downloads folder |
| `Prompts.swift` | Summary formats and languages, prompt building, `AppSettings`, `Appearance` |
| `SelfTest.swift` | 161 checks on throwaway data; `build.sh` refuses to install if any fail |
| `TestHooks.swift` | Test-only remote control (`VS_TEST_HOOKS=1`); see [Testing](#11-testing) |
| `Views/Theme.swift` | The Video Buddy palette (bg `#09090B`, sidebar `#111114`, cards `#191A1E`, elevated `#222327`, hover `#2D2E33`, red `#FA233B` → `#B8132C`, text `#F5F5F7` / `#A0A0A8`, borders `#33343A`), a light version with the same roles, applies the theme |
| `Views/Components.swift` | Card and panel styles, the red primary / charcoal secondary / red-outline button styles (hover, press, Reduce Motion), the red **+ Transcript** checkbox, chips, section header, search field, thumbnail, status pill, avatar, `FlowLayout`, `FileOps` (open, reveal, copy, export) |
| `Views/Markdown.swift` | Block Markdown parser (headings, bullets, numbered lists, rules, inline styling), **summary cards** (`Markdown.sections` → TL;DR / Key Points / Action Takeaways / other, English and Arabic headings), right-to-left detection |
| `Views/RootView.swift` | Window layout and breakpoints (sidebar folds under ~1360 pt, two columns under ~1120 pt of content), the sidebar (logo, navigation with the Queue badge, My Playlists, Learning Stats), the top bar, notices, dialogs |
| `Views/CenterColumn.swift` | The library column: list with search, sort, chips, *Grouped / All Videos*, album rows, *Your Playlists* and *Continue watching*, the rows and ⋮ actions, watched marks, the grouped Downloads list, file rows |
| `Views/DetailViews.swift` | The video column (details, actions, *About this video*), the AI panel and its Summary / Transcript / Downloads tabs |
| `Views/PlayerView.swift` | `AVPlayerView` wrapper, the 16:9 player area, ±10 s / speed, the **mini-player** and Up Next |
| `Views/QueueView.swift` | The processing strip and its stage track, the waiting strip, the Queue section (running, waiting, failed) |
| `Views/SettingsView.swift` | Settings, in the window and in the ⌘, window |
| `Browser/BrowserPolicy.swift` | **4.0 Phase 1 (branch `feature/4.0-phase1-browser`):** what a YouTube address is (home, video, Short, playlist, channel, search, sign-in, consent) from the URL alone, and the navigation rules (YouTube and Google's sign-in/consent pages stay in the app, other sites open in your browser, no downloads or `file://`) |
| `Browser/BrowserTab.swift` | 4.0 P1: one tab owning its `WKWebView` (survives section switches), its state through KVO (so YouTube's in-page navigation is seen), the delegates, camera/mic refused, and releasing everything before its data is removed. **Phase 2 (branch `feature/4.0-phase2-tabs`):** sleep and wake (`interactionState`), ⌘-/middle-click and `_blank` into tabs, `window.close()`, page-crash handling, the right-click menu (`TabWebView`) |
| `Browser/BrowserController.swift` | 4.0 P1: the YouTube section's browser: its own WebKit data store per data folder, the one-player rule (a read-only media check in a separate script world, since WebKit's own playback state is wrong on YouTube), Clear Browsing Data. **P2:** the tabs (order, active, closed), the pure tab rules, the 4-live-tab limit and memory pressure, background audio, `tabs.json` save/restore (`TabSession`) |
| `Views/OfflineHubView.swift` | **4.0 Phase 4 (branch `feature/4.0-phase4-offline-hub`):** the Prepare for Offline sheet (rows, checks, Declare…, sizes, quality, reserve, totals, Queue N) |
| `MediaCheck.swift` | 4.0 P4: `MediaChecker`, read-only file checks: the quick check (ffprobe + AVFoundation opens it), the deep check (ffmpeg decodes it), finding moved files |
| `Views/WatchLaterView.swift` | **4.0 Phase 3 (branch `feature/4.0-phase3-watch-later`):** the Watch Later page in the library column: search, sort, multi-selection and its bar, rows with live status and Play Offline / Play Audio / Open in YouTube; nothing on it downloads |
| `Views/BrowserView.swift` | 4.0 P1: the YouTube section: toolbar (back, forward, reload, address, open in your browser), the Video Buddy bar (library status; Video → Audio → Summarize → + Transcript; Play on this Mac; Save playlist), offline and error screens, the web view container (re-attaches after full screen). **P2:** the tab strip, one view identity per tab, the declaration sheet names its video |
| `Views/PlaylistViews.swift` | My Playlists list, the album-style playlist page (Play All, Continue, Download Missing, Add Videos, reorder), the Add Videos sheet (incl. From Folder), the YouTube playlist preview / Check Against YouTube sheet |

Other app files: `build.sh` (installs `~/Applications/Video Buddy.app`), `Info.plist` (name Video Buddy, id `local.video-summarizer`, version 3.1), `make-icon.swift` (draws the red gradient tile with a white `play.fill`; `preview` adds the amber PREVIEW band), `tests/vsctl.swift`, `tools/preview.sh` (4.0 branch: builds and installs the isolated *Video Buddy 4.0 Preview.app*; `--remove` deletes it and its data).

### 5.2 Video identity: one entry per video
`VideoRef.parse` turns a link into a **key**:
- **YouTube:** `youtube:<11-char id>`. It understands `watch?v=`, `youtu.be/`, `shorts/`, `embed/`, `live/`, `m.`, `music.` and `www.`.
- **Other sites:** `url:<host><path><query>`, without the fragment or a trailing slash.
- **Imported files:** `file:<normalised stem>`, because their URL is unknown.

A video can have any number of **jobs**: every summary version, every audio or video download, every failed or cancelled attempt. An imported entry merges into the real video once both its title and its channel match.

### 5.3 Database schema
Location: `~/Library/Application Support/Video Summarizer/history.sqlite`. Settings: WAL, `synchronous=NORMAL`, `foreign_keys=ON`, `busy_timeout=5000`, `user_version=3`.

**Upgrades:** `Database.migrate` goes step by step (v1 → v2 → v3). Before changing an existing database it writes a **verified copy** to `backups/history-pre-v<N>-<ms>.sqlite`, always a new name (a v1 database gets only the pre-v2 copy, since that already holds everything). If that copy can't be made, the upgrade doesn't run and the data on disk stays as it was. Your real history was upgraded to v2 on 2026-10-18 (2 videos, 3 jobs) and to **v3 on 2026-10-21** (36 videos, 38 jobs, the playlist and both resume positions kept, `quick_check ok`, `history-pre-v3-1792576609183.sqlite` verified).

```sql
videos(id PK, key UNIQUE, url, platform, title, channel, channel_followers, thumbnail_url,
       duration REAL, upload_date TEXT /*yyyyMMdd from the platform, never guessed*/,
       favorite, first_processed, last_processed, last_opened,
       thumbnail_path /*v2: the copy saved on this Mac*/,
       description, tags /*v3: from yt-dlp; tags as a JSON array; NULL until known*/)
jobs(id PK, video_id → videos ON DELETE CASCADE,
     kind summary|audio|video|transcript, action summarize|audio|video|transcribe|resummarize|audio_transcript|video_transcript /*v2; the last two since 10-18, same column*/,
     status queued /*v2*/|running|succeeded|failed|cancelled|interrupted,
     source app|raycast|import, event_id UNIQUE /*Raycast event id → no duplicates*/,
     started, finished, file_path, file_size, summary_path, transcript_path,
     summary, summary_language, summary_format, transcript,
     transcript_segments /*JSON [{start,end,text}]*/, transcript_language, error /*last 40 output lines*/)
meta(key PK, value)   -- inbox_offset, import_offered, last_backup
-- v2:
playback(file_path PK, position, duration, updated)            -- resume points
collections(id PK, name, source_url, created)                  -- My Playlists
collection_items(collection_id → collections CASCADE, video_id → videos CASCADE,
                 position, added, PK(collection_id, video_id))  -- ordered membership
```

Rules:
- **Summaries are append-only.** Regenerate inserts a new job and never edits an old one, so a failed regeneration loses nothing.
- **Every multi-row change is one transaction.**
- **Removing history deletes rows only, never files.**
- Unknown metadata stays NULL and shows as "—" or "unknown".

Filters:
- **Summaries:** has a succeeded summary.
- **Audio:** a succeeded audio job, or any `.mp3`.
- **Video** (called Downloads before 3.0): a succeeded video job.
- **Offline** (called On this Mac before 3.0): has an audio or video file that exists on disk right now. This is checked against the files, not the database.
- **Favorites:** starred.

Search uses escaped `LIKE` over title, channel, URL, summary, transcript and (3.1) the names of the video's playlists, with a 180 ms debounce.

Stats:
- **Videos processed:** distinct videos with any succeeded job.
- **Summaries generated:** succeeded summary jobs.
- **Videos offline (3.1; "available offline" in 3.0):** entries with a *video* file on this Mac right now. Audio-only entries still play, but don't count.
- **Learning time:** the sum of *known* durations of videos with a succeeded summary.

Other 3.0 reads:
- **Failed list:** failed or interrupted jobs with no newer job of the same kind for that entry (`failedJobs`, at most 20). Retry queues the same action. A failed job's file path isn't kept (`finishJob` writes the result's fields), so a retried transcription uses the entry's file that's on this Mac.
- **Continue watching:** `playback` rows joined to the succeeded job with that file, position over 1 s and not "nearly finished", latest first, at most 3, and only when the file is still playable.
- **Playlist artwork:** the thumbnail of each playlist's first item.

3.1 reads and rules (no schema change; still v3):
- **Memberships:** `memberships()` loads every `(playlist, video)` row in order once; every screen groups from it, so there is never a second copy of a video.
- **Watch states:** `watchStates()` takes the latest `playback` row per video (through `jobs.file_path`). **Finished** = the length is known and the position is in the "nearly finished" margin; the player now saves the **full length** when a file plays to its end (3.0 saved 0). Position 0, an unknown length or no row is **not started**, never finished. Over 1 s otherwise = part-watched.
- **Continue (per playlist):** the member played last; if it's finished, the next member that's on this Mac and not finished (`PlaylistOrder.resume`).
- **No duplicate downloads:** `insertJob` refuses a queued audio or video job when the same video already has one of that kind *queued or running* (it throws `AlreadyQueued`; the app says "Already in the queue"). Every path goes through it: Video/Audio, Download Missing, Make Available Offline, Download Again, playlist import, Retry.
- **Playlist import / Check:** one transaction. Ticked entries get a video row and a queued job. With a target (new, or an existing playlist, whose empty `source_url` is then filled in), every entry of the YouTube playlist that's in the library is linked by `youtube:<id>`; `PlaylistOrder.merge` slots new members after their nearest YouTube predecessor that's already a member (else before the nearest later one, else at the end), and they get positions *between* their neighbours, so existing rows aren't rewritten.

**4.0 (branches only; 3.1 stays at v3):** additive steps after v3, numbered in order (`Database.additive`). An existing database gets one verified backup before its first additive step (`history-pre-v4-…` from v3, `history-pre-v5-…` from v4), each step runs in a transaction, and creates only what doesn't exist.
```sql
-- v4 (Phase 1b): declarations you recorded, by video key
authorizations(video_key PK, basis, reference, recorded)
-- v5 (Phase 3): Watch Later, apart from the library (no link to videos)
watch_later(video_key PK /*youtube:<id>, the key videos and authorizations use*/,
            url NOT NULL /*the canonical watch link*/, title, channel, duration REAL,
            thumbnail_url, added REAL NOT NULL)
```
- One row per video (the primary key), so duplicates are impossible; saving again reports "already saved" (`ON CONFLICT DO NOTHING`).
- A lookup's details are written with an `UPDATE` only (an item removed meanwhile never comes back); its title replaces a guess, channel and duration fill only what's empty.
- What's on this Mac for each item is never stored: it's read live from the library's files and the queue.
- The thumbnail copy's path is worked out from the id (`watch-later/<id>.jpg`), not stored.
```sql
-- v6 (Phase 4): what a prepared download was queued with
job_options(job_id PK → jobs ON DELETE CASCADE, video_quality /*480|720|1080|max*/,
            estimated_bytes, size_kind /*known|approximate|unknown*/, low_space_stops /*after 2: failed, no loop*/)
```
- **The backstop:** `insertJob` refuses a queued YouTube download or summary unless `authorizations` has its `video_key` (`AuthorizationRequired`), whoever asks.
- **Relink** (`relinkFile`) changes `jobs.file_path` / `summary_path` / `transcript_path` and `playback.file_path` in one transaction, refuses a new path that doesn't exist or is already used, and never touches a file.
- **Restoring a backup, only on request:** `app/tools/restore-db.sh <data folder> <backup>`. It refuses while anything has the database open, saves the current state (log included) as `backups/history-before-restore-…` and checks it, restores through SQLite (`.restore`, then a checkpoint, never a file copy over the live database), and compares integrity, foreign keys, version and every table's count with the backup.

### 5.4 A job's life (`JobController`)
1. Parse the link. If it's bad, show an inline error and run nothing. Playlist links open the playlist flow (§5.14).
2. In one transaction, upsert the video and insert a **`queued`** job (2.1). It appears in history at once, as *Queued*.
3. `pump()` takes the oldest queued job that can run now (any job when online; only `transcribe` when offline), checks the internet is really reachable for network jobs, and marks it `running`.
4. Start `yt-dlp -j --skip-download` **in parallel**. It provides the title, channel, followers, duration, upload date, thumbnail and platform, and is saved as soon as it arrives, even if the job later fails.
5. Run the bundled `summarize.sh` (or `cobalt-dl.sh`) with `VS_FROM_APP=1`, `VS_OUT_DIR=<setting>`, `VS_SUMMARY_PROMPT=<format + language>` and, for video, `VS_VIDEO_QUALITY`.
6. Update the steps from the marker lines. Only lines that **start with** the marker emoji count (🎙 U+1F399, 🧠 U+1F9E0, 📁 U+1F4C1), so summary text that mentions "summarizing" can't confuse it. The step label gets "(yt-dlp fallback)" when that line appears.
7. **Check the outputs before calling it a success.** The media file must exist with size > 0, and for Summarize the `.summary.md` must not be empty. Then save the summary, transcript, segments, language, paths and size.
8. Fill gaps with fallbacks: the title and channel from the filename, the duration from `ffprobe`, the YouTube thumbnail from `i.ytimg.com/vi/<id>/mqdefault.jpg`.
9. Save the thumbnail on this Mac, then show the success banner, or on failure the job's last 40 output lines with a Retry button. Each failure also says why: missing file, empty summary, and so on.
10. `pump()` moves on to the next queued job.

**Transcribe on this Mac** (action `transcribe`, 2.1) runs `transcribe.sh` on the entry's local file (audio preferred, because it needs no conversion) and saves a `transcript` job: text, timestamped segments, language. It needs no internet.

**Audio / Video + Transcript** (actions `audio_transcript` and `video_transcript`, 10-18) run exactly like Audio and Video.
- When the download succeeds, they queue a `transcribe` job for the exact saved file, which then runs as above. The banner says "• transcript next".
- It's two jobs, not one: the download is saved first, so a cancelled or failed transcription loses nothing.
- The entry ends up with an audio or video job plus a transcript job.

**Regenerate / Summarize Transcript** (action `resummarize`) writes the saved transcript to a private temp file, then runs `claude -p --model sonnet "<prompt>" < transcript > summary`, and saves the result as a new version. It never downloads or transcribes again.

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
The keys are `summaryLanguage`, `summaryFormat`, `downloadDir` (empty means `~/Downloads/cobalt`), `videoQuality` (2.1: "720p (smaller)" / "1080p (default)" / "Best available"), `retentionDays` (0 means forever; favorites are never pruned), `appearance` (Dark / System / Light), `queuePaused`, `followTranscript`, `sidebarCollapsed` and `didSizeWindow2`. Any of them can be overridden per launch, which is how the tests use their own folders: `open -n "…/Video Buddy.app" --args -downloadDir /tmp/x`.

### 5.11 Queue and offline behaviour (2.1)
- **The queue is the database:** `queued` rows in `jobs`, oldest first. Nothing is held only in memory, so quitting, `kill -9` or a crash loses nothing. On launch, `running` jobs become `interrupted`; `queued` ones stay queued and start again.
- **One at a time:** `pump()` claims the runner before any `await`, so two callers can't start two jobs. It's called after enqueueing, after each job, on launch, on *Resume*, and whenever the network comes back.
- **Offline:** `NWPathMonitor` reports whether a network path exists. Before each network job the app also sends one `HEAD https://www.youtube.com/generate_204` (6 s timeout). If nothing answers, as on Wi-Fi stuck at a login page, the Mac counts as offline for 30 s, network jobs wait, and on-device jobs (`transcribe`) still run.
- **Cancel** stops the running job (the process guard, §5.5) and **pauses** the queue, so nothing else starts behind your back. *Resume* continues. *Pause* in the Queue section lets the current job finish and then waits.
- **+ Transcript order:** the follow-up `transcribe` job joins the end of the queue.
  - A single link: the download, then its transcript straight away.
  - A playlist: all the downloads first, then the transcripts. The downloads need internet and the transcripts don't, so they can finish offline.
- **Failed (3.0):** the Queue section lists what failed and hasn't been redone, with Retry (§5.3).
- **Notices** say what happened: *"Added to the queue. It starts by itself when you're back online."*, *"(3 waiting)"*, *"The queue is paused…"*.

### 5.12 The player (2.1)
- `PlaybackController` owns one `AVPlayer`, created for the file being played (`AVPlayerItem(url:)`). It reads the time every 0.5 s (this drives the transcript highlight), saves the position every 5 s while playing, and saves on pause, switching file, closing and quitting (Quit waits for the write).
- **Resume rule:** a saved position over 1 s is used unless it's in the last 5% of the file (at most 10 s). Those start over. The resumed spot lands on the nearest keyframe, a fraction of a second early.
- **Play All** keeps an ordered "up next" list. When an item ends (`AVPlayerItemDidPlayToEndTime`), its position is saved as its full length (3.1, so it reads as finished), the next one plays and the detail panel follows it.
- **Playlist context (3.1):** playing a playlist video sets `context` (id, name, count), `upNext` = the later members on this Mac and `played` = the earlier ones, so ⏭/⏮ stay in the playlist. Every saved position refreshes the watched marks and Continue (`onSaved`).
- The transcript's highlighted line is found by a binary search over segment start times (`[Segment].index(at:)`).
- The player view is AppKit's `AVPlayerView` (`controlsStyle .floating` since 3.0, full-screen toggle, Picture in Picture). For audio the thumbnail stays and the mini-player has the controls.
- **Mini-player (3.0):** drives the same `PlaybackController` (no second player). ⏭ = `next()` (the next Play All item), ⏮ = `previous()` (back to the start, or within the first 3 s to the item played before, kept in a small `played` list), the slider seeks on release, and `volume` is kept across files.

### 5.13 Thumbnails on this Mac (2.1)
- Stored in `~/Library/Application Support/Video Summarizer/thumbnails/<video id>.jpg`, at most 640 px wide, JPEG.
- Made when a job's metadata arrives, after Raycast ingest, and on launch for anything missing. The source is the web image when online, otherwise a frame at 10% (at most 30 s) of the local video.
- Views use the local file first, so the library looks the same offline. Removing an entry deletes only its cached thumbnail, never your files.

### 5.14 Playlists (2.1)
- `PlaylistLink.parse` recognises `youtube.com/playlist?list=…`, `watch?v=…&list=…` and `youtu.be/…?list=…`.
- **Preview:** `yt-dlp --flat-playlist -J` lists the playlist without downloading anything (about 5 s; a 1,004-video playlist took the same). Entries with invalid ids are dropped; `[Private video]` / `[Deleted video]` are shown greyed out and can't be selected.
- **Import:** one transaction creates or reuses an entry per video (key `youtube:<id>`, title, channel, duration and thumbnail from the listing). It adds a queued job each, with start times spaced a millisecond apart so the queue keeps the playlist order, and creates the playlist with the same order.
- **My Playlists:** `collections` + `collection_items` with a `position`. Adding appends and skips duplicates, dragging saves the full new order, and removing a video from history removes it from its playlists (cascade). Deleting a playlist deletes only the playlist.
- **Collections (3.1):** see §5.3 for linking, the merge, Continue and duplicate prevention. Membership belongs to the video, not to a job or a file, so later Summarize, Audio or Transcribe jobs keep it, and restarting changes nothing.

---

## 6. Where everything lives

### This folder: `~/Desktop/Dev/video-summarizer/`
```
README.md            this guide
design/              reference.png (the 3.0 design target) and screenshots/ of the real app
docker-compose.yml   cobalt API (:9000) + nginx web page (:9001), localhost only; `name: cobalt`
nginx.conf           static serving + COOP/COEP headers (cobalt's in-browser ffmpeg needs them)
scripts/
  cobalt-dl.sh       download via cobalt → yt-dlp fallback; temp dir, traps, never-overwrite naming
  record-history.sh  Raycast → app history event (jq -nc + lockf)
  transcribe.sh      on-device transcript of a local file (2.1); also used by summarize.sh
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
| Installed app (with its **own copy** of `scripts/` and `raycast/summarize.sh` in `Contents/Resources/`) | `~/Applications/Video Buddy.app` (was `Video Summarizer.app` until 2.1) |
| History database, backups (daily rotation + `history-pre-v2-*` / `history-pre-v3-*.sqlite` + the manual `history-before-*` copies), Raycast inbox, `thumbnails/` (the folder keeps its old name) | `~/Library/Application Support/Video Summarizer/` |
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

### 2026-10-18: version 2.1, offline library, player, playlists
- **Request:** use the library on a plane (watch downloaded videos, read summaries and transcripts without internet), plus playlists. Your choices: the player goes **inside the detail panel**, plus a **video quality setting**, a **disk space display**, and this README updated.
- **Checked first:** AVKit, AVFoundation and Network are in the Command Line Tools SDK, and `yt-dlp --flat-playlist -J` lists a playlist in about 5 s.
- **Built in phases, each built, self-tested, tested end to end and committed:**
  1. Schema v2 (with a verified pre-upgrade backup); the persistent queue; online/offline detection; the in-panel player with resume, speed and transcript sync; thumbnails saved locally; *On this Mac*; *Make Available Offline*.
  2. `scripts/transcribe.sh` (`summarize.sh` now uses it, with the same output lines); *Transcribe on this Mac*; summaries of saved transcripts queued while offline; the Queue popover.
  3. Playlist links, the preview sheet, My Playlists (reorder, Play All, Make All Available Offline).
  4. Video quality (720p / 1080p / Best) and the disk-space line; this README.
- **Bugs found while testing, and the fixes:**
  - **Resume skipped short videos.** "Restart if within 10 s of the end" meant anything past 9 s of a 19-second clip started over. → "Nearly finished" is now the last 5%, at most 10 s.
  - A test expected a removed job's video to show "cancelled", but the entry correctly shows its most recently *started* job (interrupted). The test was wrong, not the app.
  - Compile-time catches: Swift doesn't allow `await` on the right of `&&` (inside an autoclosure), or a `switch` inside a ternary. Both were rewritten.
  - The test player would have played sound on your Mac, so there's a test-only mute.
- **Measured** (§11): offline transcription of a 19-second mp4 in 2.8 s, a queue that survives `kill -9` (0 of 9 job processes left alive), playlist import of 2 of 1,004 videos in order, 720p downloads at exactly 1280×720 H.264.

### 2026-10-18: Raycast refuses playlist links
- **Question:** does a playlist link work? In the app, yes. In Raycast it didn't, and it failed wastefully:
  1. cobalt rejects playlist links, so the script fell back to yt-dlp.
  2. Measured on this Mac: for `playlist?list=X` and `watch?list=X`, yt-dlp **ignores `--no-playlist`** and goes through the whole list. It printed the first video ids of the 1,004-video test playlist.
  3. The download then fails, because several paths come back instead of one, and is retried up to 3 times.
- **Fix:** one check at the top of `scripts/cobalt-dl.sh` (§4.1, step 0). It refuses YouTube links with `list=` but no video id, before anything is created, and points you to the app. All three Raycast commands go through this script, so one check covers them.
- **Unchanged:** every other link's arguments, output and exit codes. A `watch?v=…&list=…` link still downloads just that video.
- **App rebuild:** not needed. Raycast runs the script from this folder, and the app never passes such links to it. The bundled copy picks up the check on the next `bash app/build.sh`.
- **Left out:** channel links (`/@name`) have the same yt-dlp behaviour. Add them to the check if you ever paste one.

### 2026-10-18: test videos removed, "+ Transcript", the series queue
- **Request:** delete the demo and test videos. Then two ways to download: *just the media*, to watch on a plane, or *the media plus a transcript*, when it's needed for a topic.
- **Cleanup**, done with the app quit and after a verified copy (`history-before-cleanup-20261018-044153.sqlite` in the app's `backups/`):
  - removed the two test entries from history, with their 3 jobs, the resume position and the cached thumbnail:
    - "Inside the Mind of a Master Procrastinator | Tim Urban | TED", the first end-to-end test on 10-13;
    - "Me at the zoo".
  - moved their 6 files in `~/Downloads/cobalt` to the Trash. The Zoo mp4 was already there.
  - A copy of the TED mp3 is still in the Music app's library; delete it there.
  - `backups/2026-10-14-downloads-sha256.txt` now lists files that are gone. It's kept as a record, but it's no longer the "downloads unchanged" check.
- **The series queue:**
  - The 36 episodes of *Lann Aeish fi Gilbab Aby* had been queued as Summarize. Episode 1 was cancelled, which paused the queue.
  - Its 35 waiting jobs were marked "Removed from the queue", and 36 **video** jobs were queued in episode order.
  - Measured on episode 1 (46 min): about 690 MB at Best and 270 MB at 720p.
- **Feature:** a **+ Transcript** checkbox, in the toolbar and the playlist preview.
  - Two new action values, `audio_transcript` and `video_transcript`, stored in the existing `jobs.action` column, so there's no schema change.
  - After a successful download they queue a `transcribe` job for the saved file (§5.4), using `transcribe.sh` as before.
- **Why two jobs, not one:**
  - the download is saved first, so a cancelled transcription loses nothing;
  - in a playlist, the downloads (which need internet) all finish before the transcripts (which don't).
- **Found while testing:** a scripted quit is refused ("User canceled") while the app shows its import-offer sheet. That's macOS behaviour and isn't new; the test copy was stopped with SIGTERM instead.
- **Unchanged:** Summarize, plain Audio and Video, Raycast, and every script.

### 2026-10-21: Video Buddy 3.0, the redesign
- **Request:** turn the app into **Video Buddy** (*Watch smarter. Learn faster.*), a premium Apple Music style dark app in black, grey and red, matching a reference image (now `design/reference.png`). The toolbar order must be **Video → Audio → Summarize → + Transcript**, with Summarize still the red primary button. Keep every existing feature, the data, the bundle ID and the shortcuts.
- **Safety first:** git tag `checkpoint-before-video-buddy` (6b0d8cf), a verified history copy and a settings export in the app's `backups/`, and the baseline self-test (113 checks).
- **What changed (the backend didn't):**
  - **Look:** a new palette and components (red primary, charcoal secondary and red-outline buttons with hover; red checkbox; chips; panels and cards), the logo and app icon (red tile, white ▶), the name in Info.plist, the window and the installed app.
  - **Layout:** sidebar (navigation with a Queue badge, My Playlists with artwork, Learning Stats), toolbar, processing strip, library | video | AI panel, bottom mini-player; responsive breakpoints instead of fixed sizes.
  - **New sections:** Library (was History), Queue (running, waiting, failed + Retry), Settings inside the window. Home is the library with *Continue watching*.
  - **AI panel:** summary cards (TL;DR, Key Points, Action Takeaways), the transcript and file lists restyled.
  - **Small data additions:** schema v3 adds `videos.description` and `videos.tags` (read by the same yt-dlp call as before, or *Load details*), with a verified `pre-v3` backup first. New reads: the failed list, continue watching, playlist artwork. The player gained volume, next and previous.
- **Decisions:**
  - Things in the image the app has no real data for were left out rather than faked: the percentage and "About 1 min remaining" (the scripts report neither), the bell and profile picture (no notifications or accounts), the verified badge and channel photo (not saved), the Chapters tab (no chapter data yet), shuffle and repeat (not asked for).
  - The video keeps **Apple's own player controls** (floating style) so full screen, Picture in Picture and keyboard control keep working. The red scrubber is in the mini-player.
  - "Downloaded" became **Available Offline** or **File missing**, so a pill never claims a file that isn't there.
  - The Favorites chip is a heart, so the chips fit on one line like the reference.
  - The app was renamed `Video Buddy.app`. The data folder (`Application Support/Video Summarizer`), the UserDefaults domain and the bundle ID stayed, so history, settings, resume positions and Raycast's inbox carry over without a migration.
- **Found while testing:** a sample summary inserted with SQLite's `readfile()` is a BLOB and reads as empty (test data only; fixed with `CAST(… AS TEXT)`). The window can't be taller than the screen's visible area, so the 1536×1024 snapshots are 1536×863.

### 2026-10-21: Video Buddy 3.1, playlists as collections
- **Request:** keep playlists grouped like Apple Music albums everywhere (Library, Home, Downloads, Favorites, Queue, search, player), for the series already on this Mac and for future imports, without downloading anything again or changing the queue.
- **What was found (read-only):** the schema already had `collections` / `collection_items`, and the series was already a playlist with its YouTube link, holding **35 of its 36 episodes**: episode 1 had been downloaded before the import and was never linked. On disk: 34 episodes plus a second identical copy of episode 1 (`… (2).mp4`); episodes 8 and 18 had failed. The old import also always made a *new* playlist and ticked everything, so pasting the link again would have downloaded ~23 GB a second time.
- **Safety first:** git tag `checkpoint-before-3.1`, a verified history copy (`history-before-3.1-20261021-135026.sqlite`, quick_check ok) and a settings export. No schema change.
- **What changed:** the grouped Library/Home/Favorites (album rows, Individual Videos, the toggle), *Your Playlists* cards, the album-style playlist page (Continue, Download Missing, Add Videos, From Folder), **Check Against YouTube** (link by ID only; nothing ticked), the preview's library badges, default ticks and *Save to*, Downloads grouped by playlist with one row per video, Queue headers per playlist, the player's playlist context, watched marks, and the duplicate-download guard.
- **Your amendments, as built:** Check only links; downloads happen only from *Download Missing* or ticked entries. Video and audio availability are separate (unique videos; mp3-only = "audio only"). Finished is detected from the end of the file, not from position 0. Reconciliation never moves existing members. Nothing on disk is moved, renamed, deleted or downloaded again.
- **Found while testing:** the watched marks and Continue didn't update until the next full reload, because positions are saved by the player, not through the store; now every save refreshes them. Group and video ids collided in one lazy list (playlist 1 vs video 1), hiding episode 1; group ids are now strings. Sizes in Downloads follow symlinks (only the test copy uses them).

### 2026-10-22: Video Buddy 4.0, Phase 1: YouTube in WKWebView (branch only)
- **Request:** make Video Buddy the main place to browse YouTube (tabs, Watch Later, an Offline Hub), but first prove the core browser in an isolated prototype and stop for review.
- **Where:** branch `feature/4.0-phase1-browser` (tag `checkpoint-before-4.0` = 3.1). Not installed; `main` and the installed 3.1 app are unchanged.
- **Built:** a **YouTube** sidebar section with one tab, the toolbar, the Video Buddy bar, the navigation rules, the one-player rule, ⌘[ / ⌘] / ⌘R / ⌘L in the YouTube section, and test commands that send real mouse and key events. Plus `app/tools/try-browser.sh` (try it in a throwaway folder; `--clean` removes its WebKit data).
- **Found:**
  - **Google sign-in worked in WKWebView** (a real account, by hand, with a phone prompt).
  - Full screen, `k`/`f`, in-page navigation, channels, playlists and Shorts work.
  - Memory: 0.6–1.4 GB per signed-in page.
  - **WebKit's playback state is wrong on YouTube.**
  - **A data store can only be deleted on a fresh launch,** after the session that used it ends.
- **Fixed:** the page not coming back after full screen; resuming the native player not pausing YouTube; test instances hearing each other (`VS_TEST_CHANNEL`).
- **Full results, GO/NO-GO and the revised Phases 2–5:** `design/4.0-phase1-report.md`.
- **Phase 1b (same day): the native action bar.**
  - **The bar:** it knows what you have from the video's ID and real files: Play Offline / Download Video (red) / Queued / Downloading / Retry / Download Again / Unavailable / Open Summary.
  - **The authorization gate:** a technical check from yt-dlp metadata, plus a declaration you record, labelled *not independently verified*. Nothing is queued if the check is inconclusive.
  - **ID safety:** an ID-keyed checker, and click-time ID matching, so rapid navigation can't queue the wrong video.
  - **Migrations:** an ordered additive list (v4 = `authorizations`; Watch Later = v5).
  - 219 self-tests; the report adds a Phase 1b section.
- **The 4.0 Preview app (same day).**
  - **Why:** the try-out only lived in `~/Library/Caches`, started from a script, and had 3.1's bundle ID, so it couldn't be found.
  - **What:** `app/tools/preview.sh` installs **Video Buddy 4.0 Preview.app** in `~/Applications`, with its own bundle ID, data folder, downloads folder, settings, WebKit data and PREVIEW icon.
  - **Behaviour:** a queue that can't be resumed; it opens in the YouTube section. 3.1 builds are unchanged (`AppSettings.isPreview` is false without `VBPreview`).

### 2026-10-23: Video Buddy 4.0, Phase 4: the Offline Hub (branch only)
- **Request:** a practical offline preparation tool in Downloads: Ready for Offline (verified files), Prepare for Offline from Watch Later and playlists (sizes, quality, free space, a reserve), the authorization checks on every in-app download path, Wi-Fi-only, safe low-space handling, and a WAL-safe rollback. Branch `feature/4.0-phase4-offline-hub` (from Phase 3); schema v6; `main` and 3.1 unchanged.
- **Built, in four commits:**
  - **4a:** v6 `job_options`, the database backstop, the runner's space checks (two volumes, about 2× while merging, during and at finalization, no retry loop) and last check, the network rule, the fake runner.
  - **4b:** per-video checks for a batch, size estimates from the same metadata.
  - **4c:** Prepare for Offline, and the download checks at every entry point (the link field too).
  - **4d:** Ready for Offline (file checks, problems, relink).
  - Plus `app/tools/restore-db.sh`.
- **Your requirements kept:**
  - every in-app YouTube download path gated, including the link field;
  - every registered file of every source;
  - disk space checked on both volumes, best effort for unknown sizes;
  - media checks that don't overclaim;
  - the network rule conservative, with its limits said in Settings;
  - rollback through SQLite's own backup and restore.
- **Found:**
  - **Backups keep WAL mode:** a backup SQLite makes keeps the log mode, so `sqlite3 -readonly` can't open it (it can't create the `-shm`); quiescent backups are read as immutable instead.
  - **Paths in listings:** a file listing names `/var/…` files as `/private/var/…`, so moved files are searched with paths relative to the folder.
  - **The test queue's paused state is kept in its settings:** the first fake-runner run had to resume it once.

### 2026-10-23: Video Buddy 4.0, Phase 3: native Watch Later (branch only)
- **Request:** save videos while browsing, without copying links, downloading anything or a Google integration; a Watch Later that works offline and shows what you already have; the download authorization gate unchanged; ready for Phase 4's Offline Hub without building it. Branch `feature/4.0-phase3-watch-later` (from Phase 2); schema v5; `main` and 3.1 unchanged.
- **Built, in two commits:**
  - **3a:** the v5 table with seven columns (no index, no stored thumbnail path), its `Database` functions and rules;
  - **3b+3c, one commit since "In Watch Later" opens the page:** the bar button, ⌘D, tab menus, titles, lookups and thumbnails tracked per video, the page, live status with a folder watcher, Open in Tabs under the 50-tab limit.
- **Your three extra requirements:**
  - Titles are never empty or another video's.
  - Status updates live, including files added, moved or deleted in subfolders.
  - Removing an item while its details or thumbnail are on their way leaves no row and no file behind.
- **Found:**
  - A failed download behind a queued retry shows as queued (the existing rule: the retry is what counts).
  - System alerts draw blank in the app's own snapshots, as other separate windows do.
  - A read-only `sqlite3` can't open a WAL database that has no `-wal`/`-shm` beside it, or make a `.backup` copy; copies of the three files are what the checks use.
- **Phase 4 ready:** one key (`youtube:<id>`) joins Watch Later, the library and declarations; status is computed live; the selection bar is where "Prepare Offline" will go, one video at a time through the download checks.

### 2026-10-22: Video Buddy 4.0, Phase 2: YouTube tabs (branch only)
- **Request:** Safari-style tabs in the YouTube section (new, close, reorder, duplicate, reopen; links in background tabs; restore after a restart; sleep inactive tabs; optional background audio), with the action bar correct for the active tab and no way to download from the wrong one. Branch `feature/4.0-phase2-tabs` (from Phase 1b); tested in the Preview's own test build; `main` and 3.1 unchanged.
- **Built, in four commits:**
  - **2a, tabs and safety:** the tab model and strip, the Tab menu and ⌘W, clicks checked against the active tab, one view identity per tab.
  - **2b, links into tabs:** ⌘-/middle-click, `_blank` and `window.open` in a click, `window.close()`, redirect tabs that close themselves, the right-click menu.
  - **2c, memory and media:** at most 4 live tabs, macOS memory warnings, WebKit's `.suspend` policy, background audio, page-crash handling.
  - **2d, restore:** `tabs.json`, the damaged-file fallback, Clear Browsing Data covering every tab.
- **Holes found in Phase 1b and closed (none had queued anything real; the Preview's queue is locked):**
  - ⌘⇧D / ⌘⇧A / ⌘↩ in the YouTube section queued the *hidden* link field's text without the gate; ⌘⇧V filled that field from the clipboard. They now act for the active tab's video through the gate, and ⌘⇧V opens a copied YouTube link in a new tab.
  - The playlist bar's *Save to Video Buddy…* sheet could queue downloads without the gate: from the YouTube section it's now link-only.
  - The web view container's delayed re-attach could show one tab's page under another tab's bar; `BrowserTab.close()` could undo a wake; pages could open windows with no click (WebKit's macOS default); the declaration sheet didn't name its video.
- **Found:**
  - WebKit reports mouse buttons as a mask (left 1, right 2, middle 4).
  - Each live YouTube tab is its own web process: about 250–300 MB each (top), and the total stays flat past 4 tabs.
  - A synthetic key event matches ⇧ shortcuts only when built like hardware (from the key code), so the test hook now does that.
- **Correction:** the Preview report's "33 videos" in your library was wrong. It read `history.sqlite` with `immutable=1`, which skips the write-ahead log; the main file still holds the rows from before Fresh Start (Oct 21, 19:39), and the deletions are in the log. Your library has had 0 videos since 14:49 on Oct 22. Production checks now count from a copy of all three files and compare the log's modified time too.

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
open ~/Applications/"Video Buddy.app"
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
| See or manage the queue | The **Queue** section (sidebar), or `sqlite3 ~/Library/Application\ Support/Video\ Summarizer/history.sqlite "select id, action, (select title from videos v where v.id=video_id) from jobs where status='queued' order by id"` |
| Unpause a queue from Terminal | `defaults write local.video-summarizer queuePaused -bool false`, then reopen the app |
| Restore from the pre-upgrade copy | As above, using `backups/history-pre-v3-*.sqlite` (or `pre-v2`). An older app can't open a newer schema; 3.0 simply upgrades the copy again, which is fine |
| Go back to the 2.1 app | `git checkout checkpoint-before-video-buddy -- app` and `bash app/build.sh` installs *Video Summarizer.app* again; restore `history-before-video-buddy-20261021-102939.sqlite` (§9 above), because 2.1 doesn't know schema v3. Then `git checkout main -- app` |
| Save your work | `git add -A && git commit -m "…"` |

---

## 10. Troubleshooting

| Symptom | Cause, and what to do |
|---|---|
| A step says "(yt-dlp fallback)" | Normal for YouTube: cobalt often streams 0 bytes. yt-dlp takes over |
| "Processing failed" with `HTTP Error 403` three times | YouTube's bot checks. `brew upgrade yt-dlp`; retry later. The long-term fix is the `bgutil-ytdlp-pot-provider` plugin for yt-dlp |
| A job seems stuck at the start, or an import says "Importing…" forever | A macOS privacy prompt is waiting (Downloads or Desktop folder access), possibly behind other windows. Click **Allow**. Every rebuild of the app re-asks, because of the ad-hoc signature |
| Raycast: "command not found" | Raycast doesn't load your shell profile. The scripts export `PATH=/opt/homebrew/bin:~/.local/bin:…`; check the tools are installed there |
| Ticked **+ Transcript**, but there's no transcript yet | The transcript is a separate job at the end of the queue; in a playlist it runs after all the downloads. Check the **Queue** section. If it failed, use ⋮ → *Transcribe on this Mac* |
| Raycast says "Playlist link: paste it into the Video Buddy app…" | It was a playlist link, which Raycast refuses on purpose (§4.1, step 0). Paste it into the app to preview and pick videos, or copy a single video's link instead |
| Raycast commands vanished | The script directory moved. Re-add `raycast/` in Raycast settings |
| The web page shows nothing / localhost:9001 doesn't load | `colima status`; `docker compose up -d`; check `vendor/cobalt/web/build` exists |
| `docker: unknown command: docker compose` | `~/.docker/config.json` is missing `cliPluginsExtraDirs` |
| `Cannot connect to the Docker daemon` | `docker context use colima`, or `colima start` |
| A summary mentions "the watch skill" or offers follow-ups | `claude -p` loads your Claude Code skills and hooks. `--bare` would stop it but requires `ANTHROPIC_API_KEY`, which you don't use. It's harmless; edit the summary or regenerate |
| An empty or missing summary | The app never marks it saved (it checks the file). See Details; often a claude login problem: run `claude` in Terminal |
| History damaged | The app moves it aside as `history.corrupt-*.sqlite` and starts fresh. Restore from `backups/` (§9) |
| "Waiting for internet" although you're online | The quick check to youtube.com failed (captive or login Wi-Fi, a VPN blocking it). Finish the Wi-Fi login. The app looks again within 30 s and whenever the network changes |
| Nothing runs, the strip says "Queue paused" | You pressed Cancel or Pause. Press **Resume** |
| *About this video* only shows **Load details** | The entry was saved before 3.0, so its description was never read. Press it (needs internet; metadata only) |
| The Dock or Spotlight still shows *Video Summarizer* | 3.0 is `Video Buddy.app`; the old app was moved to the Trash. Re-pin the new one. Same history and settings |
| A row says **File missing** | It was downloaded but the file isn't there now (moved, deleted or renamed). ⋮ → *Make Available Offline*, or *Download Again* in its Downloads tab |
| ▶ isn't shown for an entry | No playable file on this Mac: the file is missing, or it's a format the built-in player can't play (webm/mkv): use ⋮ → *Open Downloaded File*. Or there's no download yet: *Make Available Offline* |
| A video doesn't resume | It was within its last 5% (at most 10 s), so it counts as watched and starts over |
| Playlist preview fails | Reading a playlist needs internet; private playlists can't be read; `brew upgrade yt-dlp` if YouTube changed something |
| A playlist shows fewer videos than it has on YouTube, or one episode sits under *Individual Videos* | It was downloaded before (or apart from) the playlist import. Open the playlist → ⋯ → **Check Against YouTube…** → **Link N Library Videos** (metadata only, nothing downloads). Without a YouTube link: **Add Videos** → tick it, or **From Folder…** |
| "Already in the queue" | That video already has a download of the same kind waiting or running; nothing was queued twice. See the **Queue** section |
| An episode shows ✓ but you didn't finish it | You stopped within its last 5% (at most 10 s), which counts as finished. Play it again to start over |
| Arabic shows left-to-right | Right-to-left is detected from the first letter. Regenerate, or check the summary actually starts with Arabic text |

---

## 11. Testing

### The self-test: `app/build.sh` runs it on every build (161 checks)
- **3.1 collections (35 new):** a new playlist links every library video of the YouTube playlist and queues only the ticked ones; re-importing queues nothing already waiting and makes no second playlist; **Check links the already-downloaded episode and adds no jobs**; the hand-made order stays (episode 1 lands right before episode 2); merge and position rules; **a second video download of the same video is refused while one waits or runs**, audio is a separate download; a video in two playlists is grouped twice and stored once; favorites stay under their playlist in its order; searching a playlist name finds its videos; queue headers keep FIFO numbers; **position 0 and unknown lengths are never finished**, the end and the nearly-finished margin are; Continue after a finished episode is the next one, skipping missing and finished ones, never-played → Play All; the player's end-of-file save reads as finished; deleting a playlist keeps videos and jobs.
- **Link parsing:** 6 YouTube link forms, rejecting non-video pages and non-http links, normalising other sites.
- **Filename parsing and grouping:** cobalt audio/video names, `(2)` repeats, yt-dlp names, file roles.
- **Prompts:** Standard is identical to the **bundled** `summarize.sh`; the bundled scripts exist and are executable; the Masri and ADHD prompts.
- **Markdown:** block parsing, right-to-left detection, duration and watch-time formatting.
- **Database:** one row per video, metadata wins over guesses, derived flags, search (summary, transcript, channel, misses, `_` and `%` escaping), filters, favorites, stats, a failed regeneration keeping the saved summary, interrupted-job recovery, Raycast event dedupe, the files list, merging imported duplicates, cascade delete that keeps files, retention keeping favorites, integrity.
- **Backups:** two rotations, both copies healthy, not due again within a day, a bad copy rejected with both backups byte-identical, no temp leftovers.
- **Corruption:** a garbage database file is moved aside, not deleted.
- **Inbox:** complete lines only, a bad line skipped, a partial line read once complete, a replay after an offset reset adds nothing.
- **Import:** 2 videos and 3 jobs from 8 files, a second scan finds nothing, files byte-identical, URLs left unknown.
- **Upgrade (2.1):** a real v1 database with data upgrades to v2 with nothing lost; existing jobs get their action; exactly one verified pre-upgrade backup, even when the database is opened again.
- **Queue (2.1):** oldest first; offline picks only on-device work; queued jobs keep their format; a job starts only once; crash recovery leaves queued jobs alone; remove and clear; resume positions per file; thumbnail path; transcript line lookup; quality → script values (the default sends nothing); transcribe needs no network.
- **+ Transcript (10-18):** the checkbox → action mapping (unticked is the same as before); the kinds stay audio/video; the action survives the queue with no schema change.
- **3.0:** the summary cards (TL;DR / Key Points / Takeaways from English and Arabic headings, an empty title heading dropped, a summary without headings → one card, bullets-only → Key Points, ADHD's ⭐ Key takeaways); the filter chip names; description and tags stored and never replaced by guesses; a failed job listed with what Retry needs and gone once retried; Continue watching and its "nearly finished" rule; playlist artwork; a v1 database still gets one backup; **a 2.1 (v2) database upgrades to v3 after its own verified backup, keeping its entries**.
- **Playlists (2.1):** playlist / watch-in-playlist / short links; listing parse with private, deleted and invalid entries; import queues each video in order, reuses existing entries and takes durations from the listing; add skips duplicates; reorder; remove; summaries; cascade on history removal; deleting a playlist keeps the videos.

Run it by hand: `~/Applications/"Video Buddy.app"/Contents/MacOS/VideoSummarizer --selftest`

### End-to-end harness: drive the real app without touching your data
```bash
T=$(mktemp -d); mkdir -p "$T/data" "$T/out" "$T/shots"
swiftc app/tests/vsctl.swift -o "$T/vsctl"
open -n --env VS_DATA_DIR="$T/data" --env VS_SNAPSHOT_DIR="$T/shots" --env VS_TEST_HOOKS=1 \
  --env VS_WINDOW_SIZE=1536x1024 ~/Applications/"Video Buddy.app" --args -downloadDir "$T/out" -queuePaused YES
"$T/vsctl" "link https://www.youtube.com/watch?v=jNQXAC9IVRw"
"$T/vsctl" "start summary"          # or: start audio | start video
"$T/vsctl" state                    # → $T/shots/state.json (steps, banner, list, selection, jobs, files, stats)
"$T/vsctl" snapshot                 # → $T/shots/window.png
```
Commands: `link <url>`, `start summary|audio|video`, `cancel`, `select <title text>`, `favorite`, `search <text>`, `filter All|Summaries|Audio|Video|Offline|Favorites`, `sort <name>`, `section Home|Library|Favorites|Playlists|Downloads|Queue|Settings`, `tab Video|Summary|Transcript|Downloads`, `regenerate <Format>|<Language>`, `import`, `declineImport`, `remove`, `clearAll`, `reload`, `settings`, `snapshot`, `state`.

2.1 adds: `offline on|off` (simulated offline), `mute on|off` (so tests don't play sound), `play`, `pause`, `seek <seconds>`, `seekLine <n>`, `rate <x>`, `stopPlayer`, `transcribe`, `offlineVideo`, `summarizeTranscript`, `pauseQueue`, `resumeQueue`, `clearQueue`, `thumbnails`, `playlistPreview <url>`, `playlistImport <action>|<n shortest>|<name>`, `newPlaylist <name>`, `addToPlaylist <name>`, `openPlaylist <name>`, `movePlaylistItem <from>|<to>`, `removeFromPlaylist`, `playAll`, `makeAllOffline`, `deletePlaylist <name>`. `state` also reports `isOnline`, `queue`, `current`, `queuePaused`, `playback` (path, time, playing, rate, highlighted line), `onMac`, `thumbnailPath`, `playlists`, `openPlaylist`, `preview`.

3.0 adds: `next`, `previous`, `volume <0…1>`, `loadDetails`, `retryFailed`, and `showSteps` / `showSteps off` (test-only: fills the processing strip with a sample of the 4 Summarize stages, so its look can be checked without a download or an AI call). `state` also reports `failed`, `continueWatching`, `description`, `tags`, `queueBadge`, and `playback.volume` / `playback.hasPrevious`.

4.0 Phase 1 (branch) adds:
- **Navigation:** `browse <link or search>`, `back`, `forward`, `pageReload`.
- **Real input:** `webClick x|y` and `webClickEl <css>` (a real mouse click, at a point or an element's centre), `webKey <k|f|return|escape|…>`, `webType <text>`, `menuKey <[|]|r|l>` (a ⌘ shortcut through the app's menu).
- **Test-only:** `webRead <js>` (reads in a separate script world), `focusWindow` (only while nobody is at the keyboard), `clearBrowsingData`.
- **State:** `state` reports `browser` (url, title, page type, video id, full screen, media and WebKit's own media value, navigation log, outside links, data store id, clear report, window focus).
- **Phase 1b adds:**
  - `nativeClick <control>` (a real mouse click on a native control; controls are marked with `.testProbe`), `nativeType <control>|<text>`;
  - `declareOnly <id>|<reference>`, `requestVideo <id>` (a click carrying that ID), `fakeRunning <id>|off`, `ownChannels <list>`, `recheck`;
  - `loadFixtures <samples>|<downloads>`, `fixtureComplete <id>|<samples>|<downloads>`;
  - `state` gains `bar` (each slot's state, the gate, the check, files, jobs, visible controls).
- **Channels:** `VS_TEST_CHANNEL=<name>` (for the app and `vsctl`) keeps two test instances apart.

3.1 adds: `layout Grouped|All Videos`, `expand <playlist name part>|all|none`, `playPlaylist <name part>`, `continuePlaylist <name part>`, `checkPlaylist <name part>` (Check Against YouTube: a metadata read, needs `offline off`), `linkPlaylist` (the sheet's *Link N Library Videos*), `closeSheet`, `downloadMissing <name part>` → `confirmOffline` / `cancelOffline`, `selectEpisode <name part>|<n>`. `state` also reports `groups` (per playlist: members, shown, offline, audioOnly, episodes, resume), `layout`, `watch` (the selected video's state), `videoOnMac`, `offlineBatch`, `previewChecking`, `played` and `context` (playlist name, count, episode).

**Testing safely on a copy of your library (as done for 3.0 and 3.1):** copy `history.sqlite` with `sqlite3 … ".backup …"` into `$T/data`; in the copy only, set `queued`/`running` jobs to `cancelled` and rewrite every `file_path`/`summary_path`/`transcript_path` and `playback.file_path` from `~/Downloads/cobalt` to the test folder (then nothing under ~/Downloads is read, so macOS never asks); link those names to a sample made with `say` + `ffmpeg`; launch with `-queuePaused YES` and send `offline on` first so no network job can start. The test instance shares your UserDefaults, so `defaults export local.video-summarizer` before and `defaults import` after.

`VS_DATA_DIR` keeps the history in the temp folder, and `-downloadDir` the files. `VS_SCRIPTS_DIR` points the app at another copy of the scripts.

### What has been verified on this Mac (2026-10-14 → 10-21)
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
- **2.1 (10-18):**
  - Summarize and *Make Available Offline* through the queue; thumbnail saved (480×360).
  - **Player:** plays, seeks, the transcript-line seek jumps to the right second, the highlighted line matches the time, 1.5× speed is exact, the position saves on pause and resumes after a relaunch, and the last 5% restarts.
  - **Offline (simulated):**
    - the strip appears;
    - **transcribing an mp4 works with no network** (3 lines, English);
    - Summarize and summary jobs queue with the right notice;
    - going back online starts them by themselves.
  - **Queue:**
    - `kill -9` mid-job leaves 0 of 9 processes alive;
    - after relaunch the job is `interrupted` and the waiting job runs automatically, saved as `(2).mp3`, never overwriting;
    - Cancel pauses, and Resume continues.
  - **Playlists:**
    - a real 1,004-video playlist previewed;
    - 2 videos queued and run in order into "Shortest test";
    - My Playlists create, add, drag-reorder and **Play All**, which moved to the next video by itself;
    - *Make All Available Offline* downloaded both videos;
    - deleting a playlist kept the videos.
  - **Quality:** 720p gave H.264 1280×720 via cobalt, and the yt-dlp path keeps H.264. The default request is unchanged.
  - **Disk line:** "13 files • 33.4 MB • 761.21 GB free" matched `du` and the system figure.
  - **Raycast `summarize.sh`:** the same 4 marker lines with `transcribe.sh` inside.
  - **Your real history:** upgraded v1 → v2 (2 videos, 3 jobs, `quick_check ok`, verified pre-upgrade copy).
  - **Your `~/Downloads/cobalt`:** byte-identical to the 2026-10-14 list.
- **Playlist guard (10-18):**
  - `cobalt-dl.sh`, `download-audio.sh` and `summarize.sh` with a playlist link all end with the message and exit code 2. No output folder was created, no yt-dlp process started, and no history line was written.
  - A `watch?v=…&list=…` link still saves exactly one mp3 (19.1 s, "Me at the zoo").
  - The check was dry-run on 10 sample links (playlist, `watch?list=`, m./music., `v=` before and after `list=`, `youtu.be/<id>?list=`, plain video, Shorts, another site): all as intended.
  - `~/Downloads/cobalt` was still byte-identical afterwards.
  - Re-run it yourself: `scripts/cobalt-dl.sh "https://www.youtube.com/playlist?list=PL1EBE78CC528B52E8" audio /tmp/x; echo $?` should print the message and `2`, and create no `/tmp/x`.
- **+ Transcript and the cleanup (10-18):**
  - **Audio + Transcript** on "Me at the zoo": the mp3, then a transcript job ran by itself (3 lines, English). No summary.
  - **Video + Transcript:** an H.264 mp4, then its transcript through ffmpeg. The earlier mp3 and transcript stayed byte-identical.
  - **A playlist with Video + Transcript** for 2 videos: both downloads first, then both transcripts, in order. Distinct file names, and the playlist saved.
  - **Cancel during the follow-up transcription** of a 46-minute episode: whisper-cli and both scripts gone, no temp folders, the mp3 kept, the job `cancelled`, the queue paused.
  - **Unticked**, Audio gives the mp3 only, with no transcript job, saved as `(2)` without overwriting.
  - The window snapshot shows the checkbox next to Video.
  - **Your history after the cleanup:** 36 videos, no test rows, no orphan jobs, `quick_check ok`. The pre-cleanup copy has 38 videos.
  - **Your queue:** 36 video jobs, episode 1 first, still paused.
  - The tests ran on a throwaway copy. Your settings were exported first and restored afterwards.
- **Video Buddy 3.0 (10-21)**, on a throwaway copy of your library (36 episodes + the two old test talks from the 10-18 backup, a `say` + `ffmpeg` sample in place of every media file, one file left missing on purpose, an Arabic sample summary), launched offline with the queue paused:
  - **Build:** 126 self-test checks pass; the app installs as `Video Buddy.app`.
  - **Layout** at 1536×1024 (the reference size, shown at 1536×863 because the screen is shorter), 1280×800 (sidebar folds to icons, three columns) and 1024×700 (two columns, the Video tab): screenshots in `design/screenshots/`. The chips stay on one line at every size, and narrow rows show the status as an icon.
  - **Toolbar order:** Video → Audio → Summarize (red) → + Transcript, in every snapshot; the shortcuts are the same menu items as before.
  - **Summary cards:** an English Standard summary (TL;DR, numbered Key points) and the Arabic sample laid out right-to-left with numbered circles and ticks on the right.
  - **Playback:** ▶ plays; the mini-player appears, its time advances and its slider follows; it stays while switching to Settings and Queue; Play All in the playlist then ⏭ moved to the next episode (Up Next 31 → 30, *previous* available) and ⏮ came back; volume 0.3 applied; ✕ closes it.
  - **Transcription on this Mac** of the sample: the real 2-stage strip while running, then *"Transcript saved • 5 timestamped lines • English"*; clicking line 3 jumped to 0:09 and highlighted the spoken line.
  - **Processing strip:** `showSteps` drew the 4 stages (✔, moving bar, ③, ④) with Cancel.
  - **Queue:** the 2 failed episode downloads listed under Failed; Retry moved one to Waiting (badge 1) without starting it (paused, offline); Clear emptied it.
  - **Load details** on episode 2 (metadata only): the real description (1,770 characters) and its 38 tags appeared in *About this video*.
  - **Downloads:** 39 files, *Available 38 · Missing 1*; **Playlists:** artwork in the sidebar and the list, the open playlist with Play All and All Offline; **Settings** in the window; the **Light** theme (launch argument, your setting untouched).
  - **Upgrade on the copy:** v2 → v3 with `history-pre-v3-*.sqlite` written first.
  - **Raycast:** every script parses; the playlist guard still prints its message (now naming Video Buddy) and exits 2.
  - **Your real library:** after a verified copy (`history-before-video-buddy-20261021-102939.sqlite`, `quick_check ok`) and a settings export, Video Buddy opened it and upgraded it to **v3**: 36 videos, 38 jobs, 1 playlist, 2 resume positions, `quick_check ok`, and the `pre-v3` copy verified (v2, 36 videos, 38 jobs). The old `Video Summarizer.app` was moved to the Trash afterwards (it wasn't in the Dock).
  - Your settings were exported before the tests and imported afterwards; a diff showed them identical.

**3.1 on a copy of your library** (from `history-before-3.1-…`, media = 13.9 s sample clips at the real names, only the files that really exist, offline and queue paused; built into the job's temp folder, so the installed app wasn't touched while testing):
- **Recognised:** Grouped showed the series as one collection of **35** (33 offline, episodes 8 and 18 missing) with episode 1 under *Individual Videos*.
- **Check Against YouTube** (the only network step: `yt-dlp --flat-playlist`, queue paused): 36 on YouTube • 36 in your library • 34 on this Mac, **0 ticked**; *Link 1 Library Video* → 36 members, episode 1 first, **0 jobs added** (38 before and after, none queued). With a hand-made order (episode 3 dragged above 2) episode 1 went in between at position 0.5; every existing position was unchanged (diff of `collection_items`: one added row).
- **Restart:** grouping and order the same.
- **Modes and filters:** All Videos 36; Video and Offline 34 (episodes 8, 18 left out, numbers kept); Summaries 1 (episode 1); Favorites showed episodes 4 and 9 under the series; search by playlist name → 36, by title "الحلقة الثالثة" → episodes 3, 13, 23, 33 under the series ("4 of 36 videos"), by channel → 36.
- **Downloads:** *34 of 36 videos downloaded • 2 missing*; episode 1 is one row with its two MP4s and the missing MP3. **Download Missing** offered exactly episodes 8 and 18; asking again said they're already queued, and ⋮ → *Make Available Offline* on episode 8 was refused by the database ("Already in the queue"). The queue was cleared afterwards (nothing ran: offline and paused).
- **Queue:** one header for the series (2 queued • 34 of 36 offline), rows "Episode 8 • Download video", numbers 1–2.
- **Player:** Play All → episode 1 with 33 up next (the 34 on this Mac minus the current); ⏭ → episode 2, ⏮ within 3 s → episode 1; ▶ on episode 6 → 5 played before, 28 up next; mini-player "4 of 36 • series".
- **Finished vs started:** episode 3 played to its real end was saved at 13.93 of 13.93 s → **finished** (✓); episode 4, started automatically and paused at 0.86 s → **not started**; Continue → **episode 4**. Before that (positions from your library) Continue was episode 1, where you'd stopped.
- **Untouched:** your real `~/Downloads/cobalt` (35 files: sizes, modification times and inodes identical before and after), your real history (36 videos, 38 jobs, 35 members), episode 1's summary (759 characters) in both. Settings: the test only added `libraryLayout`, removed afterwards; `transcribeDownloads` changed while the test ran (from your app; no test command touches it) and was left as you set it.
- **Your real library:** with nothing running or queued, a second verified copy (`history-before-3.1-install-20261021-142338.sqlite`, quick_check ok: 36 videos, 38 jobs, 35 members, 3 positions), then the app was quit normally, 3.1 installed (161 checks) and reopened: still v3 (no migration), the same counts, nothing queued, quick_check ok, `~/Downloads/cobalt` unchanged.
- **Screenshots:** `design/screenshots/3.1-*.png`: grouped Library, Home, playlist page, playing from a playlist, Downloads, Queue, Favorites, search, and Library / playlist / Downloads / Home-playing at 1280×800 and 1024×700.

**4.0 Phase 1, on the branch (2026-10-22), in throwaway instances** (own data and downloads folders, own WebKit store, queue paused):
- **Self-tests:** 178 pass (161 + 17 browser rules). Phase 1b: **219** (+41: technical-check parsing, availability, state precedence, the gate, click outcomes, rapid navigation, the migration order).
- **The live results** (home, search two ways, watch, playback, `k`, full screen, in-page navigation, channels, playlists, Shorts, ⌘[ ⌘] ⌘R, outside links, sign-in, the one-player rule, memory and CPU, clearing data) are in `design/4.0-phase1-report.md`.
- **Afterwards:**
  - both WebKit stores were removed and checked;
  - `~/Library/WebKit/local.video-summarizer` was gone again;
  - settings were identical (the window position was restored);
  - the production library was unchanged.

- **4.0 Preview app (10-22):**
  - **Self-tests:** 222 inside the preview bundle (219 + 3: own data folder, downloads inside it, queue locked).
  - **Offline run:** a Resume request left the queue paused, with nothing running.
  - **Isolation:** the preview never opened a file in 3.1's folders (`lsof`).
  - **The states:** opened normally (no test hooks), it was the front app, in the YouTube section with youtube.com loaded. The bar showed Play Offline (sample), Authorization Required → Download Video (red) with Play Audio / Summarize / + Transcript, and Video Queued.
  - **Unchanged afterwards:** the 3.1 app, the production DB (`user_version` 3, counts, modified time), `~/Downloads/cobalt` and 3.1's settings. (The counts were read without the write-ahead log, so they showed 33 instead of 0; see the Phase 2 correction in §7.)
  - **Screenshots:** `design/screenshots/4.0-preview-*`.

- **4.0 Phase 2 (10-22), in the test build** (`preview.sh --test`: bundle ID `local.video-summarizer.preview-test`, a temp data folder, its own WebKit store, the queue locked; guest YouTube only, nothing downloaded, no AI):
  - **Self-tests:** 241 inside the bundle (222 + 19: link-tab order, close neighbour, what a tab keeps, the sleep rule, click modifiers, saved-tabs decoding, a click from another tab).
  - **Wrong-tab races** (queued video ids compared exactly): a click captured on one tab and delivered after switching → nothing queued; three quick ⌃Tab then a real click → only the tab on screen; in-page navigation then the old click → nothing; ⌘⇧D / ⌘⇧A / ⌘↩ with another link in the hidden field → the active tab's video through the gate (declaration sheet named it), never the hidden link; the playlist bar forced with 3 ticked videos → 0 queued; the bar's video = the active tab's on every switch (6/6).
  - **Tabs and shortcuts:** new, close, select, move, duplicate, reopen; ⌘T, ⌘W (the window stays), ⌘⇧T, ⌃Tab, ⌃⇧Tab, ⌘⇧] / [, ⌘1, ⌘9 (through the app menu with hardware-built key events).
  - **Links:** ⌘-click and a real middle-button event → tabs behind, asleep, after their opener in order; `window.open` in a gesture → a tab in front; `window.close()` → closed, opener shown, not in Reopen; a `youtube.com/redirect` tab that left YouTube → recorded as sent outside, closed itself; `window.open` from a timer → blocked; the link's right-click menu had *Open Link in New Tab* and no Download items.
  - **Memory and CPU:** 10 video tabs → 4 live, new WebKit processes and memory flat after 4 (about 3.1 GB resident with 4, 0.75 GB with 1); a memory warning → only the active tab stayed live (and the background-audio tab when on), with a notice; live idle background tabs 0.0% CPU.
  - **Background audio** (videos played muted; test runs count that as playing): off → switching tabs paused the video; on → it kept playing, became the audio tab, survived a memory warning, paused when the active tab started; the native player paused every tab.
  - **Crashes:** a page crash (the delegate call WebKit makes) in an inactive tab → asleep, woke with its history; in the active tab → reloaded once, a second → Try Again. `kill -9` of the app → all tabs, their order and the active one came back. A damaged `tabs.json` → kept as `tabs.corrupt.json`, one Home tab, a notice.
  - **Restore:** after quitting, 4 tabs came back asleep with no web process until YouTube was shown; Back worked in a restored tab; the guest cookie names were identical.
  - **Clear Browsing Data** with 3 tabs: every tab released, website data and saved tabs removed; WebKit then removed the store only on a fresh launch (as in Phase 1).
  - **Afterwards:** the test build's WebKit store, caches, settings and app were removed and checked gone. Compared with a baseline taken before testing, identical: the 3.1 app, the production DB (counted from a copy: 0 videos, 0 jobs, 0 playlists; main and log modified times), `~/Downloads/cobalt`, 3.1's settings, and your Preview's data folder, store id, WebKit store and settings.
  - **Installed:** the Preview was rebuilt at `66076e4` (241 self-tests inside its bundle), quit gracefully first, and opened normally in front in the YouTube section with 4 starter tabs (the labelled samples); it had no 3.1 file open. Its data folder, samples and WebKit store were kept; its own `queuePaused` setting was set back to on.
  - **Screenshots:** `design/screenshots/4.0-p2-*` (`03` is the installed Preview).

- **4.0 Phase 3 (10-23), in the test build** (`preview.sh --test`, a temp data folder, the queue locked, signed out of YouTube; nothing downloaded, no AI; lookups are yt-dlp metadata only):
  - **Self-tests:** 260 inside the bundle (241 + 19).
    - **Migration:** v4 → v5 with one verified pre-v5 backup, the library, declarations and playlists kept, exactly the 7 columns and no index; v3 → latest with one pre-v4 backup.
    - **Duplicates:** one key across watch, youtu.be, Shorts, mobile, music and `&list` links; saving twice keeps one row.
    - **Details:** a lookup fills details but never overwrites existing ones; a late lookup after Remove adds nothing.
    - **Independence:** Clear All History and pruning keep Watch Later.
    - **Page rules:** search and sort (accents and case ignored, unknown values last), placeholder titles, the row's main button, the status words.
  - **Saving:** the bar button (a real click) → saved with the page's title and a thumbnail copy; ⌘D again → "Already in Watch Later.", still 1 row; from asleep background tabs (the library's title, else "Getting details…" until the lookup filled the title, channel and duration); a click captured on one tab and delivered after switching → that tab's video with its own title.
  - **Statuses:** every labelled sample showed its own (Play Offline, Play Audio, Summary ready, queued, failed, file missing, a Short).
  - **Live, in one session, no restart:** queued (through the bar, with a declaration) → downloading → on this Mac → summary ready → failed. The file then deleted → File missing → put back → on this Mac; moved out → missing → moved back. A file two folders deep added, deleted and put back, and a file outside the downloads folder deleted, each caught by the watcher: the reload count went up and the sidebar stats changed in the snapshot.
  - **Remove while busy:** during a lookup, and during a slowed thumbnail download (`VS_TEST_SLOW_THUMBS`) → no row, no `.jpg`, no yt-dlp left after 14 s.
  - **Offline:** the page from the database and thumbnail copies, Open in YouTube greyed out; a video saved offline → "Title unavailable", no lookup or download; back online → title, channel, duration and thumbnail filled.
  - **50 tabs:** with 48 open, Open in Tabs for 7 → 2 reused, 2 opened asleep, the 3 others named in the report; again with 50 open: 1 reused, 2 named.
  - **The gate:** the queue and the library's row count were identical before and after save, open, play, show and remove; the page has no download buttons.
  - **Restart:** the items and the bar's **In Watch Later** came back. ⌘F stayed on the page. At 980×660 the sidebar still fits.
  - **Migration rehearsals on copies (deleted afterwards):**
    - your Preview's database (v4: 7 videos, 8 jobs, 1 declaration, 2 meta) → v5 with identical counts and a healthy pre-v5 backup;
    - your last full 3.1 backup (`history-before-fresh-start-…`, v3: 33 videos, 33 jobs, 3 resume points) → v5 with identical rows (keys, titles, job ids) and a healthy pre-v4 backup. The original backup's modified time was unchanged.
  - **Afterwards:** the test build's leftovers were removed. Compared with a baseline taken before testing, identical: 3.1, production (from a copy), `~/Downloads/cobalt`, 3.1's settings, and your Preview's data folder, database counts, `tabs.json`, store id, WebKit store and settings.
  - **Installed:** the Preview was rebuilt at `2e0e83a` (260 self-tests inside its bundle), quit gracefully and opened in front on the Watch Later page. Its database went from v4 to v5 after a verified `history-pre-v5-…` backup (v4, 7 videos, 8 jobs, 1 declaration); every count is the same. Its open tab, sign-in store, settings (including the Background audio you turned on) and samples were kept; only `tabs.json` was re-saved on quit (the same tab). The queue is still locked. Screenshot: `design/screenshots/4.0-p3-03-preview-installed.png`.

- **4.0 Phase 4 (10-23), in the test build** (its own bundle ID, temp data folders; the **fake runner** only there, which copies a sample clip and never downloads or summarizes; nothing real downloaded, no AI):
  - **Self-tests:** 309 inside the bundle (260 + 49).
    - **Migrations:** v5 → v6 (backup, rows, the 5 columns, `foreign_key_check`); v3 → latest; v4 → latest.
    - **The backstop:** a YouTube download or summary refused without a declaration; other sites and on-device work allowed.
    - **Job options:** quality and estimate travel with the job.
    - **Low space:** requeued once, then failed.
    - **Rules:** the two-volume space rule (same volume: reserve + 2×; separate: 2× on the temporary one, 1× on the downloads one, the reserve on both; unknown size: the reserve only); the network rule (Wi-Fi or Ethernet without the expensive or constrained flags; hotspot, Low Data Mode, cellular, unnamed: wait); size estimates (known, ≈, unknown, H.264 first, the quality cap, audio as MP3); totals and fit; Prepare's row states.
    - **The fake runner:** never the Preview, 3.1 or an unbundled binary.
    - **Files:** ffprobe parsing (an MP3's cover isn't video); damaged and empty files; a moved file found by name and size in a subfolder; Relink moving the record and the resume position, refused for a missing or used file, never touching the file; imported media listed.
  - **The queue, with the fake runner:**
    - A declared 480p job ran, and its quality reached the script.
    - **Low space:** before the start → it stays queued, with the reason; resuming while still low pauses again with no attempt; during the download → requeued (stop 1), then failed (stop 2); at finalization ("No space left") → requeued. No partial file was left in Downloads.
    - **Order:** three jobs ran in queue order.
    - **Cancel:** the job was cancelled and its process stopped.
    - **`kill -9`:** the job became "interrupted" with Retry, and the process guard stopped the download.
    - **Wi-Fi only:** it waited on a hotspot, Low Data Mode, cellular and an unnamed interface, and ran on Wi-Fi.
    - **Double Queue:** one job.
    - **Live status:** Watch Later showed "Downloading video", then "Video available offline".
  - **The gate at every entry point:**
    - **The link field:** without a declaration, the declaration sheet (nothing queued); declared, one job; members-only, refused with the reason.
    - **The Library:** Make Available Offline, Download Again, Process Again and Retry, each to the declaration sheet; declared, one job.
    - **Not gated:** Transcribe and a non-YouTube link queue as in 3.1.
    - **The runner's last check:** a declared video that's members-only at run time failed with the reason, and nothing was downloaded.
    - **Playlists:** Prepare Missing and the import sheet open Prepare and queue nothing by themselves.
    - **The backstop:** a direct queue call without a declaration was refused.
  - **Prepare:**
    - **10 rows:** a duplicate merged; already here, unavailable, needs a declaration, ready; known, ≈ and unknown sizes; "720p (its best)".
    - **Wrong video:** a row that became "already here" after the sheet opened was skipped at Queue.
    - **What was queued:** exactly the ready rows, with their quality, estimate and kind (Video or Audio); unticked rows were left out.
  - **Ready for Offline:**
    - **Files:** an imported clip and the samples opened and played (quality and length); a truncated file and a text file renamed `.mp4` were damaged; a missing one was missing.
    - **Deep check:** a good file was fully checked; the truncated one was still damaged.
    - **Moved:** a file moved two folders down was found and relinked after confirming.
    - **Unchanged:** the checksums were identical before and after.
  - **Rollback rehearsals (isolated copies only):**
    - **Uncheckpointed log:** a copy of your Preview's database with 3 rows only in its `-wal` (the writer force-quit). `restore-db.sh` refused while a process held it (nothing changed), then saved a recovery copy holding all 8 test rows, restored exactly the backup's rows with none of the log's coming back (log truncated), and the undo put all 8 back.
    - **v5 → v6 → v5:** a copy migrated to v6 with identical counts and no broken foreign keys, then restored from its pre-v6 backup with identical Watch Later, declarations, videos and jobs.
    - **3.1 backup:** a copy of your last full 3.1 backup (v3) → v6 with identical rows; the original unchanged.
  - **Afterwards:**
    - **Test build:** its store, caches, settings and app were removed.
    - **Unchanged since the Phase 3 install:** 3.1, production (from a copy), `~/Downloads/cobalt` and 3.1's settings.
    - **Your Preview:** it differs only by what you did in it on Oct 23 (2 Watch Later items, a declaration, 2 cancelled jobs, your tabs).
  - **Screenshots:** `design/screenshots/4.0-p4-*`.

### Not verified
- **4.0 Phase 4 (needs real downloads, so Phase 5):**
  - real cobalt or yt-dlp downloads at a chosen quality, and whether the result has that resolution;
  - size estimates against real files;
  - the disk really filling during a real download, and the script cleaning up a real one;
  - a real Wi-Fi to hotspot switch;
  - "+ Transcript" after a real download;
  - paid summaries.
- **4.0 Phase 4, by hand:** the native controls in the Prepare sheet (pickers draw blank in snapshots), Locate…'s file panel, and a deep check of a long video (slow; cancellable by design).
- **4.0 Phase 3:**
  - your own mouse and keyboard on the page: ⇧/⌘-click selection, ⌘A, Delete, the right-click menu (driven through the same model calls instead);
  - the tab-limit alert's look (system alerts draw blank in snapshots; its text was checked);
  - a real download or summary finishing (the queue is locked; completions were recorded as the queue would record them);
  - FSEvents on a network or external drive.
- **4.0 Phase 2:**
  - your real keyboard and mouse: ⌃Tab while the page has keyboard focus, drag-to-reorder, a hardware middle click (the test used a real middle-button event and the menu with hardware-built key events);
  - plain clicks on `target=_blank` links (YouTube's page swallowed the synthetic click; the same path ran through `window.open` in a gesture);
  - signing in across tabs and a restart (only guest cookies were compared);
  - a real web-process crash (no public API causes one; the delegate call was made directly);
  - tab switching blocked during full screen (a one-line guard; full screen would have taken over your screen);
  - per-tab memory exactly (WebKit gives no per-tab figure; process totals were measured).
- **4.0 Preview app:** `preview.sh --remove` (written, not run, so your preview stays).
- **4.0 Phase 1:**
  - Picture in Picture, ads, page downloads (rules unit-tested only), long sessions, multiple tabs, sound output;
  - sign-in lasting across relaunches;
  - click-to-play by hand: automated clicks started playback only 2 of 5 times.
- **3.1 by hand:** real clicks on album rows, drag-to-reorder with the mouse, the *Add Videos* sheet and *From Folder…* (its folder match is code-checked only), and pasting a playlist link in *import* mode (default ticks = not in library) were not driven end to end; Check mode was. The preview sheet's native controls render blank in snapshots. **Your real library still has 35 members** until you press *Check Against YouTube → Link 1 Library Video* (I didn't run a YouTube check or change it from here).
- **3.0 by hand:** real hover, clicks and keyboard focus in the new layout (driven through the test hooks instead), the full-screen and PiP buttons themselves, and the native player controls (they render black in snapshots, like the video picture). A real Summarize run through the new strip wasn't done, to avoid an AI call; it uses the same strip as `showSteps` and the transcription run.
- **Clicking the + Transcript checkbox.** The tests set it with a launch argument (`-transcribeDownloads YES`); the snapshot shows it.
- **Real mouse clicks and keyboard shortcuts.** Accessibility scripting is blocked in the terminal that ran the tests.
- The **save dialogs**, and how the **import alert**, the **Settings window** and the **playlist preview sheet** look (the window snapshot renders separate windows blank). The **video picture** in the player also renders black in snapshots; the playback itself was verified through the player's state.
- **Real Wi-Fi off.** Offline was simulated with `offline on`, because turning Wi-Fi off would have cut the test session. The captive-portal check was not exercised on a real login-page Wi-Fi. → Use the checklist below once.
- **The Raycast toast for a playlist link.** The scripts were run from the terminal, because Raycast can't be clicked from here. → Run *Download Audio* in Raycast with a playlist link once: the toast should show "Playlist link: …".

### Your one-time real offline check
1. With internet, make sure at least one video is **On this Mac** and one entry has an mp3 but no transcript.
2. Turn **Wi-Fi off**. Within a few seconds the blue *"You're offline"* strip appears.
3. Press ▶ on the video: it plays. Close the app, reopen it, press ▶ again: it resumes.
4. *Transcribe on this Mac* on the mp3 entry: it completes.
5. Paste any YouTube link and press **Summarize**: you get *"Added to the queue. It starts by itself when you're back online."*
6. Turn **Wi-Fi on**: the queued job starts by itself.

---

## 12. Limitations, privacy and next steps

**Limitations**
- **YouTube through cobalt mostly fails** (0-byte tunnels), and yt-dlp is throttled and occasionally gets 403. It works, but it's slow.
- **Ad-hoc signing** means macOS re-asks for folder permissions after every rebuild.
- **Summaries can mention your Claude Code skills.** `--bare` needs an API key.
- **Player formats:** mp4/m4v/mov/mp3/m4a/aac/wav play inside the app; webm/mkv open outside. "Best available" via yt-dlp is still H.264, so usually 1080p at most on YouTube.
- **Big playlists** run one video at a time, so 100 videos summarized takes hours. The preview shows the total time.
- **Offline is detected, not predicted:** a job that loses the connection halfway fails, with Retry. It isn't paused.
- **No notes of your own.** Tags come from the platform (3.0), not from you.
- **Imported entries** have no original link and use placeholder thumbnails.
- **Leftovers from cancelled jobs:** files a cancelled job *finished* (an mp3, a transcript) stay on disk but aren't in history; use Import to pick them up.
- **Raycast ignores the app's settings:** it always uses `~/Downloads/cobalt` with Standard in English.
- **One job at a time**, on purpose: it keeps YouTube from throttling harder and keeps the Mac responsive.

**Privacy and security**
- Both containers listen on 127.0.0.1 only, and the cobalt API's CORS only allows the local web page.
- The audio stays on your Mac; only the transcript goes to Anthropic.
- Your Desktop, Documents and Downloads sync to your **work Google Drive**. That includes downloaded media and this project folder.
- No secrets are stored in this project.

**Next steps**
1. A stable self-signed code-signing certificate, so permission grants survive rebuilds.
2. The `bgutil-ytdlp-pot-provider` plugin for yt-dlp: faster, more reliable YouTube.
3. Notes and tags on videos, and exporting a summary with its notes.
4. A Raycast command that adds a playlist or a link to the app's queue.
5. **Chapters** (yt-dlp has them for many videos): a Chapters tab that jumps the player, as in the reference design.
6. Shuffle and repeat in the mini-player, also in the reference design.
7. *Just This Video* on a `watch?v=…&list=…` link could join the video to that playlist when you already have it (3.1 doesn't).
8. Whisper picks the wrong language when a video opens with music (episode 1's transcript is "Music playing."): detect the language from a later part, or let you choose it.
7. **Whisper picks the wrong language when a video starts with music** (episode 1's transcript is "Music playing." throughout): detect the language from the middle of the file, and let a stuck transcript be redone.
5. A Raycast command to search the history.
