# audio_service Fork

Nameless Audio uses a local `audio_service` dependency override:

```yaml
dependency_overrides:
  audio_service:
    path: third_party/audio_service
```

## Baseline

- Upstream package: `audio_service`
- Upstream version tracked in `pubspec.yaml`: `0.18.18`
- Local path: `third_party/audio_service`

## Why the Fork Exists

The app has Android-specific playback and notification requirements that are coordinated with native Kotlin services:

- foreground media playback service integration;
- media button and notification action routing;
- compatibility with grouped multi-session playback notifications;
- local changes needed before they can be removed or upstreamed.

## Maintenance Policy

- Keep the public Dart API compatible with `audio_service 0.18.18` unless an app change explicitly requires otherwise.
- Document any local fork changes near the modified code or in this file when they affect app behavior.
- Before upgrading the upstream version, compare the fork against the new upstream release, reapply only required local patches, then run `flutter analyze`, `flutter test`, `cd android && ./gradlew testDebugUnitTest && cd ..`, `flutter build apk --debug`, and `flutter build apk --release`.
- Avoid changing the fork for unrelated app fixes; prefer app-level integration code unless the plugin layer truly needs the change.
