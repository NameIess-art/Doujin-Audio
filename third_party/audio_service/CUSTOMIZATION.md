# audio_service customization notes

This is a local fork of [audio_service 0.18.18](https://github.com/ryanheise/audio_service)
kept under `third_party/audio_service/`. The `pubspec.yaml` overrides the published
package via `dependency_overrides`.

## Why forked

The published `audio_service` makes assumptions that conflict with this app's
multi-session playback model and custom native notification pipeline:

1. **Ongoing notification policy** — upstream always respects
   `androidNotificationOngoing` config. We need the notification to stay ongoing
   while audio is actively playing, even when `androidNotificationOngoing` is
   `false`, so Android does not kill the foreground service mid-playback.

2. **Foreground service type** — upstream calls `startForeground(id, notification)`
   (the deprecated single-arg overload). We call the 3-arg overload with
   `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` required by Android 14+.

3. **Foreground exit on pause** — upstream unconditionally exits the foreground
   service when `androidStopForegroundOnPause` is set. We keep the service in
   foreground (releasing only the wake lock and updating the notification) when
   `androidNotificationOngoing` is `false` so the notification card stays visible.

4. **Notification metadata** — added `CATEGORY_TRANSPORT`, `setOnlyAlertOnce(true)`,
   and `FOREGROUND_SERVICE_IMMEDIATE` to prevent notification spam and ensure
   the notification appears instantly.

## Dart-side changes

| Change | Location |
|---|---|
| `AudioService.stopService()` made public | `lib/audio_service.dart` ~L1236 |
| (was package-private `_stop`) | |

This allows our native bridge to explicitly tear down the MediaSession when the
last playback session is removed, preventing ghost MediaSession notifications.

## Native (Android) changes

All in `android/src/main/java/com/ryanheise/audioservice/AudioService.java`:

| Change | Lines |
|---|---|
| `internalStartForeground()` uses `ServiceCompat.startForeground()` with `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK` | ~813 |
| `exitPlayingState()` keeps foreground when `!config.androidNotificationOngoing` | ~799 |
| `shouldKeepNotificationOngoing()` returns `config.androidNotificationOngoing \|\| playing` | ~821 |
| Notification builder adds `CATEGORY_TRANSPORT`, `setOnlyAlertOnce(true)`, `FOREGROUND_SERVICE_IMMEDIATE` | ~751 |
| `buildNotification()` / `buildSummaryNotification()` use `shouldKeepNotificationOngoing()` instead of raw config | ~686, ~709 |

## Maintenance

- Upstream version: **0.18.18** (commit reference lost — fork was bulk-imported)
- The only modifications are to `AudioService.java` and `audio_service.dart`
- When updating upstream, re-apply these changes to the new version
- The `androidNotificationOngoing` config should remain `false` in our
  `AudioServiceConfig` — the dynamic behavior is driven by playback state
