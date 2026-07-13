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

File-cache calls use the same success/failure envelope as playback. The Android
handler wraps synchronous work and delayed picker/export activity results with
`ChannelEnvelopeResult`; implemented methods never call Dart's `result.error`.
Only unknown methods use `notImplemented`. `NativeResult<T>` is the single
strict Dart decoder: missing `ok`, malformed values, or incomplete failure
fields become `platform_error` rather than being interpreted as legacy data.

File-cache calls use `ChannelArgumentReader` in the Android handler for required
strings, integers, floating-point values, booleans, byte arrays, lists, and
maps. A missing or wrongly typed required value is reported as
`invalid_argument` with the method name in details. Cache indexes, cache limits,
scan chunk sizes, and overwrite flags are never synthesized from missing
arguments. File and scan work remains on the existing bounded executors.

Folder scan events use one wire shape. Every event contains `taskId`,
`generationId`, and `eventType`; failures additionally contain `errorCode`,
`error`, and optional `details`. The old `sessionId`, `type`, `code`, and
`message` fields are not accepted. The native stream validates the active task,
cancel flag, listener generation, and sink immediately before delivery, so a
detached listener, cancellation, or stale generation cannot publish an event.

## Android playback lifecycle

`NativePlaybackService` owns MediaSessionService lifecycle, sessions, foreground
state, and true Media3 state publication. `NativePlaybackRecoveryController`
owns playback intent, recovery windows, scheduled retry/expiry tasks, and
network/screen recovery triggers through `NativePlaybackRecoveryHost` and a
replaceable environment. `NativeAudioFocusController` owns requesting,
abandoning, and tracking Android AudioFocus. A focus callback returns to the
service so it can decide which intended sessions pause or resume. Playback state
published to Flutter continues to come from the real Media3 player state.
