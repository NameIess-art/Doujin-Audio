part of 'audio_provider.dart';

class _TimeSegmentLoopRuntime {
  const _TimeSegmentLoopRuntime({
    required this.trackKey,
    required this.labelId,
    required this.start,
    required this.end,
  });

  factory _TimeSegmentLoopRuntime.fromLabel(TimeSegmentLabel label) {
    return _TimeSegmentLoopRuntime(
      trackKey: label.trackKey,
      labelId: label.id,
      start: label.start,
      end: label.end,
    );
  }

  final String trackKey;
  final String labelId;
  final Duration start;
  final Duration end;

  bool contains(Duration position) => position >= start && position <= end;
}

extension AudioProviderTimeSegments on AudioProvider {
  String? timeSegmentTrackKeyForSession(String sessionId) {
    final session = _sessions[sessionId];
    final trackPath = session?.currentTrackPath;
    if (trackPath == null || trackPath.isEmpty) return null;
    final track = session == null
        ? null
        : _sessionTrackForPath(session, trackPath);
    if (track == null) return PathMatcher.normalize(trackPath);
    return TimeSegmentLabel.trackKeyFor(track);
  }

  String timeSegmentTrackKeyForTrack(MusicTrack track) {
    return TimeSegmentLabel.trackKeyFor(track);
  }

  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) {
    return _audioDatabaseRepository.loadTimeSegmentLabels(trackKey);
  }

  Future<void> saveTimeSegmentLabel(TimeSegmentLabel label) async {
    await _audioDatabaseRepository.upsertTimeSegmentLabel(label);
    for (final entry in _timeSegmentLoopsBySessionId.entries.toList()) {
      if (entry.value.labelId != label.id) continue;
      _timeSegmentLoopsBySessionId[entry.key] =
          _TimeSegmentLoopRuntime.fromLabel(label);
    }
  }

  Future<void> deleteTimeSegmentLabel(String id) async {
    await _audioDatabaseRepository.deleteTimeSegmentLabel(id);
    final sessionIds = _timeSegmentLoopsBySessionId.entries
        .where((entry) => entry.value.labelId == id)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final sessionId in sessionIds) {
      _clearTimeSegmentLoopForSession(sessionId);
    }
  }

  String? timeSegmentLoopLabelIdForSession(
    String sessionId, {
    required String? trackKey,
  }) {
    final runtime = _timeSegmentLoopsBySessionId[sessionId];
    if (runtime == null || runtime.trackKey != trackKey) return null;
    return runtime.labelId;
  }

  void toggleTimeSegmentLoop({
    required String sessionId,
    required TimeSegmentLabel label,
  }) {
    final session = _sessions[sessionId];
    if (session == null) return;
    final current = _timeSegmentLoopsBySessionId[sessionId];
    if (current?.labelId == label.id && current?.trackKey == label.trackKey) {
      _clearTimeSegmentLoopForSession(sessionId);
      return;
    }
    _timeSegmentLoopsBySessionId[sessionId] = _TimeSegmentLoopRuntime.fromLabel(
      label,
    );
    _bindTimeSegmentLoopPosition(sessionId);
    if (timeSegmentTrackKeyForSession(sessionId) == label.trackKey &&
        !label.contains(session.position)) {
      _seekTimeSegmentLoopToStart(sessionId, label.start);
    }
    _notifyPlaybackChanged();
  }

  void handleTimeSegmentManualSeek(String sessionId, Duration position) {
    final runtime = _timeSegmentLoopsBySessionId[sessionId];
    if (runtime == null ||
        runtime.trackKey != timeSegmentTrackKeyForSession(sessionId) ||
        runtime.contains(position)) {
      return;
    }
    _clearTimeSegmentLoopForSession(sessionId);
  }

  void _bindTimeSegmentLoopPosition(String sessionId) {
    if (!_timeSegmentLoopBoundSessionIds.add(sessionId)) return;
    final session = _sessions[sessionId];
    if (session == null) {
      _timeSegmentLoopBoundSessionIds.remove(sessionId);
      return;
    }
    final subscription = session.positionStream.listen(
      (position) => _handleTimeSegmentLoopPosition(sessionId, position),
    );
    session.subscriptions.add(subscription);
  }

  void _handleTimeSegmentLoopPosition(String sessionId, Duration position) {
    final runtime = _timeSegmentLoopsBySessionId[sessionId];
    if (runtime == null ||
        runtime.trackKey != timeSegmentTrackKeyForSession(sessionId)) {
      return;
    }
    const tolerance = Duration(milliseconds: 1500);
    if (position < runtime.start - tolerance ||
        position > runtime.end + tolerance) {
      _seekTimeSegmentLoopToStart(sessionId, runtime.start);
      return;
    }
    if (position >= runtime.end &&
        !_timeSegmentLoopSeekPendingSessionIds.contains(sessionId)) {
      _seekTimeSegmentLoopToStart(sessionId, runtime.start);
    }
  }

  void _seekTimeSegmentLoopToStart(String sessionId, Duration start) {
    if (!_timeSegmentLoopSeekPendingSessionIds.add(sessionId)) return;
    unawaited(
      _playbackFacade.seekSession(sessionId, start).whenComplete(() {
        _timeSegmentLoopSeekPendingSessionIds.remove(sessionId);
      }),
    );
  }

  void _clearTimeSegmentLoopForSession(String sessionId) {
    final removed = _timeSegmentLoopsBySessionId.remove(sessionId);
    _timeSegmentLoopSeekPendingSessionIds.remove(sessionId);
    if (removed != null) {
      _notifyPlaybackChanged();
    }
  }

  void _forgetTimeSegmentLoopSession(String sessionId) {
    _timeSegmentLoopsBySessionId.remove(sessionId);
    _timeSegmentLoopBoundSessionIds.remove(sessionId);
    _timeSegmentLoopSeekPendingSessionIds.remove(sessionId);
  }

  TimeSegmentLabel buildTimeSegmentLabel({
    required String trackKey,
    required String name,
    required Duration start,
    required Duration end,
    required int colorValue,
    TimeSegmentLabel? existing,
  }) {
    final now = DateTime.now();
    return TimeSegmentLabel(
      id: existing?.id ?? _newTimeSegmentId(now),
      trackKey: trackKey,
      name: name.trim(),
      start: start,
      end: end,
      colorValue: colorValue,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
  }

  int nextTimeSegmentColor(List<TimeSegmentLabel> labels) {
    final used = labels.map((label) => label.colorValue).toSet();
    for (final color in kTimeSegmentLabelPalette) {
      if (!used.contains(color)) return color;
    }
    return kTimeSegmentLabelPalette[labels.length %
        kTimeSegmentLabelPalette.length];
  }

  String _newTimeSegmentId(DateTime now) {
    final randomPart = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'segment_${now.microsecondsSinceEpoch}_$randomPart';
  }
}
