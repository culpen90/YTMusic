# YTMusic for macOS

YTMusic is a native SwiftUI music app that searches YouTube through `yt-dlp`, extracts the best available audio with FFmpeg, and plays it with AVFoundation.

Its storage rule is deliberate:

- **Play Once** downloads into a per-song cache folder. The complete folder—audio, artwork, and temporary metadata—is deleted when the song ends, when you skip it, on app quit, and again on the next launch.
- **Download** is the only action that keeps an audio file. Kept songs appear in the offline Library.
- **Playlists store URLs only.** Each entry contains a YouTube URL plus lightweight display metadata. Links can be added while metadata lookup is unavailable. Playback uses an existing Library copy when available; otherwise it prepares a self-cleaning temporary copy for that song.

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

The default **Best available** mode selects `bestaudio/best` and asks yt-dlp/FFmpeg to preserve the source audio without another lossy encode. This is higher fidelity than converting already-lossy YouTube audio to MP3. ALAC is available when a lossless post-conversion/native container is preferred, but it cannot restore information absent from the source and uses much more disk. M4A and MP3 are available for compatibility.

## Data locations

- Kept audio: `~/Library/Application Support/YTMusic/Media`
- Kept artwork and library metadata: `~/Library/Application Support/YTMusic`
- Interrupted or unreferenced Library files preserved for recovery: `~/Library/Application Support/YTMusic/Recovered`
- Temporary playback and staging: `~/Library/Caches/YTMusic`

Library deletion moves the audio file to the macOS Trash. Playlist deletion removes only the URL list; it never deletes downloaded songs. Remote artwork uses an ephemeral network session rather than a persistent URL cache.

## Responsible use

Use YTMusic only for media you own or are authorized to download, such as your own uploads, public-domain works, or material whose license permits saving. The app does not bypass DRM, private access, authentication, or platform restrictions. You remain responsible for following YouTube's terms and applicable law.

## Architecture

- SwiftUI `NavigationSplitView` for Discover, Downloads, Library, and URL-only playlists
- Shell-free `Foundation.Process` runner with tagged JSON progress, EOF-safe output draining, and cancellable child process groups
- App-controlled staging and path validation before every import
- Atomic JSON persistence with backups, recovery, and rollback for kept tracks and playlist references
- `AVPlayer` playback with deterministic cleanup callbacks
- Unit coverage for output parsing, URL validation, persistent Library imports, URL-only playlists, and Play Once deletion
