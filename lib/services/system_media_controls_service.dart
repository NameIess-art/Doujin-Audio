import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'app_log_service.dart';

typedef SystemMediaSessionCallback = FutureOr<void> Function(String sessionId);

class SystemMediaControlsCallbacks {
  const SystemMediaControlsCallbacks({
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
    this.onSeek,
  });

  final SystemMediaSessionCallback onToggle;
  final SystemMediaSessionCallback onPrevious;
  final SystemMediaSessionCallback onNext;
  final FutureOr<void> Function(String sessionId, Duration position)? onSeek;
}

@immutable
class SystemMediaControlState {
  const SystemMediaControlState({
    required this.sessionId,
    required this.title,
    this.artist,
    this.album,
    this.thumbnail,
    required this.playing,
    required this.hasPrevious,
    required this.hasNext,
    this.position = Duration.zero,
    this.duration,
  });

  final String sessionId;
  final String title;
  final String? artist;
  final String? album;
  final String? thumbnail;
  final bool playing;
  final bool hasPrevious;
  final bool hasNext;
  final Duration position;
  final Duration? duration;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SystemMediaControlState &&
            sessionId == other.sessionId &&
            title == other.title &&
            artist == other.artist &&
            album == other.album &&
            thumbnail == other.thumbnail &&
            playing == other.playing &&
            hasPrevious == other.hasPrevious &&
            hasNext == other.hasNext &&
            position == other.position &&
            duration == other.duration;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    title,
    artist,
    album,
    thumbnail,
    playing,
    hasPrevious,
    hasNext,
    position,
    duration,
  );
}

abstract interface class SmtcController {
  Stream<PressedButton> get buttonPressStream;

  Future<void> enableSmtc();

  Future<void> disableSmtc();

  Future<void> updateConfig(SMTCConfig config);

  Future<void> updateMetadata(MusicMetadata metadata);

  Future<void> updateTimeline(PlaybackTimeline timeline);

  Future<void> setPlaybackStatus(PlaybackStatus status);

  Future<void> clearMetadata();

  Future<void> dispose();
}

class _SmtcWindowsController implements SmtcController {
  _SmtcWindowsController(SMTCWindows smtc) : _smtc = smtc;

  final SMTCWindows _smtc;

  @override
  Stream<PressedButton> get buttonPressStream => _smtc.buttonPressStream;

  @override
  Future<void> clearMetadata() => _smtc.clearMetadata();

  @override
  Future<void> disableSmtc() => _smtc.disableSmtc();

  @override
  Future<void> dispose() => _smtc.dispose();

  @override
  Future<void> enableSmtc() => _smtc.enableSmtc();

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) =>
      _smtc.setPlaybackStatus(status);

  @override
  Future<void> updateConfig(SMTCConfig config) => _smtc.updateConfig(config);

  @override
  Future<void> updateMetadata(MusicMetadata metadata) =>
      _smtc.updateMetadata(metadata);

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) =>
      _smtc.updateTimeline(timeline);
}

class SystemMediaControlsService {
  SystemMediaControlsService({
    bool Function()? isWindows,
    Future<void> Function()? initialize,
    SmtcController Function(SystemMediaControlState state)? controllerFactory,
  }) : _isWindows = isWindows ?? (() => Platform.isWindows),
       _initialize = initialize ?? SMTCWindows.initialize,
       _controllerFactory = controllerFactory ?? _defaultControllerFactory;

  final bool Function() _isWindows;
  final Future<void> Function() _initialize;
  final SmtcController Function(SystemMediaControlState state)
  _controllerFactory;

  SmtcController? _controller;
  StreamSubscription<PressedButton>? _buttonSubscription;
  SystemMediaControlsCallbacks? _callbacks;
  SystemMediaControlState? _lastState;
  bool _initialized = false;
  bool _enabled = false;

  static SmtcController _defaultControllerFactory(
    SystemMediaControlState state,
  ) {
    return _SmtcWindowsController(
      SMTCWindows(
        metadata: _metadataFor(state),
        timeline: _timelineFor(state),
        config: _configFor(state),
        status: state.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
        enabled: true,
      ),
    );
  }

