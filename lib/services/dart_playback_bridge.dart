import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as media;

import 'native_playback_bridge.dart';
import 'native_result.dart';
import 'path_matcher.dart';
import '../models/audio_effects.dart';
import '../platform/app_platform.dart';

const String _legacyChannelSwapAudioFilterLabel = '@channel_swap';
const String _channelSwapAudioFilterLabel = '@na_channel_swap';
const String _panningAudioFilterLabel = '@na_panning';
const String _skipSilenceAudioFilterLabel = '@na_skip_silence';
const String _noiseReductionAudioFilterLabel = '@na_noise_reduction';
const String _volumeNormalizationAudioFilterLabel = '@na_volume_norm';
const String _equalizerAudioFilterLabel = '@na_eq';
const List<String> _managedAudioFilterLabels = <String>[
  _skipSilenceAudioFilterLabel,
  _noiseReductionAudioFilterLabel,
  _volumeNormalizationAudioFilterLabel,
  _equalizerAudioFilterLabel,
  _panningAudioFilterLabel,
  _channelSwapAudioFilterLabel,
  _legacyChannelSwapAudioFilterLabel,
];
const List<int> _windowsEqBandFrequencies = <int>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];
const String _windowsSkipSilenceFilter =
    '$_skipSilenceAudioFilterLabel:lavfi=[silenceremove=stop_periods=-1:stop_duration=0.9:stop_threshold=-60dB]';
const String _windowsNoiseReductionFilter =
    '$_noiseReductionAudioFilterLabel:lavfi=[afftdn=nr=6:nf=-55]';
const String _windowsVolumeNormalizationFilter =
    '$_volumeNormalizationAudioFilterLabel:lavfi=[dynaudnorm=f=500:g=5:p=0.6:m=3,alimiter=limit=0.95]';

@visibleForTesting
const EqCapabilities dartPlaybackWindowsEqCapabilities = EqCapabilities(
  supported: true,
  bands: <EqBandInfo>[
    EqBandInfo(frequencyHz: 31),
    EqBandInfo(frequencyHz: 62),
    EqBandInfo(frequencyHz: 125),
    EqBandInfo(frequencyHz: 250),
    EqBandInfo(frequencyHz: 500),
    EqBandInfo(frequencyHz: 1000),
    EqBandInfo(frequencyHz: 2000),
    EqBandInfo(frequencyHz: 4000),
    EqBandInfo(frequencyHz: 8000),
    EqBandInfo(frequencyHz: 16000),
  ],
);

@visibleForTesting
List<String> buildDartPlaybackAudioFiltersForTest(NativeAudioEffects effects) {
  return _buildDartPlaybackAudioFilters(
    effects.state,
    channelSwapEnabled: effects.channelSwapEnabled,
  ).map((filter) => filter.value).toList(growable: false);
}

class DartPlaybackBridge implements NativePlaybackBridgeBase {
  DartPlaybackBridge() {
    _ensureMediaKitInitialized();
  }

  static bool _mediaKitInitialized = false;

  static void _ensureMediaKitInitialized() {
    if (_mediaKitInitialized) return;
    media.MediaKit.ensureInitialized();
    _mediaKitInitialized = true;
  }

  final Map<String, _DartPlaybackSession> _sessions = {};
  final StreamController<NativePlaybackSnapshot> _snapshots =
      StreamController<NativePlaybackSnapshot>.broadcast();
  String? _focusedSessionId;

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;

