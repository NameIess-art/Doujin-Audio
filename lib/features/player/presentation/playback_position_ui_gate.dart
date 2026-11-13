import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/media/subtitle_parser.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../application/playback_session_snapshot.dart';

import '../application/playback_session.dart' show PlaybackPositionSample;

typedef PlaybackPositionUiSnapshot = PlaybackPositionSample;

class PlaybackPositionUiGate extends ChangeNotifier {
  PlaybackPositionUiGate({
    required PlaybackSessionSnapshot session,
    UiInteractionCoordinator? interactionCoordinator,
    this.minUpdateInterval = const Duration(milliseconds: 32),
    this.deferDuringInteraction = true,
    this.includeBufferedPosition = true,
  }) : _session = session,
       _interactionCoordinator =
           interactionCoordinator ?? UiInteractionCoordinator.instance,
       _value = session.progress {
    _publishedValue = _value;
    _bindSession();
    _interactionCoordinator.addListener(_handleInteractionChanged);
  }

  final UiInteractionCoordinator _interactionCoordinator;
  final Duration minUpdateInterval;
  final bool deferDuringInteraction;
  final bool includeBufferedPosition;
  PlaybackSessionSnapshot _session;
  PlaybackPositionUiSnapshot _value;
  late PlaybackPositionUiSnapshot _publishedValue;
  Object? _pendingPublish;
  StreamSubscription<PlaybackPositionSample>? _progressSub;
  Timer? _throttleTimer;
  bool _disposed = false;
  bool _dirty = false;
  bool _tickerModeEnabled = true;
  int _lastNotifyMs = 0;
  int _sessionGeneration = 0;

  PlaybackPositionUiSnapshot get value => _value;

  bool get tickerModeEnabled => _tickerModeEnabled;

  set tickerModeEnabled(bool enabled) {
    if (_tickerModeEnabled == enabled) return;
    _tickerModeEnabled = enabled;
    if (enabled && _dirty) {
      _publish(force: true);
    }
  }

  void updateSession(PlaybackSessionSnapshot session) {
    if (identical(_session, session)) return;
    final streamsChanged =
        _session.id != session.id ||
        _session.progressStream != session.progressStream;
    final trackChanged = _session.currentTrackPath != session.currentTrackPath;
    _session = session;
    if (streamsChanged) {
      _sessionGeneration++;
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _unbindSession();
      _value = session.progress;
      _dirty = false;
      _bindSession();
      _publish(force: true);
    } else {
      final nextValue = _value.copyWith(
        position: trackChanged ? session.position : null,
        duration: session.duration,
        bufferedPosition: session.bufferedPosition,
      );
      if (_value != nextValue) {
        if (trackChanged) {
          _value = nextValue;
          _publish(force: true);
        } else {
          _updateValue(nextValue);
        }
      }
    }
  }

  void _bindSession() {
    final generation = _sessionGeneration;
    _progressSub = _session.progressStream.listen((sample) {
      if (_disposed || generation != _sessionGeneration) return;
      if (includeBufferedPosition) {
        _updateValue(sample);
      } else if (_value.position != sample.position ||
          _value.duration != sample.duration) {
        _updateValue(
          sample.copyWith(bufferedPosition: _value.bufferedPosition),
        );
      }
    });
  }

  void _unbindSession() {
    unawaited(_progressSub?.cancel());
    _progressSub = null;
  }

  void _updateValue(PlaybackPositionUiSnapshot nextValue) {
    if (_value == nextValue) return;
    _value = nextValue;
    _dirty = true;
    if (_pendingPublish != null) return;
    final pending = _pendingPublish = Object();
    // Coalesce same-turn updates and let an intervening session replacement
    // invalidate a queued publication before notifying the widget.
    scheduleMicrotask(() {
      if (_disposed || !identical(_pendingPublish, pending)) return;
      _pendingPublish = null;
      _publish();
    });
  }

  void _publish({bool force = false}) {
    if (_disposed) return;
    if (force) {
      _pendingPublish = null;
      _throttleTimer?.cancel();
      _throttleTimer = null;
    }
    if (_value == _publishedValue) {
      _dirty = false;
      return;
    }
    if (!_tickerModeEnabled ||
        (deferDuringInteraction && _interactionCoordinator.isInteracting)) {
      _dirty = true;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        minUpdateInterval > Duration.zero &&
        now - _lastNotifyMs < minUpdateInterval.inMilliseconds) {
      _dirty = true;
      _scheduleThrottleFlush(
        Duration(
          milliseconds:
              minUpdateInterval.inMilliseconds - (now - _lastNotifyMs),
        ),
      );
      return;
    }
    _dirty = false;
    _lastNotifyMs = now;
    _publishedValue = _value;
    notifyListeners();
  }

  void _scheduleThrottleFlush(Duration delay) {
    if (_throttleTimer != null || _disposed) return;
    _throttleTimer = Timer(delay, () {
      _throttleTimer = null;
      if (_dirty) _publish(force: true);
    });
  }

  void _handleInteractionChanged() {
    if (!_interactionCoordinator.isInteracting && _dirty) {
      _publish(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingPublish = null;
    _sessionGeneration++;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _interactionCoordinator.removeListener(_handleInteractionChanged);
    _unbindSession();
    super.dispose();
  }
}

class SubtitleTextCache {
  String? _trackPath;
  SubtitleTrack? _track;
  SubtitleCue? _cue;
  String? _text;
  bool _persistent = false;

  String? resolve({
    required String trackPath,
    required Duration position,
    required SubtitleTrack? track,
    bool persistent = false,
  }) {
    if (_trackPath != trackPath ||
        !identical(_track, track) ||
        _persistent != persistent) {
      _trackPath = trackPath;
      _track = track;
      _persistent = persistent;
      _cue = null;
      _text = null;
    }
    final nextCue = track?.cueAt(position, persistent: persistent);
    if (identical(nextCue, _cue)) {
      return _text;
    }
    _cue = nextCue;
    final text = nextCue?.text.trim();
    _text = text == null || text.isEmpty ? null : text;
    return _text;
  }

  void clear() {
    _trackPath = null;
    _track = null;
    _cue = null;
    _text = null;
    _persistent = false;
  }
}
