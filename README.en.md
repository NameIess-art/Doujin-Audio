<p align="center">
  <img src="assets/icons/app_mark_light.png" alt="Doujin Audio outline icon" width="240">
</p>

# Doujin Audio

[简体中文](README.md) | English | [日本語](README.ja.md)

Doujin Audio is an Android / Windows audio player for ASMR, doujin audio, and local media libraries. Flutter provides the shared interface and business logic; Android playback uses Media3 / ExoPlayer, while Windows uses libmpv. Local media, ASMR.ONE online streams, and custom playback queues are managed within a unified multi-session system.

[`pubspec.yaml`](pubspec.yaml) is the single source of truth for the current version. Official installers and updates are distributed through GitHub Releases: [GitHub Latest Release](https://github.com/NameIess-art/Doujin-Audio/releases/latest).

[GPL-3.0 License](LICENSE) · [Privacy Notice](PRIVACY.md) · [Security Notice](SECURITY.md)

If you would like to support ongoing maintenance, you can sponsor the project through [Aifadian](https://ifdian.net/a/nameIess). Sponsorship is voluntary and does not unlock privileges or paid features. All application features remain free.

## Download

> **Upgrade notice:** Doujin Audio now uses the independent Android application ID `com.doujin.audio`. It installs as a separate application, cannot replace versions released before the rename, and does not inherit their private application data. Restoring a `.dabackup` requires a compatible platform and backup format, and the backup database version must not exceed the version supported by the application. Automatic migration of data or older backup formats from before the rename is not provided.

| Platform | Release asset | Notes |
|---|---|---|
| Android universal | `DoujinAudio-android-universal-<tag>.apk` | Recommended for most users; includes arm64-v8a, armeabi-v7a, and x86_64 native libraries |
| Android arm64-v8a | `DoujinAudio-android-arm64-<tag>.apk` | Smaller download for most modern 64-bit Android devices |
| Android armeabi-v7a | `DoujinAudio-android-armv7-<tag>.apk` | For older 32-bit ARM Android devices |
| Android x86_64 | `DoujinAudio-android-x64-<tag>.apk` | For x86_64 tablets, PC emulators, and compatible devices |
| Windows x64 | `DoujinAudio-windows-x64-<tag>-setup.exe` | Per-user installation on Windows 10/11; runtime dependencies are bundled |

GitHub Releases are the project's only official distribution channel. App-store AAB packages and an iOS version are not distributed.

### Getting started

1. On Android, download the APK for your architecture or the universal APK. If installation is blocked, allow the browser or file manager used to open the APK to install unknown applications. On Windows 10/11 x64, download `setup.exe` and follow the wizard to install for the current user. Each installer has an accompanying `.sha256` file with the same name.
2. Open the local audio library and add your library folder through the system folder picker: Android uses SAF authorization, and Windows uses local folders. Individual files or subfolders can also be added as needed.
3. Select a work or audio entry to start playback. Online content is available on the ASMR.ONE page; account features require sign-in. On Windows, use right-click menus for card actions. Closing the main window leaves the application in the tray; use the tray's Exit command to stop playback and quit.

The application follows a local-first design: library indexes, settings, and playback state are stored entirely on the device. Network requests are used for ASMR.ONE content, DLsite metadata, GitHub updates, and the initial download of subtitle-processing models. ASMR.ONE online subtitles are saved locally before loading. Permissions such as file access and overlay display are requested only when their corresponding features are used.

## Screenshots

These five screenshots show the actual application interface. The top system status bar has been cropped out, and covers, work and track names, subtitles, and actual metadata have been pixelated. Navigation, field labels, and controls are preserved.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/asmr-one.png" alt="ASMR.ONE page with covers and work information pixelated" width="420"><br>ASMR.ONE</td>
    <td align="center"><img src="docs/screenshots/local-library.png" alt="Local audio library with covers and media information pixelated" width="420"><br>Local audio library</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/playlists.png" alt="Playlists page with covers and track names pixelated" width="420"><br>Playlists</td>
    <td align="center"><img src="docs/screenshots/work-details.png" alt="Work details page with the cover and actual metadata pixelated" width="420"><br>Work details</td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/screenshots/playback-details.png" alt="Playback details page with the cover, track name, and subtitles pixelated" width="420"><br>Playback details</td>
  </tr>
</table>

## Main features

### Playback controls and multiple sessions

- **Multiple playback sessions:** Maintain several independent sessions in a horizontal card carousel. Each session separately tracks its audio, position, volume, repeat mode, subtitle switches, and audio effects.
- **Custom named queues:** Create multiple named playback queues, sort by name, duration, or time added, drag cards to reorder tracks, and customize card colors. Multiple sessions can be retained for the same work.
- **Uninterrupted removal from queues:** Removing the currently playing track from a queue does not abruptly stop its audio; it continues until the track ends naturally or you switch tracks.
- **Batch session management:** Long-press on the playlists page to enter selection mode, then pause, resume, or remove selected sessions in bulk.
- **Six playback modes:** Repeat one track, play the current folder in order, shuffle the current folder, play across folders in order, shuffle across folders, or stop immediately after one track in the timed single-play mode.
- **Playback and seeking:** Play/pause, previous/next track, rewind/fast-forward with long-press or double-tap steps, fine-adjustment seek sliders, and quick retry after playback failure.
- **Compact progress bar:** The playback details page uses a compact 34px layout, with segmented progress backgrounds and timeline markers dynamically centered vertically.
- **Loading and buffering feedback:** A spinner appears on the play button while online audio or large files load or buffer, and the subtitle area shows a loading message. Playback state can still be toggled or the audio reloaded while buffering.
- **Local video and audio-only playback:**
  - For video entries such as MP4, MKV, and WebM, the playback details cover area renders the video directly.
  - Tap the video to enter an immersive landscape fullscreen mode with an AMOLED-black background; subtitles remain centered in landscape.
  - Screen-off playback is supported: video switches to background audio-only streaming when the screen turns off.
  - Enable Audio only in appearance settings to disable video rendering and conserve battery and system resources.

### Audio console and DSP enhancement

- **Equalizer (EQ):** Android uses a native equalizer and detects supported frequency bands; Windows uses a software equalizer. Choose presets, fine-tune band gains in dB, and create, rename, reset, or undo deletion of custom presets.
- **Skip silence:** ExoPlayer on Android and audio filters on Windows detect and skip silent sections.
- **Light noise reduction:** Native audio filters reduce background white noise and microphone hiss.
- **Dynamic volume balancing:** Suppress sudden loud sounds and enhance quiet breaths and softer audio for a more consistent listening level.
- **Channel swap and balance:** Swap left and right channels or adjust the stereo balance from -1.0 to +1.0 for uneven headphones or single-ear listening.
- **Playback speed:** Continuously adjust speed from 0.25x to 3.0x while preserving pitch, using quick presets or a fine-adjustment slider.
- **Timeline markers and segment loops:** Add named, colored markers at any audio position, or loop a specific time range.
- **Feature badges:** The top-right area of the details page, playlist cards, and bottom mini-player show active session features such as EQ, noise reduction, silence skipping, playback speed, and channel balance.

### Subtitles

- **Multiple formats:** Supports `.srt`, `.ass`, `.ssa`, `.vtt`, and `.lrc`, with automatic loading of matching filenames or manual association.
- **Synchronized display:** The playback details card, compact bottom player, and system overlay display the current subtitle line together.
- **System-wide subtitle overlay:**
  - Show subtitles above other applications, independently of the main interface. Android uses `SYSTEM_ALERT_WINDOW`; Windows uses a separate transparent, always-on-top window.
  - Customize font, text size, text color, background color, background opacity, and outline thickness, with a live preview in settings.
  - Drag the overlay anywhere on screen; edge-snapping positions are remembered automatically.
- **Dedicated controls and immediate synchronization:**
  - The playback details page has a subtitle drawer with master subtitle and overlay switches. Controls are disabled for audio without valid subtitles.
  - Select an external local subtitle file on the playback page (`.srt`, `.vtt`, `.lrc`, `.ass`, `.ssa`, and others). For local audio, the selected file is renamed and moved beside the audio. Existing subtitles require overwrite confirmation; cancellation preserves both files. Display refreshes immediately, and subtitles continue to load from the audio folder after restarting. Matching supports same-name files, double extensions, and language suffixes.
  - Script-to-subtitle recognition accepts manually selected Japanese `.txt` or `.md` scripts for local or ASMR.ONE audio. It matches spoken audio to script lines in the background and generates timing. Local results are saved as a same-name `.lrc` beside the audio, including in authorized SAF folders. Online results are stored under the audio filename in the application data directory. `.txt` files with valid timing are imported directly. Local audio reads only local subtitles; ASMR.ONE continues to cache online subtitles before loading them.
  - Japanese subtitles can be translated into Chinese or English. Background processing saves and applies an SRT containing both Japanese and translated text. Local translations are saved beside the audio and replace the current subtitles; online translations remain in the application data directory. The first use downloads and verifies local models. Choosing a background model download resumes the current subtitle task when the model is ready. Dialogs show live progress for model downloads, script matching, and translation; processing continues after the dialog closes. Interrupted tasks can resume from segment progress. 32-bit Android is not currently supported.
  - Edit subtitle text and start/end times line by line. On Android, swipe left to delete or right to insert a blank line below; Windows uses right-click menus. New subtitles need text and timing before saving. Saving after deleting every line clears subtitle display for the current audio. Edits are written in the original format to the currently associated local subtitle file; Android SAF writes back to the original authorized file. Write failures produce a save-failure message.
  - Fine-tune subtitle synchronization with millisecond precision using `-0.5s`, `-0.1s`, Reset, `+0.1s`, and `+0.5s` adjustments, applied immediately.
- **Full subtitle timeline:**
  - Scroll through the complete text in a timeline view, with the line matching current playback highlighted automatically.
  - After scrolling stops, the view smoothly returns to the current line. Select any line or its seek button to jump to that timestamp.
- **Errors and debounce behavior:**
  - Parsing or loading failures appear as clear red error text in the subtitle area.
  - Seeking applies a smooth debounce threshold and fades loading feedback in and out to avoid frequent flickering.

### Local library and metadata

- **Folders and storage authorization:** Full Android Storage Access Framework (SAF) support preserves folder permissions across restarts and upgrades. Direct-path scanning and single-file imports are also supported.
- **Hierarchical browsing, sorting, and grouping:**
  - Preserve the original folder structure and remember expanded/collapsed state during the current run.
  - Sort and group by voice actor (CV), tags, duration, release date, time added, or file title.
  - Long-press and drag entries to arrange them manually.
- **Quick card actions and direct downloads:**
  - Select a work folder to open its details. On mobile, swipe left for Download and Remove from library, or right to pin. Select an individual audio/video file to play it; swipe left for Edit information and Remove from library. Windows offers corresponding right-click actions.
  - Download on a local work with an RJ code opens its ASMR.ONE download page immediately with a skeleton screen, without waiting for remote metadata. The destination is preset and locked to the local work folder, making it easy to retrieve missing tracks or attachments.
- **Work scripts and document viewer (`WorkTextViewerPage`):**
  - Automatically discover and open `.txt`, `.md`, and `.pdf` scripts and documents from a work's folder on its details page.
  - Local work details immediately show the indexed folder tree, with folders and attachment lists cached during the current run. Each reopening starts at the root and initial position, while file changes refresh in the background.
  - Plain text supports automatic encoding detection (UTF-8, GBK, Shift-JIS, EUC-JP, and others) and smooth scrolling through long documents. Markdown is rendered with native syntax styling; PDFs provide paged previews and quick navigation.
  - Switch between multiple documents using the bottom horizontal capsule. The viewer uses a full-width floating header and soft translucent transition masks; Windows scrollbars begin below the header.
- **Native chunked scanning:** Native scan events deliver large libraries in incremental batches to the database, avoiding memory spikes and UI stalls from constructing large objects at once.
- **Search and batch actions:**
  - Fuzzy search with multiple keywords.
  - Long-press in library lists or search results to select multiple entries for batch queue additions and management.
- **Cover matching and extraction:**
  - Decode images at 300px, 600px, 900px, 1200px, or original size to balance scrolling performance and large-image clarity.
  - Find nearby images, extract embedded ID3/FLAC covers, or capture high-resolution frames at selected video positions. Identical embedded covers across multiple audio files are deduplicated by hash into one candidate. RIFF WAVE (`.wav`) trailing ID3v2 APIC covers are supported across platforms and by Android's native extraction.
  - Prefer own cover makes audio use embedded artwork first and video use its own captured frame. Audio without its own cover falls back through folder covers, Disc subfolders, and ancestor folders. The metadata editor lets you select any extracted cover candidate, with immediate updates on the fullscreen playback details page.
  - Renaming a file or folder automatically updates its cover-cache association.
- **Non-destructive metadata persistence:**
  - SQLite is the primary fast runtime data source; voice actors and tags are stored separately in ordered relation tables.
  - A folder's `doujin-audio.json` is an open, portable metadata format.
  - Adding or scanning automatically detects durations for individual audio/video files and cumulative audio/video duration in work folders, filling details and JSON `durationMs`. Existing durations are preserved; a folder total is saved only after every file is successfully identified.
  - **Metadata preservation:** Automatic duration completion fills only missing durations on the target entry. Missing JSON files are created in the existing format. Other fields, timeline markers, neighboring file entries, and unknown fields remain unchanged; unreadable or incompatible files are preserved. Scan imports and RJ-code completion do not modify existing JSON. Explicit saves, confirmed DLsite metadata, and timeline-marker edits continue to use the existing atomic update process.
  - Manually selected covers (relative paths, embedded-image caches, or captured video-frame data) are also saved in `doujin-audio.json`, and retain priority when a removed work is imported again.
  - Local timeline markers and segment loops can be imported/exported through `doujin-audio.json` or backed up/restored through `.dabackup`, preserving names, start/end times, and colors. Marker additions, edits, and deletions synchronize only marker fields. Folder works use relative track paths so markers survive folder moves. Repeated imports retain newer markers; older files do not clear existing markers.
- **Safe removal and removed-folder management:**
  - Removing a folder from the library shows a toast with an undo countdown to prevent accidental removal.
  - A dedicated Removed folders screen persists excluded paths, skips them in later scans, and lets you restore them to the library at any time.
- **DLsite metadata retrieval and batch review:**
  - Retrieve official DLsite metadata using RJ codes, filenames, or work titles, including title, voice actors, circle, release date, tags, and cover.
  - Search and automatically match unidentified library works in batches.
  - A dedicated DLsite review page provides previous/next work navigation to compare results, make quick corrections, and merge/save confirmed metadata.

### ASMR.ONE and downloads

- **Online browsing and cloud synchronization:**
  - Browse the ASMR.ONE remote catalog by new releases, popularity, category tags, and voice actors.
  - Securely sign in with account/password credentials and synchronize cloud favorites and playback history.
  - Android work cards support swipe actions; Windows uses right-click menus for playback, queue additions, and details. Long-press to select works for batch additions or downloads.
- **Streaming and playback caching:**
  - Add remote audio streams directly to local multi-session playback queues.
  - Enable automatic caching after playback to save completed audio in the private application cache, avoiding repeated data usage when listening again.
- **Background and resumable downloads:**
  - Download selected tracks, subfolders, or complete works to local storage.
  - Android retains SAF authorization for download folders; Windows uses local folders.
  - Each successfully completed work automatically refreshes any already-added local library, without opening its page. Download folders are not automatically added to the library; works outside it still need manual import.
  - Preserve the work's original folder hierarchy and save covers separately under `Cover/<RJ code>.<extension>` in the download root for recognition by other media players.
  - Pause all downloads or individual tasks, resume interrupted transfers, and retry failures. Tasks are safely suspended when the application enters the background or before process exit, then reuse downloaded temporary chunks on resumption.
  - Network interruptions, truncated responses, and remote 5xx errors trigger exponential-backoff retries for individual files. The retry limit is configurable from 3 to 10 (default 5); concurrent work downloads can be set from 1 to 5.
  - Existing `.json` files in download folders retain their original bytes. New metadata JSON is generated only for a fully downloaded work with valid, nonempty content.

### Video to audio

- **Local audio extraction:** Select a video in a common format from local storage and extract its audio stream.
- **Formats and parameters:** Export MP3, AAC, OGG, WAV, or FLAC. Lossy formats offer selectable bitrates up to 320 kbps; lossless formats retain the original sampling specifications automatically.
- **Convenient workflow:** Remember the last export folder, show live percentage and progress, and cancel at any time. After extraction, locate the result or add it directly to the library for playback.

### Android background playback and stability

- **Native media sessions:** Built on Android `MediaSessionService` and Media3 / ExoPlayer, following modern Android foreground media-service requirements.
- **Minimal background-service notification:** Shows only the application name and background-service status, without track details, artwork, or playback buttons. Tap to return to the application. The foreground service required for background playback remains active; notification text supports Simplified Chinese, English, and Japanese.
- **Background and screen-off playback:** CPU WakeLocks are acquired and renewed as needed during playback; streaming also uses a Wi-Fi Lock, prebuffering, and recovery. High-performance Wi-Fi Locks can work with the screen off on Android 13 and earlier. Android 14 and later restrict them to foreground, screen-on use. WakeLocks cannot bypass Doze or manufacturer background controls. For long listening sessions, review battery optimization and background permissions under Permissions and background. Playback resources are released after pausing or finishing.
- **Playback recovery window:** A 10-minute backoff recovery window retries transient network reconnections, I/O instability, or AudioTrack hardware-channel disconnections. Network reconnection or turning on the screen immediately triggers a priority recovery attempt.
- **Manufacturer background-management guidance:** Analyze process termination reasons. If customized systems such as vivo / OriginOS kill the process for high power usage or background cleanup, a dialog directs you to the system's background allowlist settings.
- **Sleep and resume timers:**
  - Set a countdown or stop after the current track ends.
  - Smooth linear volume fade-out before stopping avoids abrupt silence disturbing sleep.
  - Automatically resume at a preset time after a scheduled pause, with smooth linear fade-in to avoid sudden loud playback.
- **Exact alarms and reboot persistence:** `SCHEDULE_EXACT_ALARM` and `RECEIVE_BOOT_COMPLETED` restore pending pause and automatic-resume tasks after a device reboot.

### Personalization, settings, and data maintenance

- **Themes and appearance:**
  - Follow the system theme or choose light/dark mode.
  - Choose a global theme color and adaptive launcher icons.
  - Independent ASMR.ONE colors let the online module use its own theme color. Light and dark surfaces adapt to that color throughout the header (`TopPageHeader`), search and batch-action bars, active category capsules, download pages, task details, and other subpages.
  - ThemeProvider applies color and dark-mode changes immediately across the application without restarting.
- **Interaction and gestures:**
  - Swipe left/right on bottom navigation to switch pages, or long-press an icon for 350ms to quickly reset and switch.
  - Choose the initial page: ASMR.ONE, local audio library, or playlists.
  - Sticky section headers make long settings lists easier to navigate.
  - Inline permission cards centralize storage access, background operation, overlays, exact alarms, and unknown-application installation status, with shortcuts to authorization.
  - Slow down transitions or enable reduced motion, and configure cover-image decoding quality.
- **Audio focus and interruption behavior:**
  - Configure behavior separately for headphone unplugging/Bluetooth disconnection, transient focus loss such as navigation announcements, and the end of incoming calls: continue, pause, or lower volume.
  - Choose standard exclusive-focus mode or mixing with other applications, which allows simultaneous audio without competing for other applications' media focus.
- **Data protection and lossless backups (`.dabackup`):**
  - Stream-export the library database, preferences, playback history/sessions, work timeline markers, and ASMR.ONE credentials into a standard `.dabackup` file.
  - Restores undergo strict format validation and transactional atomic replacement at the next cold start. Validation or replacement failure rolls back to preserve the original data.
- **Cover and browsing caches:**
  - Android and Windows share persistent image caching. Work lists, details, playlists, playback screens, and work image viewers reuse saved original images after restarts or offline.
  - Root-page lists, filters, pagination, and browsing positions are retained only during the current run. Search reuses the existing list cache and starts at the top; details reload the file tree each time they open. Data loads on first entry or explicit refresh; returning to an existing page does not automatically refresh it.
  - Page data and browsing positions are not stored in the database. Images are not evicted automatically by age or capacity, and cache hits do not trigger network update checks. Redownloads occur only when an address changes, a file is missing/corrupt, or the cache is explicitly cleared. Memory remains bounded; temporary audio, subtitle, and video caches still use capacity management. Explicit cleanup preserves source files, manually chosen covers, favorites, history, and playback state.
- **Storage analysis and selective cache cleanup:**
  - Storage charts break down local audio, cover caches, ASMR caches, logs, and other system storage.
  - A dedicated panel separately clears cover images, ASMR.ONE playback caches, captured video frames, temporary download chunks, and update installers.
  - Export diagnostic environment information and runtime logs with sensitive account information removed, ready to attach to an issue.

## In-app updates

Every update asset is built by GitHub Actions and published with an accompanying `.sha256` file of the same name:

```text
DoujinAudio-android-universal-<tag>.apk
DoujinAudio-android-universal-<tag>.apk.sha256
DoujinAudio-android-arm64-<tag>.apk
DoujinAudio-android-arm64-<tag>.apk.sha256
DoujinAudio-android-armv7-<tag>.apk
DoujinAudio-android-armv7-<tag>.apk.sha256
DoujinAudio-android-x64-<tag>.apk
DoujinAudio-android-x64-<tag>.apk.sha256
DoujinAudio-windows-x64-<tag>-setup.exe
DoujinAudio-windows-x64-<tag>-setup.exe.sha256
```

- Updates are checked against the GitHub Latest Release API automatically at startup or manually from settings.
- Android selects an arm64, armv7, or x64 APK for the CPU ABI, falling back to universal if the architecture cannot be determined. Windows selects the x64 installer.
- Download progress and network status appear globally in the application's top bar. After downloading, SHA-256 verification must pass before launching the Android system installer or Windows installation wizard.

## Supported formats

| Type | Formats / protocols |
|---|---|
| Audio | `flac`, `wav`, `mp3`, `m4a`, `aac`, `ogg`, `opus`, `3gp` |
| Video | `mp4`, `mkv`, `webm`, `mov`, `m4v`, `avi`, `3gp` |
| Subtitles | `.srt`, `.ass`, `.ssa`, `.vtt`, `.lrc` |
| Documents | `.txt` (automatic encoding detection), `.md`, `.pdf` |
| Covers | `jpg`, `jpeg`, `png`, `webp`, embedded audio artwork (including hash deduplication and WAV APIC), captured video frames |
| Backups | `.dabackup` (database, settings, playback sessions, timeline markers, and accounts) |

## Code structure

- `lib/app`: Application entry and global assembly, covering dependency injection, routing, theme state, localization, and application-level controllers.
- `lib/core`: Shared infrastructure, including SQLite persistence, preferences and file caching, platform communication gateways (MethodChannel), shared media models, and reusable UI components.
- `lib/features`: Feature modules with strict `domain` / `application` / `presentation` separation:
  - `library`: Local library indexing, SAF-authorized folder scanning, cover extraction/caching, metadata editing, script/document viewing (`.txt` / `.md` / `.pdf`), and DLsite matching.
  - `player`: Multiple playback sessions, queue scheduling, playback controls, DSP audio console, timelines, and subtitle overlays.
  - `asmr`: ASMR.ONE browsing, account synchronization, streaming, and reliable downloads.
  - `settings`: Global preferences, appearance, inline permission cards, and GitHub updates.
  - `data_support`: Storage analysis, selective cache cleanup, redacted diagnostics, and `.dabackup` backup/restore.
  - `video_converter`: Audio extraction from local video and format/encoding conversion.
- The local library queries ASMR.ONE through Library metadata interfaces; the application-level playback command coordinator manages playback caches. Library and Playback writable state is held by their respective Services.
- `android/`: Native Android code separated by functional package:
  - `player/`: Media3 / ExoPlayer `NativePlaybackService`, minimal foreground-service notification, system media sessions, AudioFocus, and hardware audio effects.
  - `channel/`, `scanner/`, `storage/`, `metadata/`, `subtitle/`, `update/`, `common/`: Platform Channel communication, chunked streaming scans, SAF storage, metadata extraction, system subtitle overlays, update installation, and shared native utilities.
- `windows/runner/desktop/`: Window/tray lifecycle, system media controls, subtitle overlays, and per-user scheduled tasks. Playback sessions use the libmpv player held by the Flutter-side Windows bridge.

## Android permissions

| Permission | Purpose |
|---|---|
| `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` | Direct filesystem scans and traditional file-picker paths |
| `MANAGE_EXTERNAL_STORAGE` | Optional full-storage access; unnecessary when using the SAF system picker |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` | Continuous background and screen-off playback |
| `SYSTEM_ALERT_WINDOW` | Display global subtitles above other applications |
| `SCHEDULE_EXACT_ALARM` / `RECEIVE_BOOT_COMPLETED` | Precise sleep-timer stops, scheduled next-day resumption, and persistence across reboots |
| `REQUEST_INSTALL_PACKAGES` | Launch system installation after downloading GitHub Release updates |
| `INTERNET` | ASMR.ONE content, DLsite metadata, and GitHub update checks |

## Development and verification

```powershell
flutter pub get
flutter analyze
flutter test
$tag = dart tool/verify_release.dart --print-tag
dart run tool/verify_release.dart --tag $tag
```

### Android Release builds

Official Release builds require signing configuration. The build stops immediately if `android/key.properties` or its keystore is missing; it does not fall back to an insecure debug signature.

```powershell
flutter build apk --release --obfuscate --split-debug-info=build/app/outputs/symbols
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64 --obfuscate --split-debug-info=build/app/outputs/symbols
```

### Building and using Windows

Install Flutter 3.41.6, Visual Studio's Desktop development with C++ workload, and the Windows SDK, then run:

```bat
tool\build_windows.bat
```

`tool/build_windows.bat` is the unified Windows packaging entry point. It works from any working directory, automatically downloads and verifies pinned media tools and Inno Setup, builds Release, and writes the installer and matching `.sha256` to `dist/windows/`. The installer includes required DLLs, Flutter assets, and media tools; copying only the main EXE is insufficient. Windows code signing is not configured by default. Use `-SkipBuild` only to reuse an existing Release build; it does not replace build verification.

The Windows interface uses a landscape layout with an initial client area of 1280×800 and a minimum of 960×600 logical pixels. Right-click menus replace swipe actions. Closing the window minimizes to the tray; use Exit in the tray to save data and terminate the process. Videos support in-window and fullscreen playback. Subtitle overlays remain visible with the main window in the foreground or background, can be dragged and resized horizontally, and wrap text and adjust height automatically. Vertical pages have always-visible scrollbars, and metadata tags can be copied through right-click actions.

Before running `flutter run -d windows` directly, run `tool\build_windows.bat -PrepareOnly` to prepare bundled media tools. Debug and installed builds each maintain their own single instance, and debug scheduled tasks are isolated from installed builds.

Windows uses software EQ, system media controls, and audio-output-device change events. Settings hide Permissions and background, Cache, Storage space, and mobile audio-focus options; internal caches still serve streaming, downloads, and covers. Folders are added through the Windows picker. ASMR.ONE, DLsite, video conversion, and backups use the shared workflows.

Windows keyboard controls (press `F1` for help and global shortcut registration status):

| Scope | Keys | Action |
| --- | --- | --- |
| System-wide, including background and tray | `Ctrl+Alt+Space` | Play / pause |
| System-wide | `Ctrl+Alt+←` / `→` | Previous / next track |
| System-wide | `Ctrl+Alt+↑` | Restore main window |
| Application foreground | `Ctrl+Space` | Play / pause |
| Application foreground | `Ctrl+←` / `→` | Previous / next track |
| Application foreground | `Alt+←` / `→` | Seek backward / forward 5 seconds |
| Application foreground | `Alt+↑` / `↓` | Increase / decrease the controlled session's volume by 5% |
| Main interface | `Ctrl+1` through `Ctrl+4` | Switch navigation pages in displayed order |
| Main interface | `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous page |
| Controls and menus | `Tab` / `Shift+Tab`, `Enter` | Move focus and activate controls |
| Cards | `Shift+F10` or the menu key | Open card actions |
| Menus and pages | `↑` / `↓`, `Esc` | Select items, close menus, or go back |

Text-entry fields retain their editing keys. Space first activates a focused button, and controls playback when no control consumes it. Global shortcuts already claimed by another application appear as unavailable in help. Playback commands target the same session selected by system media controls. Taskbar thumbnails provide previous, play/pause, and next buttons whose availability follows the current session.

Pending timer tasks are restored after sign-in through the current user's Windows Task Scheduler. Waking from sleep depends on hardware and power policy; waking from shutdown and playback while signed out are unsupported. Backups can only be restored on the same platform; Android SAF paths cannot be directly migrated to Windows. Upgrades preserve user data. Uninstallation removes scheduled tasks but retains the user data directory.

## Release process

Pushing a Git tag that exactly matches the `pubspec.yaml` version triggers GitHub Actions:

1. Run static analysis (`flutter analyze`), the full Flutter test suite, Android JVM tests, and validation builds for Debug APK and Windows.
2. Use the official signing keys stored in repository Secrets to build Android universal, arm64, armv7, and x64 APKs.
3. Build the Windows x64 installer, generate `.sha256` checksums for every asset, verify each APK's signature integrity and CPU ABI, and upload CI Artifacts.
4. After all build steps succeed, create a draft Release. Verify that all assets are complete and correct, then publish it as the GitHub Latest Release.

```powershell
$tag = dart tool/verify_release.dart --print-tag
dart run tool/verify_release.dart --tag $tag
git push origin main
# Wait until all main-branch CI checks pass for this commit before creating and pushing the tag.
git tag $tag
git push origin $tag
```

For the complete version history and changelog, see [release_notes.md](release_notes.md).
