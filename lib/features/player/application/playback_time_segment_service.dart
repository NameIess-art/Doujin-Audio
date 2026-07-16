import 'dart:async';
import 'dart:math';

import '../../../app/application/audio_path_coordinator.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../domain/time_segment_label.dart';
import 'playback_facade.dart';

final class PlaybackTimeSegmentService {
  PlaybackTimeSegmentService({
    required AudioDatabaseRepository database,
    required PlaybackFacade playback,
    required AudioPathCoordinator paths,
    DateTime Function()? now,
    Random? random,
  }) : _database = database,
       _playback = playback,
       _paths = paths,
       _now = now ?? DateTime.now,
       _random = random ?? Random() {
    _playbackSubscription = _playback.states.listen((_) => _pruneSessions());
  }

  final AudioDatabaseRepository _database;
  final PlaybackFacade _playback;
  final AudioPathCoordinator _paths;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, _TimeSegmentLoopRuntime> _loops =
      <String, _TimeSegmentLoopRuntime>{};
  final Map<String, StreamSubscription<Duration>> _positionSubscriptions =
      <String, StreamSubscription<Duration>>{};
  final Set<String> _pendingSeeks = <String>{};
  late final StreamSubscription<Object?> _playbackSubscription;
  bool _disposed = false;

  String? trackKeyForSession(String sessionId) {
    final session = _playback.sessionById(sessionId);
    final trackPath = session?.currentTrackPath;
    if (session == null || trackPath == null || trackPath.isEmpty) return null;
    final track = _paths.sessionTrackForPath(sessionId, trackPath);
    return track == null
        ? PathMatcher.normalize(trackPath)
        : TimeSegmentLabel.trackKeyFor(track);
  }

  String trackKeyForTrack(MusicTrack track) =>
      TimeSegmentLabel.trackKeyFor(track);

  Future<List<TimeSegmentLabel>> loadLabels(String trackKey) =>
      _database.loadTimeSegmentLabels(trackKey);

  Future<void> saveLabel(TimeSegmentLabel label) async {
    await _database.upsertTimeSegmentLabel(label);
    for (final entry in _loops.entries.toList(growable: false)) {
      if (entry.value.labelId == label.id) {
        _loops[entry.key] = _TimeSegmentLoopRuntime.fromLabel(label);
      }
    }
  }

  Future<void> deleteLabel(String id) async {
    await _database.deleteTimeSegmentLabel(id);
    final affected = _loops.entries
        .where((entry) => entry.value.labelId == id)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final sessionId in affected) {
      _clearLoop(sessionId);
    }
  }

  String? loopLabelIdForSession(String sessionId, {required String? trackKey}) {
    final loop = _loops[sessionId];
    return loop == null || loop.trackKey != trackKey ? null : loop.labelId;
  }

  void toggleLoop({
    required String sessionId,
    required TimeSegmentLabel label,
  }) {
    final session = _playback.sessionById(sessionId);
    if (session == null) return;
    final current = _loops[sessionId];
    if (current?.labelId == label.id && current?.trackKey == label.trackKey) {
      _clearLoop(sessionId);
      return;
    }
    _loops[sessionId] = _TimeSegmentLoopRuntime.fromLabel(label);
    _bindPosition(sessionId);
    if (trackKeyForSession(sessionId) == label.trackKey &&
        !label.contains(session.position)) {
      _seekToStart(sessionId, label.start);
    }
  }

  void handleManualSeek(String sessionId, Duration position) {
    final loop = _loops[sessionId];
    if (loop == null ||
        loop.trackKey != trackKeyForSession(sessionId) ||
        loop.contains(position)) {
      return;
    }
    _clearLoop(sessionId);
  }

  TimeSegmentLabel buildLabel({
    required String trackKey,
    required String name,
    required Duration start,
    required Duration end,
    required int colorValue,
    TimeSegmentLabel? existing,
  }) {
    final timestamp = _now();
    return TimeSegmentLabel(
      id: existing?.id ?? _newId(timestamp),
      trackKey: trackKey,
      name: name.trim(),
      start: start,
      end: end,
      colorValue: colorValue,
      createdAt: existing?.createdAt ?? timestamp,
      updatedAt: timestamp,
    );
  }

  int nextColor(List<TimeSegmentLabel> labels) {
    final used = labels.map((label) => label.colorValue).toSet();
    for (final color in kTimeSegmentLabelPalette) {
      if (!used.contains(color)) return color;
    }
    return kTimeSegmentLabelPalette[labels.length %
        kTimeSegmentLabelPalette.length];
  }

  Future<void> resetForBackupRestore() async {
    await _clearAll();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _playbackSubscription.cancel();
    await _clearAll();
  }

  void _bindPosition(String sessionId) {
    if (_positionSubscriptions.containsKey(sessionId)) return;
    final session = _playback.sessionById(sessionId);
    if (session == null) return;
    _positionSubscriptions[sessionId] = session.positionStream.listen(
      (position) => _handlePosition(sessionId, position),
    );
  }

  void _handlePosition(String sessionId, Duration position) {
    final loop = _loops[sessionId];
    if (loop == null || loop.trackKey != trackKeyForSession(sessionId)) return;
    const tolerance = Duration(milliseconds: 1500);
    if (position < loop.start - tolerance || position > loop.end + tolerance) {
      _seekToStart(sessionId, loop.start);
      return;
    }
    if (position >= loop.end && !_pendingSeeks.contains(sessionId)) {
      _seekToStart(sessionId, loop.start);
    }
  }

  void _seekToStart(String sessionId, Duration start) {
    if (_disposed || !_pendingSeeks.add(sessionId)) return;
    unawaited(
      _playback
          .seekSession(sessionId, start)
          .whenComplete(() => _pendingSeeks.remove(sessionId)),
    );
  }

  void _pruneSessions() {
    final activeIds = _playback.state.activeSessions
        .map((session) => session.id)
        .toSet();
    for (final sessionId in _positionSubscriptions.keys.toList()) {
      if (!activeIds.contains(sessionId)) _clearLoop(sessionId);
    }
  }

  void _clearLoop(String sessionId) {
    _loops.remove(sessionId);
    _pendingSeeks.remove(sessionId);
    final subscription = _positionSubscriptions.remove(sessionId);
    if (subscription != null) unawaited(subscription.cancel());
  }

  Future<void> _clearAll() async {
    _loops.clear();
    _pendingSeeks.clear();
    final subscriptions = _positionSubscriptions.values.toList(growable: false);
    _positionSubscriptions.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }

  String _newId(DateTime timestamp) {
    final randomPart = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'segment_${timestamp.microsecondsSinceEpoch}_$randomPart';
  }
}

final class _TimeSegmentLoopRuntime {
  const _TimeSegmentLoopRuntime({
    required this.trackKey,
    required this.labelId,
    required this.start,
    required this.end,
  });

  factory _TimeSegmentLoopRuntime.fromLabel(TimeSegmentLabel label) =>
      _TimeSegmentLoopRuntime(
        trackKey: label.trackKey,
        labelId: label.id,
        start: label.start,
        end: label.end,
      );

  final String trackKey;
  final String labelId;
  final Duration start;
  final Duration end;

  bool contains(Duration position) => position >= start && position <= end;
}
