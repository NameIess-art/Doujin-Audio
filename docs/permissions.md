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

If the user denies battery optimization exemption, playback still works best-effort through media services and wake locks, but some OEM ROMs may stop background work more aggressively.

## Notifications

- `POST_NOTIFICATIONS`: shows playback controls on Android 13 and newer.

If notification permission is denied or playback notifications are disabled in the app, playback should continue without rich notification controls.

## App Updates

- `REQUEST_INSTALL_PACKAGES`: allows the in-app update flow to hand a downloaded APK to the Android installer.

If this permission is denied, users can still install updates manually from the release APK.