  @override
  void startListening() {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
    await _snapshots.close();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> prepareSession({
    required String sessionId,
    required Uri uri,
    required String title,
    String? path,
    String? subtitle,
    Uri? artUri,
    Duration startPosition = Duration.zero,
    double volume = 1.0,
    bool repeatOne = false,
    bool autoPlay = false,
    double speed = 1.0,
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) async {
    if (uri.scheme == 'content') {
      return const NativeFailure(
        'Android content URI playback is not supported on Windows.',
      );
    }

    try {
      final session = _sessions.putIfAbsent(
        sessionId,
        () => _DartPlaybackSession(
          sessionId: sessionId,
          onChanged: () => _emit(sessionId),
        ),
      );
      _focusedSessionId = sessionId;
      final items = _itemsFor(
        uri: uri,
        title: title,
        path: path,
        subtitle: subtitle,
        artUri: artUri,
        queue: queue,
        queueStartIndex: queueStartIndex,
      );
      session.volume = _normalizeSessionVolume(volume);
      session.speed = _normalizeSessionSpeed(speed);
      await session.setItems(
        items,
        initialIndex: queueStartIndex ?? 0,
        initialPosition: startPosition,
      );
      await _applyLoopAndShuffle(
        session,
        repeatOne: repeatOne,
        repeatAll: repeatAll,
        shuffle: shuffle,
      );
      if (autoPlay) {
        unawaited(_playSession(session));
      }
      return NativeSuccess(_emit(sessionId));
    } catch (error) {
      return NativeFailure(error.toString());
    }
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    _focusedSessionId = sessionId;
    unawaited(_playSession(session));
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.pause();
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.stop();
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.seek(position);
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.setVolume(volume, reloadSource: reloadSource);
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setSpeed(
    String sessionId,
    double speed,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.setSpeed(speed);
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setRepeatOne(
    String sessionId,
    bool repeatOne, {
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await _applyLoopAndShuffle(
      session,
      repeatOne: repeatOne,
      repeatAll: repeatAll,
      shuffle: shuffle,
    );
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    try {
      await session.setAudioEffects(effects);
    } catch (error) {
      return NativeFailure(error.toString());
    }
    return NativeSuccess(_snapshotFor(sessionId));
  }

  @override
  Future<NativeResult<void>> removeSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (_focusedSessionId == sessionId) _focusedSessionId = null;
    await session?.dispose();
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> pauseAll() async {
    await Future.wait(_sessions.values.map((session) => session.pause()));
    for (final sessionId in _sessions.keys) {
      _emit(sessionId);
    }
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> clearAll() async {
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
    _focusedSessionId = null;
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> setForegroundEnabled(bool enabled) async {
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> dismissNotifications() async {
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> undismissNotifications() async {
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() async {
    return NativeSuccess(
      NativePlaybackBundleSnapshot(
        sessions: _sessions.keys.map(_snapshotFor).toList(growable: false),
        focusedSessionId: _focusedSessionId,
      ),
    );
  }

  Future<void> _playSession(_DartPlaybackSession session) async {
    try {
      await session.play();
    } catch (error) {
      debugPrint('DartPlaybackBridge.play error: $error');
    } finally {
      if (_sessions.containsKey(session.sessionId)) {
        _emit(session.sessionId);
      }
    }
  }

  List<_DartPlaybackItem> _itemsFor({
    required Uri uri,
    required String title,
    required String? path,
    required String? subtitle,
    required Uri? artUri,
    required List<Map<String, Object?>>? queue,
    required int? queueStartIndex,
  }) {
    final queueItems = queue
        ?.map(_itemFromMap)
        .whereType<_DartPlaybackItem>()
        .toList(growable: false);
    if (queueItems != null && queueItems.isNotEmpty) {
      return queueItems;
    }
    return <_DartPlaybackItem>[
      _DartPlaybackItem(
        uri: uri,
        path: path ?? _pathFromUri(uri),
        title: title,
        subtitle: subtitle,
        artUri: artUri?.toString(),
      ),
    ];
  }

  _DartPlaybackItem? _itemFromMap(Map<String, Object?> map) {
    final rawUri = map['uri']?.toString();
    final uri = rawUri == null ? null : Uri.tryParse(rawUri);
    if (uri == null || uri.scheme == 'content') return null;
    final rawPath = map['path']?.toString();
    return _DartPlaybackItem(
      uri: uri,
      path: rawPath == null || rawPath.isEmpty ? _pathFromUri(uri) : rawPath,
      title: map['title']?.toString(),
      subtitle: map['subtitle']?.toString(),
      artUri: map['artUri']?.toString(),
    );
  }

  Future<void> _applyLoopAndShuffle(
    _DartPlaybackSession session, {
    required bool repeatOne,
    required bool repeatAll,
    required bool shuffle,
  }) async {
    await session.setPlaybackMode(
      repeatOne: repeatOne,
      repeatAll: repeatAll,
      shuffle: shuffle,
    );
  }

  NativePlaybackSnapshot _emit(String sessionId) {
    final snapshot = _snapshotFor(sessionId);
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
    return snapshot;
  }

  NativePlaybackSnapshot _snapshotFor(String sessionId) {
    final session = _sessions[sessionId]!;
    final item = session.currentItem;
    return NativePlaybackSnapshot(
      sessionId: sessionId,
      uri: item?.uri.toString(),
      path: item?.path,
      title: item?.title,
      subtitle: item?.subtitle,
      artUri: item?.artUri,
      playing: session.playing,
      playWhenReady: session.playWhenReady,
      processingState: session.processingState,
      position: session.position,
      bufferedPosition: session.bufferedPosition,
      duration: session.duration,
      volume: session.volume,
      speed: session.speed,
      boostGain: _boostGainFor(session.volume),
      channelSwapEnabled: session.channelSwapEnabled,
      audioEffects: session.audioEffects,
      eqCapabilities: dartPlaybackWindowsEqCapabilities,
      queueIndex: session.currentIndex,
    );
  }
}

class _DartPlaybackSession {
  _DartPlaybackSession({required this.sessionId, required this.onChanged}) {
    void bind<T>(Stream<T> stream, void Function(T value) update) {
      subscriptions.add(
        stream.listen(
          (value) {
            if (suppressPlaybackEvents) return;
            update(value);
            _notifyChanged();
          },
          onError: (e, st) {
            debugPrint('DartPlaybackSession stream error: $e\n$st');
            error = e.toString();
            _notifyChanged();
          },
        ),
      );
    }

    bind<bool>(player.stream.playing, (value) {
      playing = value;
      if (value) {
        playWhenReady = true;
        completed = false;
        error = null;
      }
    });
    bind<bool>(player.stream.completed, (value) {
      completed = value;
      if (value) {
        playing = false;
        playWhenReady = false;
      }
    });
    bind<bool>(player.stream.buffering, (value) => buffering = value);
    bind<Duration>(player.stream.position, (value) => position = value);
    bind<Duration>(player.stream.buffer, (value) => bufferedPosition = value);
    bind<Duration>(player.stream.duration, (value) {
      duration = value == Duration.zero ? null : value;
    });
    bind<media.Playlist>(player.stream.playlist, (value) {
      currentIndex = value.index.clamp(0, items.isEmpty ? 0 : items.length - 1);
    });
    bind<String>(player.stream.error, (value) {
      error = value;
      playing = false;
      playWhenReady = false;
      opening = false;
      debugPrint('DartPlaybackSession media_kit error: $value');
    });
  }

  final String sessionId;
  final VoidCallback onChanged;
  final media.Player player = media.Player();
  final List<StreamSubscription<dynamic>> subscriptions = [];
  List<_DartPlaybackItem> items = const <_DartPlaybackItem>[];
  int currentIndex = 0;
  double volume = 1.0;
  double speed = 1.0;
  AudioEffectsState audioEffects = AudioEffectsState.flat;
  bool channelSwapEnabled = false;
  bool playing = false;
  bool playWhenReady = false;
  bool buffering = false;
  bool completed = false;
  bool opening = false;
  bool suppressPlaybackEvents = false;
  Duration position = Duration.zero;
  Duration bufferedPosition = Duration.zero;
  Duration? duration;
  String? error;
  Duration? _pendingSeekPosition;

  Future<void> setVolume(double nextVolume, {bool reloadSource = true}) async {
    volume = _normalizeSessionVolume(nextVolume);
    await player.setVolume(volume * 100);
  }

  Future<void> setSpeed(double nextSpeed) async {
    speed = _normalizeSessionSpeed(nextSpeed);
    await player.setRate(speed);
  }

  _DartPlaybackItem? get currentItem {
    if (items.isEmpty) return null;
    return items[currentIndex.clamp(0, items.length - 1)];
  }

  String get processingState {
    if (error != null) return 'idle';
    if (opening) return 'loading';
    if (completed) return 'completed';
    if (buffering) return 'buffering';
    if (items.isEmpty) return 'idle';
    return 'ready';
  }

  Future<void> setItems(
    List<_DartPlaybackItem> nextItems, {
    required int initialIndex,
    required Duration initialPosition,
  }) async {
    items = List.of(nextItems);
    if (items.isEmpty) {
      await stop();
      return;
    }

    opening = true;
    completed = false;
    error = null;
    currentIndex = initialIndex.clamp(0, items.length - 1);
    onChanged();

    try {
      await player.open(
        media.Playlist(
          items.map(_mediaFor).toList(growable: false),
          index: currentIndex,
        ),
        play: false,
      );
      await player.setVolume(volume * 100);
      await player.setRate(speed);
      await _applyManagedAudioFilters();
      if (initialPosition > Duration.zero) {
        _pendingSeekPosition = initialPosition;
        await player.seek(initialPosition);
      }
      position = initialPosition;
    } finally {
      opening = false;
      onChanged();
    }
  }

  Future<void> setChannelSwapEnabled(bool enabled) async {
    if (channelSwapEnabled == enabled) return;
    await setAudioEffects(
      NativeAudioEffects(state: audioEffects, channelSwapEnabled: enabled),
    );
  }

  Future<void> setAudioEffects(NativeAudioEffects effects) async {
    final previous = channelSwapEnabled;
    final previousEffects = audioEffects;
    final previousPlaying = playing;
    final previousPlayWhenReady = playWhenReady;
    final previousBuffering = buffering;
    final previousCompleted = completed;
    final previousOpening = opening;
    final previousPosition = position;
    final previousBufferedPosition = bufferedPosition;
    final previousDuration = duration;
    final previousError = error;

    void restorePlaybackState() {
      playing = previousPlaying;
      playWhenReady = previousPlayWhenReady;
      buffering = previousBuffering;
      completed = previousCompleted;
      opening = previousOpening;
      position = previousPosition;
      bufferedPosition = previousBufferedPosition;
      duration = previousDuration;
      error = previousError;
    }

    audioEffects = effects.state;
    channelSwapEnabled = effects.channelSwapEnabled;
    suppressPlaybackEvents = true;
    try {
      await _applyManagedAudioFilters();
      restorePlaybackState();
    } catch (_) {
      channelSwapEnabled = previous;
      audioEffects = previousEffects;
      await _applyManagedAudioFilters();
      restorePlaybackState();
      rethrow;
    } finally {
      scheduleMicrotask(() {
        suppressPlaybackEvents = false;
      });
    }
  }

  void _notifyChanged() {
    onChanged();
  }

  Future<void> setPlaybackMode({
    required bool repeatOne,
    required bool repeatAll,
    required bool shuffle,
  }) async {
    await player.setPlaylistMode(
      repeatOne
          ? media.PlaylistMode.single
          : repeatAll
          ? media.PlaylistMode.loop
          : media.PlaylistMode.none,
    );
    await player.setShuffle(shuffle);
  }

  Future<void> play() async {
    playWhenReady = true;
    completed = false;
    error = null;
    onChanged();
    if (_pendingSeekPosition != null) {
      final pos = _pendingSeekPosition!;
      _pendingSeekPosition = null;
      await player.seek(pos);
    }
    await player.play();
  }

  Future<void> pause() async {
    playWhenReady = false;
    await player.pause();
    playing = false;
    onChanged();
  }

  Future<void> stop() async {
    playWhenReady = false;
    playing = false;
    buffering = false;
    completed = false;
    opening = false;
    _pendingSeekPosition = null;
    position = Duration.zero;
    bufferedPosition = Duration.zero;
    duration = null;
    items = const <_DartPlaybackItem>[];
    currentIndex = 0;
    await player.stop();
    onChanged();
  }

  Future<void> seek(Duration nextPosition) async {
    _pendingSeekPosition = null;
    final shouldResume = playWhenReady || playing;
    completed = false;
    position = nextPosition;
    onChanged();
    await player.seek(nextPosition);
    if (shouldResume) {
      playWhenReady = true;
      await player.play();
    }
  }

  media.Media _mediaFor(_DartPlaybackItem item) {
    final itemPath = item.path;
    if (itemPath == null || PathMatcher.isRemoteUri(itemPath)) {
      return media.Media(item.uri.toString());
    }
    return media.Media(itemPath);
  }

  Future<void> _applyManagedAudioFilters() async {
    final platform = player.platform;
    if (platform is media.NativePlayer) {
      for (final label in _managedAudioFilterLabels) {
        await platform.command(['af', 'remove', label]);
      }
      final filters = _buildDartPlaybackAudioFilters(
        audioEffects,
        channelSwapEnabled: channelSwapEnabled,
      );
      for (final filter in filters) {
        await platform.command(['af', 'add', filter.value]);
      }
      final appliedFilters = (await platform.getProperty('af')).toString();
      final missingLabels = filters.where(
        (filter) => !appliedFilters.contains(filter.label),
      );
      if (missingLabels.isNotEmpty) {
        throw StateError(
          'Failed to apply Windows audio filters: ${missingLabels.map((filter) => filter.label).join(', ')}',
        );
      }
    }
  }

  Future<void> dispose() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await player.dispose();
  }
}

double _normalizeSessionVolume(double volume) {
  return volume.clamp(0.0, 2.0);
}

double _normalizeSessionSpeed(double speed) {
  return speed.clamp(0.5, 2.0);
}

double _boostGainFor(double volume) {
  return _normalizeSessionVolume(volume).clamp(1.0, 2.0);
}

List<_DartPlaybackAudioFilter> _buildDartPlaybackAudioFilters(
  AudioEffectsState effects, {
  required bool channelSwapEnabled,
}) {
  final filters = <_DartPlaybackAudioFilter>[];
  if (effects.skipSilenceEnabled) {
    filters.add(
      const _DartPlaybackAudioFilter(
        label: _skipSilenceAudioFilterLabel,
        value: _windowsSkipSilenceFilter,
      ),
    );
  }
  if (effects.noiseReductionEnabled) {
    filters.add(
      const _DartPlaybackAudioFilter(
        label: _noiseReductionAudioFilterLabel,
        value: _windowsNoiseReductionFilter,
      ),
    );
  }
  if (effects.volumeNormalizationEnabled) {
    filters.add(
      const _DartPlaybackAudioFilter(
        label: _volumeNormalizationAudioFilterLabel,
        value: _windowsVolumeNormalizationFilter,
      ),
    );
  }
  final eqFilter = _buildEqualizerFilter(effects);
  if (eqFilter != null) filters.add(eqFilter);
  final panningFilter = _buildPanningFilter(effects.panning);
  if (panningFilter != null) filters.add(panningFilter);
  if (channelSwapEnabled) {
    filters.add(
      const _DartPlaybackAudioFilter(
        label: _channelSwapAudioFilterLabel,
        value: '$_channelSwapAudioFilterLabel:lavfi=[pan=stereo|c0=c1|c1=c0]',
      ),
    );
  }
  return filters;
}

_DartPlaybackAudioFilter? _buildPanningFilter(double panning) {
  final value = panning.clamp(-1.0, 1.0);
  if (value.abs() < 0.001) return null;
  final leftGain = value > 0 ? 1 - value : 1.0;
  final rightGain = value < 0 ? 1 + value : 1.0;
  return _DartPlaybackAudioFilter(
    label: _panningAudioFilterLabel,
    value:
        '$_panningAudioFilterLabel:lavfi=[pan=stereo|c0=${_formatFilterNumber(leftGain)}*c0|c1=${_formatFilterNumber(rightGain)}*c1]',
  );
}

_DartPlaybackAudioFilter? _buildEqualizerFilter(AudioEffectsState effects) {
  if (!effects.eqEnabled || effects.eqBandLevels.isEmpty) return null;
  final bands = <int, double>{};
  for (final entry in effects.eqBandLevels.entries) {
    if (!_windowsEqBandFrequencies.contains(entry.key)) continue;
    final gain = entry.value.clamp(
      dartPlaybackWindowsEqCapabilities.minGainDb,
      dartPlaybackWindowsEqCapabilities.maxGainDb,
    );
    if (gain.abs() < 0.05) continue;
    bands[entry.key] = gain;
  }
  if (bands.isEmpty) return null;
  final graph = bands.entries
      .map((entry) {
        return 'equalizer=f=${entry.key}:t=q:w=1:g=${_formatFilterNumber(entry.value)}';
      })
      .join(',');
  return _DartPlaybackAudioFilter(
    label: _equalizerAudioFilterLabel,
    value: '$_equalizerAudioFilterLabel:lavfi=[$graph]',
  );
}

String _formatFilterNumber(double value) {
  final fixed = value.toStringAsFixed(3);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class _DartPlaybackAudioFilter {
  const _DartPlaybackAudioFilter({required this.label, required this.value});

  final String label;
  final String value;
}

class _DartPlaybackItem {
  const _DartPlaybackItem({
    required this.uri,
    this.path,
    this.title,
    this.subtitle,
    this.artUri,
  });

  final Uri uri;
  final String? path;
  final String? title;
  final String? subtitle;
  final String? artUri;
}

String? _pathFromUri(Uri uri) {
  if (uri.scheme == 'file') {
    return uri.toFilePath(windows: isWindowsDriveFileUri(uri));
  }
  if (PathMatcher.isRemoteUri(uri.toString())) return uri.toString();
  return null;
}
