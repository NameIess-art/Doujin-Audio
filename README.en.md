<p align="center">
  <img src="assets/icons/app_mark_light.png" alt="Doujin Audio app icon" width="160">
</p>

# Doujin Audio

[简体中文](README.md) | English | [日本語](README.ja.md)

An Android / Windows player for ASMR, doujin audio, and local media libraries. Play local audio and video, stream and download from ASMR.ONE, and manage multiple playback sessions with independent positions, volume, subtitles, and audio effects.

[Download](https://github.com/NameIess-art/Doujin-Audio/releases/latest) · [Changelog](release_notes.md) · [GPL-3.0](LICENSE) · [Privacy Notice](PRIVACY.md) · [Security Notice](SECURITY.md)

[Download and installation](#download-and-installation) · [Screenshots](#screenshots) · [Main features](#main-features) · [Using Windows](#using-windows) · [Development and releases](#development-and-releases)

## Download and installation

Download an installer from [GitHub Latest Release](https://github.com/NameIess-art/Doujin-Audio/releases/latest). On Android, choose universal if you are unsure of your device's architecture. Windows supports Windows 10/11 x64, with runtime dependencies included. Each installer comes with a matching `.sha256` file.

| Platform | Installer | Compatible devices |
| --- | --- | --- |
| Android universal | `DoujinAudio-android-universal-<tag>.apk` | Includes arm64-v8a, armeabi-v7a, and x86_64; suitable when the architecture is unknown |
| Android arm64-v8a | `DoujinAudio-android-arm64-<tag>.apk` | Smaller download for most modern 64-bit Android devices |
| Android armeabi-v7a | `DoujinAudio-android-armv7-<tag>.apk` | Older 32-bit ARM Android devices |
| Android x86_64 | `DoujinAudio-android-x64-<tag>.apk` | x86_64 tablets, emulators, and compatible devices |
| Windows x64 | `DoujinAudio-windows-x64-<tag>-setup.exe` | Windows 10/11; installs for the current user |

Official releases are distributed only through GitHub Releases. App-store AAB packages and an iOS version are not provided. The current version is defined in [`pubspec.yaml`](pubspec.yaml).

> **Upgrading from older versions:** The current Android application ID is `com.doujin.audio`. It installs as a separate application and cannot replace versions from before the rename or inherit their private data. Restoring a `.dabackup` requires a compatible platform and format, and its database version must not exceed the application's supported version. Data and older backup formats from before the rename are not migrated automatically.

### Getting started

1. Install the package for your platform. If Android blocks installation, allow the browser or file manager opening the APK to install unknown applications. On Windows, follow the wizard to install for the current user.
2. Add a media folder, subfolder, or individual file in the local audio library. Android uses the SAF system picker for authorization; Windows uses local folders.
3. Select a work to view its details, or select an audio/video entry to play it. You can also browse online content in ASMR.ONE; account features require sign-in.
4. Android cards support swipe actions; Windows uses right-click menus. Closing the Windows main window keeps the application running in the tray. Choose Exit from the tray to stop playback and quit.

## Screenshots

<table>
  <tr>
    <td colspan="2" align="center"><strong>ASMR.ONE</strong><br><img src="docs/screenshots/asmr-one.png" alt="ASMR.ONE" width="260"></td>
    <td colspan="2" align="center"><strong>Local audio library</strong><br><img src="docs/screenshots/local-library.png" alt="Local audio library" width="260"></td>
    <td colspan="2" align="center"><strong>Playlists</strong><br><img src="docs/screenshots/playlists.png" alt="Playlists" width="260"></td>
  </tr>
  <tr>
    <td colspan="3" align="center"><strong>Work details</strong><br><img src="docs/screenshots/work-details.png" alt="Work details" width="260"></td>
    <td colspan="3" align="center"><strong>Playback details</strong><br><img src="docs/screenshots/playback-details.png" alt="Playback details" width="260"></td>
  </tr>
</table>

## Main features

### Playback and audio effects

- **Multiple sessions and custom queues:** Keep several independent sessions, each tracking its audio, position, volume, repeat mode, subtitles, and effects. Name, sort, drag to reorder, and color queues; pause, resume, or remove sessions in batches.
- **Six playback modes:** Repeat one track, play the current folder in order or shuffle it, play across folders in order or shuffle them, or stop after one track. Removing the current track from its queue lets it play until it ends or you switch tracks manually.
- **Playback controls:** Play/pause, previous/next track, fast-forward/rewind, precise seeking, and retry after failure, with feedback while loading or buffering.
- **Audio adjustments:** EQ presets and band gains, silence skipping, light noise reduction, dynamic volume balancing, channel swap and balance, and pitch-preserving speed control from 0.25x–3.0x. Android uses native EQ; Windows uses software EQ.
- **Timeline markers:** Name and color points or segments, and loop a selected range. Markers can be saved with local metadata and backups.
- **Video playback:** Watch video on the playback details page, with fullscreen, screen-off audio playback, and an Audio only mode.

### Subtitles and scripts

- Automatically match same-name subtitles or associate them manually. Supports `.srt`, `.ass`, `.ssa`, `.vtt`, and `.lrc`. Playback details, the mini-player, and the system overlay display subtitles together, with timing adjustments, full-timeline browsing, and tap-to-seek.
- Drag subtitle overlays and customize their font, size, color, background opacity, and outline. Android requires overlay permission; Windows uses a separate always-on-top window.
- Importing local subtitles renames and moves the selected file beside the audio. Existing subtitles require overwrite confirmation; cancellation preserves the original files. Edit text and start/end times line by line, then save to the associated file in its original format, including through Android SAF.
- Manually select a Japanese `.txt` / `.md` script to match against audio and generate a timed `.lrc`. A `.txt` with valid timestamps can be imported directly. Japanese subtitles can be translated into Chinese or English and saved as an SRT containing both original and translated text.
- Recognition and translation results are saved beside local audio; results for online audio are stored in the application data directory. The first use downloads and verifies local models. Tasks support background processing, progress viewing, and resuming after interruption. **Script recognition and subtitle translation are not currently supported on 32-bit Android.**

### Local media library

- **Folders and organization:** Preserve folder hierarchies; group and sort by voice actor, tags, duration, release date, time added, or title. Search with multiple keywords, pin entries, drag to reorder, and add items to queues in batches.
- **Folder authorization:** Android uses persistent SAF authorization and also supports direct-path scans and single-file imports. Windows uses local folders. Scans update the library in batches.
- **Covers:** Extract covers from folder images, embedded audio artwork, or video frames. Prefer a file's own cover or select one manually. Duplicate embedded covers are deduplicated; WAV APIC covers are supported.
- **Work attachments:** Read `.txt`, `.md`, and `.pdf` scripts and documents on the details page. Text supports encoding detection; PDFs offer paged previews.
- **DLsite metadata:** Look up work information by RJ code, filename, or title. Match works in batches, review them individually, edit results, and confirm before saving. Local works with an RJ code can open the ASMR.ONE download page directly to add missing files to the current work folder.
- **Removal and restoration:** Undo a library removal. Removed folders are skipped in future scans and can be restored from Removed folders.

Work information is stored in `doujin-audio.json` inside the folder, including the chosen cover, timeline markers, and segment loops. Scan imports and RJ-code completion do not rewrite existing JSON. Automatic duration completion updates only missing durations, preserving other fields and entries; unreadable or incompatible files remain unchanged. Folder-work markers use relative track paths for restoration after moves, and repeated imports retain newer markers.

### ASMR.ONE and downloads

- Browse newly added works, recommendations, tags, and voice actors. Sign in to synchronize favorites and playback history. Stream audio, add it to queues, and automatically cache it after playback.
- Download individual tracks, subfolders, or complete works while preserving the original folder structure. Covers are saved separately to `Cover/<RJ code>.<extension>`. Android uses SAF download folders; Windows uses local folders.
- Pause individual tasks or all downloads, resume interrupted transfers, and retry failures. Download 1–5 works concurrently and set a retry limit of 3–10 attempts (default 5). Tasks are suspended when entering the background or before exit, then continue on resumption.
- Completed work downloads automatically refresh already-added libraries. **Download folders are not automatically added to the library**; works outside it require manual import. Existing JSON remains unchanged; new JSON is generated only after a complete, successful download with valid metadata.

### Timers and background playback

- Stop after a countdown or when the current track ends, with fade-out before stopping and automatic resumption at a preset time with fade-in.
- Android uses a native foreground media service for background and screen-off playback. Its notification shows only the application name and service status. Playback failures are retried, and pending timer tasks are restored after reboot.
- Android Doze and manufacturer background restrictions can still affect long listening sessions. Review battery optimization and background permissions under Permissions and background. WakeLocks cannot bypass system restrictions.
- Windows restores pending timer tasks through the current user's Task Scheduler. Waking from sleep depends on hardware and power policy. **Waking from shutdown and playback while signed out are not supported.**

### Personalization and data maintenance

- Choose light, dark, or system theme, a theme color, separate ASMR.ONE colors, the startup page, transition speed, reduced motion, and cover decoding quality. The interface supports Simplified Chinese, English, and Japanese.
- On Android, configure behavior after headphone disconnection, temporary audio-focus loss, or calls, and choose exclusive audio focus or mixing with other applications.
- `.dabackup` stores the library, settings, playback history and sessions, timeline markers, and ASMR.ONE credentials. Restores are validated before replacing data at the next cold start, with rollback on failure. **Restores are supported only on the same platform.**
- Persistent cover caching supports offline access and survives restarts, with no automatic eviction by age or capacity. Lists, filters, pagination, and browsing positions are retained only during the current run; reopening details loads the file tree again.
- Android provides storage analysis and selective cache cleanup. Windows hides mobile settings such as Permissions and background, Cache, and Storage space; internal caches still serve playback and downloads. Cleanup preserves source files, manually chosen covers, favorites, history, and playback state.
- Export diagnostic reports with sensitive account information removed to help report problems.
- Convert video to MP3, AAC, OGG, WAV, or FLAC, with bitrate selection, progress, and cancellation. Add the result to the library when finished.

## Supported formats

| Type | Formats |
| --- | --- |
| Audio | `flac`, `wav`, `mp3`, `m4a`, `aac`, `ogg`, `opus`, `3gp` |
| Video | `mp4`, `mkv`, `webm`, `mov`, `m4v`, `avi`, `3gp` |
| Subtitles | `.srt`, `.ass`, `.ssa`, `.vtt`, `.lrc` |
| Documents | `.txt` (encoding detection), `.md`, `.pdf` |
| Covers | `jpg`, `jpeg`, `png`, `webp`, embedded audio artwork, video frames |
| Backups | `.dabackup` |

## Using Windows

The main interface uses a landscape layout, with a default client area of 1280×800 and a minimum of 960×600 logical pixels. Windows can be resized and maximized. Use right-click menus for card actions and to copy metadata tags. Vertical pages have always-visible scrollbars. Subtitle overlays remain visible with the main window in the foreground or background; they can be dragged and resized horizontally, with automatic text wrapping and height adjustment.

Closing the main window minimizes to the tray. Exit from the tray saves data and ends the process. The application provides a single instance, system media controls, handling of audio-output-device changes, and taskbar thumbnail playback buttons. Upgrades preserve user data; uninstallation removes scheduled tasks but retains the user data directory.

Press `F1` to view keyboard help and global shortcut registration status:

| Scope | Keys | Action |
| --- | --- | --- |
| System-wide (including background and tray) | `Ctrl+Alt+Space` | Play / pause |
| System-wide | `Ctrl+Alt+←` / `→` | Previous / next track |
| System-wide | `Ctrl+Alt+↑` | Restore main window |
| Application foreground | `Ctrl+Space` | Play / pause |
| Application foreground | `Ctrl+←` / `→` | Previous / next track |
| Application foreground | `Alt+←` / `→` | Seek backward / forward 5 seconds |
| Application foreground | `Alt+↑` / `↓` | Increase / decrease the controlled session's volume by 5% |
| Main interface | `Ctrl+1` through `Ctrl+4` | Switch navigation pages in displayed order |
| Main interface | `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous page |
| Controls and menus | `Tab` / `Shift+Tab`, `Enter` | Move focus and activate controls |
| Cards | `Shift+F10` or the menu key | Open actions |
| Menus and pages | `↑` / `↓`, `Esc` | Select items, close menus, or go back |

Text fields retain their editing keys. Space first activates a focused button and controls playback if no control consumes it. Global shortcuts claimed by another application appear as unavailable in help. Playback commands use the same session-selection rules as system media controls.

## In-app updates and privacy

Check GitHub Latest Release automatically at startup or manually from settings. The application selects an installer for the platform and CPU architecture, displays download progress, and launches the Android system installer or Windows installation wizard **only after SHA-256 verification passes**. Android chooses universal if the architecture is unknown; Windows chooses the x64 installer.

Library indexes, settings, and playback state are stored locally on the device. Network access is used for ASMR.ONE, DLsite metadata, GitHub updates, and the initial download of subtitle-processing models. Online subtitles are cached locally before loading. Permissions such as file access and overlays are requested when their features are used. See the [Privacy Notice](PRIVACY.md) for details.

### Android permissions

| Permission | Purpose |
| --- | --- |
| `READ_MEDIA_AUDIO` / `READ_EXTERNAL_STORAGE` | Direct filesystem scans and traditional file selection |
| `MANAGE_EXTERNAL_STORAGE` | Optional full-storage access; not required for SAF |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` | Background and screen-off playback |
| `SYSTEM_ALERT_WINDOW` | System subtitle overlay |
| `SCHEDULE_EXACT_ALARM` / `RECEIVE_BOOT_COMPLETED` | Exact timers and task restoration after reboot |
| `REQUEST_INSTALL_PACKAGES` | Launch the system installer after downloading updates |
| `INTERNET` | Online content, metadata queries, and updates |

## Development and releases

Flutter provides shared UI and business logic. Android playback uses Media3 / ExoPlayer; Windows uses media_kit / libmpv. Code is organized by responsibility:

| Path | Responsibility |
| --- | --- |
| `lib/app/` | Startup, dependency assembly, routing, global state, themes, and language |
| `lib/core/` | Persistence, platform gateways, shared media models, and reusable components |
| `lib/features/` | Library, Player, ASMR, Settings, Data Support, and Video Converter, separated into `domain` / `application` / `presentation` |
| `android/` | Playback service, channels, scanning, storage, metadata, subtitles, and updates |
| `windows/runner/desktop/` | Windows, tray, system media controls, subtitle overlays, and scheduled tasks |
| `test/`, `integration_test/` | Unit, widget, and platform integration tests |
| `tool/` | Validation, dependency preparation, builds, and installer scripts |

### Local verification

```powershell
flutter pub get
flutter analyze
flutter test
$tag = dart tool/verify_release.dart --print-tag
dart run tool/verify_release.dart --tag $tag
```

### Android Release builds

Configure `android/key.properties` and its keystore before building. Missing official signing information stops the build; it does not fall back to debug signing.

```powershell
flutter build apk --release --obfuscate --split-debug-info=build/app/outputs/symbols
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64 --obfuscate --split-debug-info=build/app/outputs/symbols
```

### Windows builds

Install Flutter 3.41.6, Visual Studio's Desktop development with C++ workload, and the Windows SDK, then run:

```bat
tool\build_windows.bat
```

The unified script works from any working directory, downloads and verifies pinned versions of media tools and Inno Setup, then builds Release and outputs the installer and `.sha256` to `dist/windows/`. The installer includes required DLLs, Flutter assets, and media tools; copying only the main EXE is insufficient. Windows code signing is not configured by default.

Before running `flutter run -d windows` directly, run `tool\build_windows.bat -PrepareOnly` to prepare media tools. `-SkipBuild` only reuses an existing Release build and does not replace build verification. Debug and installed builds each maintain their own single instance, with debug scheduled tasks also isolated from the installed application.

### GitHub Release

[GitHub Actions](.github/workflows/flutter.yml) runs static analysis, the full Flutter test suite, Android JVM tests, validation builds for both platforms, and official packaging. Official Releases include Android universal, arm64, armv7, and x64 APKs plus a Windows x64 installer. Each asset has a matching `.sha256` file.

Before creating a tag, ensure the version matches `pubspec.yaml` and wait for all main-branch CI checks to pass for the corresponding commit:

```powershell
$tag = dart tool/verify_release.dart --print-tag
dart run tool/verify_release.dart --tag $tag
git push origin main
# Wait for all main-branch CI checks to pass for this commit before creating and pushing the tag.
git tag $tag
git push origin $tag
```

The tag workflow builds Android assets with official signing keys, verifies signatures, ABIs, and checksums, and generates the Windows installer. After every build succeeds, it creates a draft Release; publish after confirming the assets are complete. See the [Changelog](release_notes.md) for the full version history.

## Support the project

Support ongoing maintenance through [Aifadian](https://ifdian.net/a/nameIess). Sponsorship is entirely voluntary and does not unlock privileges or paid features. All features remain free.
