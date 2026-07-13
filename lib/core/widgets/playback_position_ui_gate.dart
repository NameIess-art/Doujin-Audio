import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/player/domain/playback_session.dart';
import '../media/subtitle_parser.dart';
import '../../features/player/application/ui_interaction_coordinator.dart';

@immutable
class PlaybackPositionUiSnapshot {
  const PlaybackPositionUiSnapshot({
    required this.position,
    required this.duration,
    required this.bufferedPosition,
  });

  factory PlaybackPositionUiSnapshot.fromSession(PlaybackSession session) {
    return PlaybackPositionUiSnapshot(
      position: session.position,
      duration: session.duration,
      bufferedPosition: session.bufferedPosition,
    );
  }

  final Duration position;
  final Duration? duration;
  final Duration bufferedPosition;

  PlaybackPositionUiSnapshot copyWith({
    Duration? position,
    Object? duration = _durationUnchanged,
    Duration? bufferedPosition,
  }) {
    return PlaybackPositionUiSnapshot(
      position: position ?? this.position,
      duration: identical(duration, _durationUnchanged)
          ? this.duration
          : duration as Duration?,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlaybackPositionUiSnapshot &&
        other.position == position &&
        other.duration == duration &&
        other.bufferedPosition == bufferedPosition;
  }

  @override
  int get hashCode => Object.hash(position, duration, bufferedPosition);
}

const Object _durationUnchanged = Object();

class PlaybackPositionUiGate extends ChangeNotifier {
  PlaybackPositionUiGate({
    required PlaybackSession session,
    UiInteractionCoordinator? interactionCoordinator,
    this.minUpdateInterval = const Duration(milliseconds: 32),
    this.deferDuringInteraction = true,
    this.includeBufferedPosition = true,
  }) : _session = session,
       _interactionCoordinator =
           interactionCoordinator ?? UiInteractionCoordinator.instance,
       _value = PlaybackPositionUiSnapshot.fromSession(session) {
    _bindSession();
    _interactionCoordinator.addListener(_handleInteractionChanged);
  }

  final UiInteractionCoordinator _interactionCoordinator;
  final Duration minUpdateInterval;
  final bool deferDuringInteraction;
  final bool includeBufferedPosition;
  PlaybackSession _session;
  PlaybackPositionUiSnapshot _value;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _bufferedSub;
  bool _disposed = false;
  bool _dirty = false;
  bool _tickerModeEnabled = true;
  int _lastNotifyMs = 0;

  PlaybackPositionUiSnapshot get value => _value;

  bool get tickerModeEnabled => _tickerModeEnabled;

  set tickerModeEnabled(bool enabled) {
    if (_tickerModeEnabled == enabled) return;
    _tickerModeEnabled = enabled;
    if (enabled && _dirty) {
      _publish(force: true);
    }
  }

  void updateSession(PlaybackSession session) {
    if (identical(_session, session)) return;
    _unbindSession();
    _session = session;
    _value = PlaybackPositionUiSnapshot.fromSession(session);
    _dirty = false;
    _bindSession();
    _publish(force: true);
  }

  void _bindSession() {
    _positionSub = _session.positionStream.listen((position) {
      _updateValue(_value.copyWith(position: position));
    });
    _durationSub = _session.durationStream.listen((duration) {
      _updateValue(_value.copyWith(duration: duration));
    });
    if (includeBufferedPosition) {
      _bufferedSub = _session.bufferedPositionStream.listen((buffered) {
        _updateValue(_value.copyWith(bufferedPosition: buffered));
      });
    }
  }

  void _unbindSession() {
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_bufferedSub?.cancel());
    _positionSub = null;
    _durationSub = null;
    _bufferedSub = null;
  }

  void _updateValue(PlaybackPositionUiSnapshot nextValue) {
    if (_value == nextValue) return;
    _value = nextValue;
    _publish();
  }

  void _publish({bool force = false}) {
    if (_disposed) return;
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
      return;
    }
    _dirty = false;
    _lastNotifyMs = now;
    notifyListeners();
  }

  void _handleInteractionChanged() {
    if (!_interactionCoordinator.isInteracting && _dirty) {
      _publish(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
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

  String? resolve({
    required String trackPath,
    required Duration position,
    required SubtitleTrack? track,
  }) {
    if (_trackPath != trackPath || !identical(_track, track)) {
      _trackPath = trackPath;
      _track = track;
      _cue = null;
      _text = null;
    }
    final cachedCue = _cue;
    if (cachedCue != null && cachedCue.contains(position)) {
      return _text;
    }
    final nextCue = track?.cueAt(position);
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
  }
}
