# Release Quality

## Automated Checks

Pull requests and pushes to `main` must pass:

```bash
flutter pub get
flutter analyze
flutter test --coverage --concurrency=1
dart run tool/verify_coverage.dart
cd android && ./gradlew testDebugUnitTest && cd ..
flutter build apk --debug
dart run tool/verify_release.dart
```

Run the device integration smoke test on an Android release candidate:

```bash
flutter test integration_test/app_smoke_test.dart -d <device-id>
```

Use [`release-candidate-template.md`](release-candidate-template.md) for the
required device and performance evidence. A blank template is not evidence and
does not satisfy release acceptance.

Repository administrators must configure the `main` branch protection rule so
the Ubuntu coverage job and Android JVM/debug-APK job are required before
merge. This is GitHub state and
must be verified in repository settings; the workflow file alone cannot enforce
the rule.

Tag workflows must verify the generated APK names and their SHA-256 files
before uploading them. Android assets must also pass `apksigner verify` and
must not contain an Android Debug signing certificate.

## Android Release Candidate Matrix

Record device model, Android version, app version, result, and notes for every
release candidate.

| Area | Required smoke test |
|---|---|
| Startup | Cold start, startup-page preference, reduced-motion startup |
| Local library | SAF folder import, refresh, deletion detection, large library |
| ASMR.ONE | Login restore, browse, playback, remote cover notification |
| Playback | Background playback, screen off, seek, speed, audio effects |
| Multi-session | Start, pause, resume, remove, restore after process restart |
| Notification | Play/pause, next/previous, open session, dismiss behavior |
| Timer | Pause on expiry, auto-resume, reboot/process-restart recovery |
| Subtitle overlay | Permission handoff, display, and close |
| Update | Valid checksum install; missing/mismatched checksum refusal |
| Permissions | First launch with all optional permissions denied; contextual request timing |
| Backup | Export, validate, restore, corrupted backup refusal, rollback after failure |

## Performance Baselines

Capture profile-mode measurements on the same reference device and record the
median of at least three runs. Initially these are observational. Once stable,
fail release review when a metric regresses by more than 20% without an
approved explanation.

Use the same device, build mode, app version, data set, and network condition
for a comparison series. Prefer profile builds for Flutter frame analysis and
release candidates for final install/update checks. Record the median, app
version, device model, Android version, and any unusual notes.

| Metric | Measurement |
|---|---|
| Cold startup | Launch to first interactive frame |
| First library frame | Startup to populated/empty library state |
| Long-list scrolling | Flutter DevTools frame times and jank count |
| Player detail drag | Drag down to reveal the previous page while playback continues |
| System interaction | Notification shade pull-down and background/foreground switch responsiveness |
| Cover loading | Time to stable visible covers in ASMR.ONE and local library lists |
| Large-library scan | Scan duration, peak memory, discovered track count |

A regression over 20% blocks release unless the release notes record the
measured reason and approval.

Keep profile traces and the completed release-candidate matrix with the release
notes or linked issue; do not commit device-specific traces to the repository.