  @visibleForTesting
  SystemMediaControlState? get lastState => _lastState;

  Future<void> sync(
    SystemMediaControlState? state,
    SystemMediaControlsCallbacks callbacks,
  ) async {
    _callbacks = callbacks;
    if (!_isWindows()) return;
    if (state == null || state.sessionId.isEmpty) {
      await clear();
      return;
    }
    if (_lastState == state && _enabled) return;

    try {
      await _ensureController(state);
      final controller = _controller;
      if (controller == null) return;
      if (!_enabled) {
        await controller.enableSmtc();
        _enabled = true;
      }
      await controller.updateConfig(_configFor(state));
      await controller.updateMetadata(_metadataFor(state));
      await controller.updateTimeline(_timelineFor(state));
      await controller.setPlaybackStatus(
        state.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
      );
      _lastState = state;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'system_media_controls_sync_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> clear() async {
    final controller = _controller;
    _lastState = null;
    if (controller == null || !_enabled) return;
    try {
      await controller.setPlaybackStatus(PlaybackStatus.stopped);
      await controller.clearMetadata();
      await controller.disableSmtc();
      _enabled = false;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'system_media_controls_clear_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> dispose() async {
    await _buttonSubscription?.cancel();
    _buttonSubscription = null;
    _callbacks = null;
    _lastState = null;
    final controller = _controller;
    _controller = null;
    _enabled = false;
    if (controller == null) return;
    try {
      await controller.disableSmtc();
      await controller.dispose();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'system_media_controls_dispose_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _ensureController(SystemMediaControlState state) async {
    if (!_initialized) {
      await _initialize();
      _initialized = true;
    }
    if (_controller != null) return;
    final controller = _controllerFactory(state);
    _controller = controller;
    _enabled = true;
    _buttonSubscription = controller.buttonPressStream.listen(
      _handleButton,
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.warning(
          'system_media_controls_button_stream_failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  void _handleButton(PressedButton button) {
    final state = _lastState;
    final callbacks = _callbacks;
    if (state == null || callbacks == null) return;
    switch (button) {
      case PressedButton.play:
      case PressedButton.pause:
        unawaited(Future<void>.sync(() => callbacks.onToggle(state.sessionId)));
        break;
      case PressedButton.previous:
        if (state.hasPrevious) {
          unawaited(
            Future<void>.sync(() => callbacks.onPrevious(state.sessionId)),
          );
        }
        break;
      case PressedButton.next:
        if (state.hasNext) {
          unawaited(Future<void>.sync(() => callbacks.onNext(state.sessionId)));
        }
        break;
      case PressedButton.stop:
        if (state.playing) {
          unawaited(
            Future<void>.sync(() => callbacks.onToggle(state.sessionId)),
          );
        }
        break;
      case PressedButton.fastForward:
      case PressedButton.rewind:
      case PressedButton.record:
      case PressedButton.channelUp:
      case PressedButton.channelDown:
        break;
    }
  }

  static SMTCConfig _configFor(SystemMediaControlState state) {
    return SMTCConfig(
      playEnabled: true,
      pauseEnabled: true,
      stopEnabled: true,
      nextEnabled: state.hasNext,
      prevEnabled: state.hasPrevious,
      fastForwardEnabled: false,
      rewindEnabled: false,
    );
  }

  static MusicMetadata _metadataFor(SystemMediaControlState state) {
    return MusicMetadata(
      title: state.title,
      artist: state.artist,
      album: state.album,
      albumArtist: state.artist,
      thumbnail: state.thumbnail,
    );
  }

  static PlaybackTimeline _timelineFor(SystemMediaControlState state) {
    final duration = state.duration;
    final durationMs = duration == null ? 0 : duration.inMilliseconds;
    final positionMs = state.position.inMilliseconds
        .clamp(0, durationMs)
        .toInt();
    return PlaybackTimeline(
      startTimeMs: 0,
      endTimeMs: durationMs,
      positionMs: positionMs,
      minSeekTimeMs: 0,
      maxSeekTimeMs: durationMs,
    );
  }
}
