# Android Permissions

Nameless Audio uses Android permissions for local media playback, library scanning, notifications, app updates, and background reliability.

## Media and Storage

- `READ_MEDIA_AUDIO`: reads audio files on Android 13 and newer.
- `READ_EXTERNAL_STORAGE` with `maxSdkVersion="32"`: reads audio files on Android 12L and older.
- `MANAGE_EXTERNAL_STORAGE`: supports broad folder scanning for user-selected local libraries when scoped media access is not enough.

If broad storage access is denied, users should still prefer Android's picker or folder selection flows where available. Features that depend on direct filesystem traversal may be limited.

## Playback and Background Reliability

- `FOREGROUND_SERVICE`: allows foreground services used by background audio playback.
- `FOREGROUND_SERVICE_MEDIA_PLAYBACK`: declares that the foreground service is for media playback on newer Android versions.
- `WAKE_LOCK`: keeps CPU playback work alive while the screen is off.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: opens the system flow for users who want to exempt the app from aggressive battery management.
- `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM`: improve sleep timer pause and auto-resume reliability for long-running background sessions.
- `RECEIVE_BOOT_COMPLETED`: lets the app restore native timer runtime state after reboot, package replacement, or clock changes.

During playback, Android requires a visible foreground media notification so the system can treat the app as active media playback while the screen is off. Disabling rich in-app notification controls does not remove the minimal foreground playback notification while audio is playing.

If the user denies battery optimization exemption, playback still works best-effort through the native media service and wake locks, but some OEM ROMs may stop background work more aggressively.

## Subtitle Overlay

- `SYSTEM_ALERT_WINDOW`: allows the optional global subtitle window to appear over other apps after the user enables the overlay permission.

If overlay permission is denied, in-app playback and normal subtitle parsing continue; only the global floating subtitle window is unavailable.

## Notifications

- `POST_NOTIFICATIONS`: shows playback controls on Android 13 and newer.

If notification permission is denied or rich playback notifications are disabled in the app, playback should continue through the native foreground media service, but background controls and status visibility may be limited by Android or the device vendor.

## App Updates

- `INTERNET`: checks GitHub Releases and downloads update APKs.
- `REQUEST_INSTALL_PACKAGES`: allows the in-app update flow to hand a downloaded APK to the Android installer.

If this permission is denied, users can still install updates manually from the release APK.
