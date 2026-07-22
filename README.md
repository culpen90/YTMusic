# YTMusic for macOS

YTMusic is a native SwiftUI music app that searches YouTube through `yt-dlp`, streams Play Once audio with AVFoundation, and uses FFmpeg for saved downloads.

Its storage rule is deliberate:

- **Play Once** resolves a stereo AAC source and streams it directly through AVPlayer. Playback is capped at yt-dlp's extracted media duration so a bad remote AVFoundation timeline cannot add silence after the song. When validated `music_offtopic` markers are available, marked non-song sections are skipped; marker lookup failure falls back to the complete source. Play Once does not create an app-managed audio file or wait for the whole song to download.
- **Download** is the only action that keeps an audio file. Kept songs appear in the offline Library.
- **Playlists store URLs only.** Each entry contains a YouTube URL plus lightweight display metadata. Links can be added while metadata lookup is unavailable. Playback uses an existing Library copy when available; otherwise it streams the song without saving it.
- **Autoplay prepares the handoff without repeats.** While a song is playing, YTMusic chooses an unheard radio recommendation and resolves its transient stream in the background. Listening history stays in memory for the current app session and recognizes common YouTube labels such as “Official Audio,” while duration and version labels keep distinct recordings separate. Playlist order takes priority, and radio continues after the final playlist song when Autoplay is on.
- **Thumbs tune future choices.** Likes and dislikes are stored locally as lightweight song metadata. One thumbs up adds a song to Favorites and stays selected; removing it from Favorites or choosing thumbs down takes it back out. Disliked songs are excluded, and feedback about an artist changes how later radio candidates are ranked.

## Requirements

- macOS 14 or newer
- Xcode 15.3 or newer / Swift 5.10 or newer
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp)
- [FFmpeg](https://ffmpeg.org/)

On a Homebrew Mac:

```sh
brew install yt-dlp ffmpeg
```

The app auto-detects Apple Silicon and Intel Homebrew paths and also accepts custom executable paths in Settings. It uses `yt-dlp`, the actively maintained `youtube-dl`-compatible implementation required for current YouTube support.

## Build and run

```sh
make test
make app
open dist/YTMusic.app
```

`make app` creates an ad-hoc-signed universal Apple Silicon/Intel app bundle at `dist/YTMusic.app` and a clean portable archive at `dist/YTMusic.zip`. Use the ZIP when copying the app out of an iCloud/File Provider folder, since Finder metadata added to a live app bundle can invalidate its signature. For distribution to other Macs, sign and notarize with your Developer ID and either require Homebrew tools or prepare a compliant, signed helper bundle with all third-party licenses.

## Audio quality

The download format setting applies to songs kept in the Library. The default **Best available** mode selects `bestaudio/best` and asks yt-dlp/FFmpeg to preserve the source audio without another lossy encode. ALAC, M4A, and MP3 are available for saved downloads. Play Once instead selects an AVPlayer-compatible stereo AAC stream so playback can begin without a full-file transfer or conversion.

## Data locations

- Kept audio: `~/Library/Application Support/YTMusic/Media`
- Kept artwork and library metadata: `~/Library/Application Support/YTMusic`
- Local thumbs feedback: `~/Library/Application Support/YTMusic/feedback.json`
- Interrupted or unreferenced Library files preserved for recovery: `~/Library/Application Support/YTMusic/Recovered`
- Interrupted download staging and transient app data: `~/Library/Caches/YTMusic`

Library deletion moves the audio file to the macOS Trash. Playlist deletion removes only the URL list; it never deletes downloaded songs. Autoplay candidates and their expiring stream URLs are never persisted, and preparing the next song creates no audio file. Remote artwork uses an ephemeral network session rather than a persistent URL cache.

## Responsible use

Use YTMusic only for media you own or are authorized to download, such as your own uploads, public-domain works, or material whose license permits saving. The app does not bypass DRM, private access, authentication, or platform restrictions. You remain responsible for following YouTube's terms and applicable law.

## Architecture

- SwiftUI `NavigationSplitView` for Discover, Downloads, Library, automatic Favorites, and URL-only playlists
- Shell-free `Foundation.Process` runner with tagged JSON progress, EOF-safe output draining, and cancellable child process groups
- App-controlled staging and path validation before every import
- Atomic JSON persistence with backups, recovery, and rollback for kept tracks and playlist references
- `AVPlayer` playback with deterministic cleanup callbacks and a cancellable prepared-next pipeline
- Unit coverage for output parsing, stream URL and timeline validation, early playback completion, recommendation parsing/ranking, local feedback, persistent Library imports, URL-only playlists, and temporary-file cleanup
