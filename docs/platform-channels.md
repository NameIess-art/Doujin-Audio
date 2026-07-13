# Platform Channel Contracts

Flutter screens and widgets do not create project channels. Dart calls pass
through a platform gateway or repository, and Android handlers delegate core
playback and scanning behavior to their services.

## Native playback call flow

```text
Flutter UI
  -> AudioProvider / Riverpod projection
  -> NativePlaybackRepository
  -> NativePlaybackBridge (Dart)
  -> NativePlaybackBridge (Kotlin channel handler)
  -> NativePlaybackService / Media3
```

Native playback method results use an envelope:

```text
success: { ok: true, value: ... }
failure: { ok: false, errorCode: stable_code, error: technical_message, details: ... }
```

Stable boundary codes currently include `invalid_argument`,
`service_unavailable`, `player_error`, `platform_error`, and `unexpected`.
Missing or wrongly typed required parameters must return `invalid_argument`;
they must not silently become zero or an empty identifier. Dart preserves the
code and optional details in `NativeFailure`.

Wire names remain maintained on both Dart and Kotlin sides. Whenever a channel,
method, or stable error code changes, update both
`test/platform_channels_test.dart` and Android `PlatformChannelsTest` /
`ChannelContractTest`.

## Android playback lifecycle

`NativePlaybackService` owns MediaSessionService lifecycle, sessions, foreground
state, and recovery coordination. `NativeAudioFocusController` owns requesting,
abandoning, and tracking Android AudioFocus. A focus callback returns to the
service so it can decide which intended sessions pause or resume. Playback state
published to Flutter continues to come from the real Media3 player state.
