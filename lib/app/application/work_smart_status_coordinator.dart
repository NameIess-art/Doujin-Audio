import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../../core/logging/app_log_service.dart';
import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/media/path_matcher.dart';
import '../../features/asmr/application/asmr_library_controller.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/library/application/audio_detail_cache_service.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/listening_activity_service.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_session.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/domain/listening_activity.dart';
import '../../features/player/domain/playback_mode.dart'
    show ProcessingState, SessionLoopMode;
import 'runtime_binding.dart';

typedef WorkMainlineCoverage = ({
  Duration mainlineDuration,
  int completedLogicalTracks,
  int totalLogicalTracks,
  double coverageRatio,
  DateTime? latestPlayedAt,
});

/// Collapses dual-version subfolders (e.g. SEあり/SEなし, WAV/MP3) by normalized
/// track stem so finishing one version counts as 100% mainline coverage.
WorkMainlineCoverage computeWorkMainlineCoverage(
  Iterable<MusicTrack> tracks, {
  Set<String> completedTrackKeys = const <String>{},
}) {
  final allTracks = tracks.toList(growable: false);
  if (allTracks.isEmpty) {
    return (
      mainlineDuration: Duration.zero,
      completedLogicalTracks: 0,
      totalLogicalTracks: 0,
      coverageRatio: 0,
      latestPlayedAt: null,
    );
  }
  DateTime? latestPlayedAt;
  for (final track in allTracks) {
    final playedAt = track.lastPlayedAt;
    if (playedAt != null &&
        (latestPlayedAt == null || playedAt.isAfter(latestPlayedAt))) {
      latestPlayedAt = playedAt;
    }
  }
  final hasSubstantialTracks = allTracks.any(
    (track) => track.duration >= const Duration(seconds: 15),
  );
  final candidates = hasSubstantialTracks
      ? allTracks
            .where(
              (track) =>
                  track.duration == Duration.zero ||
                  track.duration >= const Duration(seconds: 15),
            )
            .toList(growable: false)
      : allTracks;

  final groups = <String, ({Duration duration, bool completed})>{};
  for (var i = 0; i < candidates.length; i++) {
    final track = candidates[i];
    final stem = _normalizeVariantTrackStem(track, fallbackIndex: i);
    final trackDone =
        completedTrackKeys.contains(PathMatcher.equivalenceKey(track.path)) ||
        (track.duration > Duration.zero &&
            track.lastPlayedPosition.inMilliseconds >=
                (track.duration.inMilliseconds * 0.85).round());
    final prev = groups[stem];
    if (prev == null) {
      groups[stem] = (duration: track.duration, completed: trackDone);
    } else {
      groups[stem] = (
        duration: track.duration > prev.duration
            ? track.duration
            : prev.duration,
        completed: prev.completed || trackDone,
      );
    }
  }

  var mainlineMs = 0;
  var completedCount = 0;
  for (final group in groups.values) {
    mainlineMs += group.duration.inMilliseconds;
    if (group.completed) completedCount++;
  }
  final totalCount = groups.length;
  return (
    mainlineDuration: Duration(milliseconds: mainlineMs),
    completedLogicalTracks: completedCount,
    totalLogicalTracks: totalCount,
    coverageRatio: totalCount == 0 ? 0 : completedCount / totalCount,
    latestPlayedAt: latestPlayedAt,
  );
}

final RegExp _variantTokenPattern = RegExp(
  r'[\(\[（【｛<《]?\s*(?:se\s*(?:あり|なし|有り|無し|付|無|on|off)|'
  r'効果音\s*(?:あり|なし|有り|無し)|有音效|无音效|無音效|バイノーラル|'
  r'wav|mp3|flac|m4a|aac|ogg|opus)\s*[\)\]）】｝>》]?',
  caseSensitive: false,
);
final RegExp _separatorCollapsePattern = RegExp(r'[\s_\-・〜~]+');

String _normalizeVariantTrackStem(
  MusicTrack track, {
  required int fallbackIndex,
}) {
  final rawFile = PathDisplay.fileName(track.path, withoutExtension: true);
  final raw = rawFile.trim().isNotEmpty ? rawFile : track.displayName;
  final stripped = raw
      .toLowerCase()
      .replaceAll(_variantTokenPattern, ' ')
      .replaceAll(_separatorCollapsePattern, ' ')
      .trim();
  return stripped.isEmpty ? 'track_$fallbackIndex' : stripped;
}

final class WorkAutoListenedPrompt {
  const WorkAutoListenedPrompt({
    required this.statusKey,
    required this.workTitle,
    required this.previousStatus,
    required this.userRating,
    required this.reviewText,
    required this.syncsWithCloud,
    required this.onUndo,
    required this.onSaveReview,
  });

  final String statusKey;
  final String workTitle;
  final WorkListenStatus? previousStatus;
  final int? userRating;
  final String reviewText;
  final bool syncsWithCloud;
  final Future<void> Function() onUndo;
  final Future<void> Function({
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
  }) onSaveReview;
}

final class _WorkSmartRecord {
  _WorkSmartRecord({
    this.lastKnownStatus,
    this.suppressAutoListening = false,
    this.suppressAutoListened = false,
    this.baselineMs = 0,
    this.listenedAtMs,
    this.listenedBaselineMs = 0,
  });

  factory _WorkSmartRecord.fromJson(Map<String, Object?> map) {
    final rawStatus = map['status'];
    return _WorkSmartRecord(
      lastKnownStatus: rawStatus is String
          ? WorkListenStatus.tryFromWireValue(rawStatus)
          : null,
      suppressAutoListening: map['suppressListening'] == true,
      suppressAutoListened: map['suppressListened'] == true,
      baselineMs: (map['baselineMs'] as num?)?.toInt() ?? 0,
      listenedAtMs: (map['listenedAtMs'] as num?)?.toInt(),
      listenedBaselineMs: (map['listenedBaselineMs'] as num?)?.toInt() ?? 0,
    );
  }

  WorkListenStatus? lastKnownStatus;
  bool suppressAutoListening;
  bool suppressAutoListened;
  int baselineMs;
  int? listenedAtMs;
  int listenedBaselineMs;

  Map<String, Object?> toJson() => <String, Object?>{
    if (lastKnownStatus != null) 'status': lastKnownStatus!.wireValue,
    if (suppressAutoListening) 'suppressListening': true,
    if (suppressAutoListened) 'suppressListened': true,
    if (baselineMs > 0) 'baselineMs': baselineMs,
    if (listenedAtMs != null) 'listenedAtMs': listenedAtMs,
    if (listenedBaselineMs > 0) 'listenedBaselineMs': listenedBaselineMs,
  };
}

/// Hybrid smart listening status coordinator (Scheme C):
/// - Silently advances `null / marked` (and resumed `postponed`) -> `listening`
///   after real audible playback crosses the preview threshold.
/// - Advances `null / marked / listening` -> `listened` on natural queue end or
///   >= 80% logical mainline coverage (excluding sleep-timer stops), emitting
///   an undoable prompt with a quick rating entry point.
/// - Silently advances `listened` -> `replay` after a 3-day cooldown + fresh
///   audible re-listening.
/// - Archives stale `listening` works to `postponed` during the startup sweep.
final class WorkSmartStatusCoordinator implements RuntimeBinding {
  WorkSmartStatusCoordinator({
    required LibraryFacade library,
    required AsmrLibraryController asmrLibrary,
    required ListeningActivityService listeningActivity,
    required PlaybackFacade playback,
    required TimerFacade timer,
    Future<String?> Function()? readPersistedState,
    Future<void> Function(String json)? writePersistedState,
    Future<Set<String>> Function(Iterable<String>, DateTime)?
    loadRecentlyPlayedWorkKeys,
    DateTime Function()? now,
  }) : _library = library,
       _asmrLibrary = asmrLibrary,
       _listeningActivity = listeningActivity,
       _playback = playback,
       _timer = timer,
       _readPersistedState = readPersistedState,
       _writePersistedState = writePersistedState,
       _loadRecentlyPlayedWorkKeys = loadRecentlyPlayedWorkKeys,
       _now = now ?? DateTime.now {
    _usageSubscription = _listeningActivity.workUsageUpdates.listen(
      _handleWorkUsageBatch,
    );
    _playbackSubscription = _playback.states.listen((_) {
      _observePlaybackSessions();
    });
    _detailSubscription = _library.detailCacheService.changes.listen(
      _handleLocalDetailChanged,
    );
    _asmrLibrary.addListener(_handleAsmrChanged);
  }

  static const String persistedSettingKey = 'smart_listen_status_state_v1';
  static const Duration previewThresholdCap = Duration(minutes: 3);
  static const Duration previewThresholdFloor = Duration(seconds: 30);
  static const Duration replayCooldown = Duration(days: 3);
  static const Duration replayThresholdCap = Duration(minutes: 5);
  static const Duration replayThresholdFloor = Duration(seconds: 45);
  static const Duration stalePostponeAfter = Duration(days: 15);

  final LibraryFacade _library;
  final AsmrLibraryController _asmrLibrary;
  final ListeningActivityService _listeningActivity;
  final PlaybackFacade _playback;
  final TimerFacade _timer;
  final Future<String?> Function()? _readPersistedState;
  final Future<void> Function(String json)? _writePersistedState;
  final Future<Set<String>> Function(Iterable<String>, DateTime)?
  _loadRecentlyPlayedWorkKeys;
  final DateTime Function() _now;

  late final StreamSubscription<List<ListeningWorkUsageUpdate>>
  _usageSubscription;
  late final StreamSubscription<Object?> _playbackSubscription;
  late final StreamSubscription<AudioDetailCacheChange> _detailSubscription;

  final _autoListenedPrompts =
      StreamController<WorkAutoListenedPrompt>.broadcast();
  Stream<WorkAutoListenedPrompt> get autoListenedPrompts =>
      _autoListenedPrompts.stream;

  final Map<String, _WorkSmartRecord> _records = <String, _WorkSmartRecord>{};
  final Set<String> _applyingAutoStatusKeys = <String>{};
  final Set<String> _naturalCompletedWorkKeys = <String>{};
  final Set<String> _completedTrackKeys = <String>{};
  final Map<String, ProcessingState> _lastSessionProcessing =
      <String, ProcessingState>{};
  List<AsmrWork> _lastAsmrReviewed = const <AsmrWork>[];
  bool _stateLoaded = false;
  bool _disposed = false;
  Future<void> _serialTail = Future<void>.value();

  Future<void> initializeAndSweepStale() => _enqueue(() async {
    await _ensureStateLoaded();
    await _sweepStaleListeningWorks();
  });

  void _observePlaybackSessions() {
    if (_disposed) return;
    final pausedByTimer = _timer.state.pausedByTimerSessionIds.toSet();
    final activeIds = <String>{};
    for (final session in _playback.sessions.values) {
      activeIds.add(session.id);
      final prev = _lastSessionProcessing[session.id];
      final current = session.state.processingState;
      _lastSessionProcessing[session.id] = current;
      if (prev == ProcessingState.completed ||
          current != ProcessingState.completed) {
        continue;
      }
      final stoppedBySleepTimer =
          session.completedByTrackStop ||
          pausedByTimer.contains(session.id) ||
          _timer.state.stopAfterCurrentTrack;
      if (stoppedBySleepTimer ||
          session.loopMode == SessionLoopMode.single ||
          session.isAdvancingAfterCompletion ||
          session.playbackError != null) {
        continue;
      }
      final track = _resolveSessionCurrentTrack(session);
      if (track == null) continue;
      _completedTrackKeys.add(PathMatcher.equivalenceKey(track.path));
      final workKey = listeningWorkKey(track);
      _naturalCompletedWorkKeys.add(workKey);
      _listeningActivity.schedulePlaybackRefresh();
      _enqueue(() async {
        await _ensureStateLoaded();
        final totals = await _listeningActivity.loadWorkTotalMilliseconds([
          workKey,
        ]);
        await _evaluateTrackWork(
          workKey: workKey,
          track: track,
          totalMs: totals[workKey] ?? 0,
          stoppedBySleepTimer: false,
        );
      });
    }
    _lastSessionProcessing.removeWhere((id, _) => !activeIds.contains(id));
  }

  MusicTrack? _resolveSessionCurrentTrack(PlaybackSession session) {
    final path = session.currentTrackPath;
    if (path.isEmpty) return null;
    return session.trackForPath(path) ?? _library.trackByPath(path);
  }

  void _handleWorkUsageBatch(List<ListeningWorkUsageUpdate> updates) {
    if (_disposed || updates.isEmpty) return;
    final pausedByTimer = _timer.state.pausedByTimerSessionIds;
    final sleepTimerTriggered = pausedByTimer.isNotEmpty;
    _enqueue(() async {
      await _ensureStateLoaded();
      for (final update in updates) {
        if (_disposed) return;
        await _evaluateTrackWork(
          workKey: update.workKey,
          track: update.track,
          totalMs: update.totalMilliseconds,
          stoppedBySleepTimer: sleepTimerTriggered,
        );
      }
    });
  }

  void _handleLocalDetailChanged(AudioDetailCacheChange change) {
    if (_disposed) return;
    final keys = change.targetKeys;
    if (keys == null || keys.isEmpty) return;
    _enqueue(() async {
      await _ensureStateLoaded();
      var dirty = false;
      for (final key in keys) {
        final detail = _library.detailCacheService.resolvedDetailByKey(key);
        if (detail == null) continue;
        final statusKey = _statusKeyForLocal(detail.target, detail);
        if (_applyingAutoStatusKeys.contains(statusKey)) continue;
        final workKey = _listeningKeyForLocal(detail.target, detail);
        final totals = await _listeningActivity.loadWorkTotalMilliseconds([
          workKey,
        ]);
        if (_recordExternalStatusChange(
          statusKey: statusKey,
          nextStatus: detail.listenStatus,
          currentTotalMs: totals[workKey] ?? 0,
        )) {
          dirty = true;
        }
      }
      if (dirty) await _persistState();
    });
  }

  void _handleAsmrChanged() {
    if (_disposed || !_asmrLibrary.initialized) return;
    final current = _asmrLibrary.reviewedWorks;
    if (identical(current, _lastAsmrReviewed)) return;
    final previous = _lastAsmrReviewed;
    _lastAsmrReviewed = current;
    _enqueue(() async {
      await _ensureStateLoaded();
      final byKey = <String, AsmrWork>{
        for (final work in current) work.workKey: work,
      };
      final candidateWorks = <String, AsmrWork?>{
        for (final work in current) work.workKey: work,
        for (final old in previous)
          if (!byKey.containsKey(old.workKey)) old.workKey: null,
      };
      var dirty = false;
      for (final entry in candidateWorks.entries) {
        final work =
            entry.value ??
            previous.firstWhere((item) => item.workKey == entry.key);
        final statusKey = _statusKeyForAsmr(work);
        if (_applyingAutoStatusKeys.contains(statusKey)) continue;
        final nextStatus = entry.value?.listenStatus;
        final existingRecord = _records[statusKey];
        if (existingRecord?.lastKnownStatus == nextStatus) continue;
        final workKey = work.rjCode.isNotEmpty
            ? 'rj:${work.rjCode.toUpperCase()}'
            : 'asmr:${work.id}';
        final totals = await _listeningActivity.loadWorkTotalMilliseconds([
          workKey,
        ]);
        if (_recordExternalStatusChange(
          statusKey: statusKey,
          nextStatus: nextStatus,
          currentTotalMs: totals[workKey] ?? 0,
        )) {
          dirty = true;
        }
      }
      if (dirty) await _persistState();
    });
  }

  bool _recordExternalStatusChange({
    required String statusKey,
    required WorkListenStatus? nextStatus,
    required int currentTotalMs,
  }) {
    final record = _records.putIfAbsent(statusKey, _WorkSmartRecord.new);
    final oldStatus = record.lastKnownStatus;
    if (oldStatus == nextStatus) return false;
    record.lastKnownStatus = nextStatus;

    switch (nextStatus) {
      case WorkListenStatus.marked:
        record.suppressAutoListening = false;
        record.suppressAutoListened = false;
        record.baselineMs = currentTotalMs >= previewThresholdCap.inMilliseconds
            ? currentTotalMs
            : 0;
      case WorkListenStatus.listening:
        record.suppressAutoListening = false;
        if (oldStatus == WorkListenStatus.listened ||
            oldStatus == WorkListenStatus.replay) {
          record.suppressAutoListened = true;
        }
      case WorkListenStatus.listened:
        record.suppressAutoListening = false;
        record.suppressAutoListened = false;
        record.listenedAtMs = _now().millisecondsSinceEpoch;
        record.listenedBaselineMs = currentTotalMs;
      case WorkListenStatus.replay:
        record.suppressAutoListening = true;
        record.suppressAutoListened = true;
      case WorkListenStatus.postponed:
        record.suppressAutoListening = false;
        record.suppressAutoListened = false;
        record.baselineMs = currentTotalMs;
      case null:
        if (oldStatus != null) {
          record.suppressAutoListening = true;
          record.suppressAutoListened = true;
        }
    }
    return true;
  }

  Future<void> _evaluateTrackWork({
    required String workKey,
    required MusicTrack track,
    required int totalMs,
    required bool stoppedBySleepTimer,
  }) async {
    if (track.isRemoteAsmr) {
      final work = _resolveRemoteAsmrWork(track);
      if (work == null) return;
      await _evaluateAsmrWork(
        workKey: workKey,
        work: work,
        totalMs: totalMs,
        stoppedBySleepTimer: stoppedBySleepTimer,
      );
      return;
    }

    if (track.path.startsWith('http://') || track.path.startsWith('https://')) {
      return;
    }

    final target = _library.audioDetailTargetForTrack(track);
    final detail =
        _library.resolvedAudioDetail(target) ??
        (await _library.loadAudioDetail(target)).detail;
    final tracks = _tracksForTarget(target);
    final coverage = computeWorkMainlineCoverage(
      tracks,
      completedTrackKeys: _completedTrackKeys,
    );
    final effectiveDuration = coverage.mainlineDuration > Duration.zero
        ? coverage.mainlineDuration
        : (detail.duration ?? track.duration);
    final statusKey = _statusKeyForLocal(target, detail);
    final workTitle = detail.workTitle.trim().isNotEmpty
        ? detail.workTitle.trim()
        : (target.isLibraryRootFolder
              ? PathDisplay.folderName(target.targetPath)
              : PathDisplay.fileName(target.targetPath, withoutExtension: true));
    final syncsWithCloud =
        _asmrLibrary.isAsmrAccountLoggedIn &&
        AudioDetail.findRjCodeInText(detail.rjCode) != null;

    await _evaluateTransition(
      statusKey: statusKey,
      workKey: workKey,
      workTitle: workTitle,
      currentStatus: detail.listenStatus,
      reviewUpdatedAt: detail.reviewUpdatedAt,
      userRating: detail.userRating,
      reviewText: detail.reviewText,
      effectiveDuration: effectiveDuration,
      coverage: coverage,
      totalMs: totalMs,
      stoppedBySleepTimer: stoppedBySleepTimer,
      syncsWithCloud: syncsWithCloud,
      applyStatus: (nextStatus, rating, note) => _applyLocalAutoStatus(
        statusKey: statusKey,
        target: target,
        listenStatus: nextStatus,
        userRating: rating,
        reviewText: note,
      ),
      applyManualReview: ({
        required listenStatus,
        required userRating,
        required reviewText,
      }) => _library.saveAudioUserReview(
        target,
        listenStatus: listenStatus,
        userRating: userRating,
        reviewText: reviewText,
      ),
    );
  }

  Future<void> _evaluateAsmrWork({
    required String workKey,
    required AsmrWork work,
    required int totalMs,
    required bool stoppedBySleepTimer,
  }) async {
    await _asmrLibrary.initializeForVisiblePage();
    final reviewed = _asmrLibrary.reviewForWork(work);
    final effectiveWork = reviewed == null ? work : work.mergedWith(reviewed);
    final statusKey = _statusKeyForAsmr(effectiveWork);
    final coverage = (
      mainlineDuration: effectiveWork.duration,
      completedLogicalTracks: 0,
      totalLogicalTracks: 0,
      coverageRatio: 0.0,
      latestPlayedAt: null,
    );

    await _evaluateTransition(
      statusKey: statusKey,
      workKey: workKey,
      workTitle: effectiveWork.title.trim().isNotEmpty
          ? effectiveWork.title.trim()
          : effectiveWork.workCode,
      currentStatus: effectiveWork.listenStatus,
      reviewUpdatedAt: effectiveWork.reviewUpdatedAt,
      userRating: effectiveWork.userRating,
      reviewText: effectiveWork.reviewText,
      effectiveDuration: effectiveWork.duration,
      coverage: coverage,
      totalMs: totalMs,
      stoppedBySleepTimer: stoppedBySleepTimer,
      syncsWithCloud:
          _asmrLibrary.isAsmrAccountLoggedIn &&
          effectiveWork.resourceFor(AsmrCatalogSource.asmrOne) != null,
      applyStatus: (nextStatus, rating, note) => _applyAsmrAutoStatus(
        statusKey: statusKey,
        work: effectiveWork,
        listenStatus: nextStatus,
        userRating: rating,
        reviewText: note,
      ),
      applyManualReview: ({
        required listenStatus,
        required userRating,
        required reviewText,
      }) => _asmrLibrary.saveWorkReview(
        effectiveWork,
        listenStatus: listenStatus,
        userRating: userRating,
        reviewText: reviewText,
      ),
    );
  }

  Future<void> _evaluateTransition({
    required String statusKey,
    required String workKey,
    required String workTitle,
    required WorkListenStatus? currentStatus,
    required DateTime? reviewUpdatedAt,
    required int? userRating,
    required String reviewText,
    required Duration effectiveDuration,
    required WorkMainlineCoverage coverage,
    required int totalMs,
    required bool stoppedBySleepTimer,
    required bool syncsWithCloud,
    required Future<void> Function(
      WorkListenStatus? nextStatus,
      int? rating,
      String note,
    )
    applyStatus,
    required Future<void> Function({
      required WorkListenStatus? listenStatus,
      required int? userRating,
      required String reviewText,
    })
    applyManualReview,
  }) async {
    final record = _records.putIfAbsent(statusKey, _WorkSmartRecord.new);
    record.lastKnownStatus ??= currentStatus;
    final now = _now();

    if (currentStatus == WorkListenStatus.replay) {
      return;
    }

    // Rule 3: `listened` -> `replay` after cooldown + fresh re-listening.
    if (currentStatus == WorkListenStatus.listened) {
      final listenedAtMs =
          record.listenedAtMs ?? reviewUpdatedAt?.millisecondsSinceEpoch;
      if (listenedAtMs == null) {
        record.listenedAtMs = now.millisecondsSinceEpoch;
        record.listenedBaselineMs = totalMs;
        await _persistState();
        return;
      }
      final elapsed = now.difference(
        DateTime.fromMillisecondsSinceEpoch(listenedAtMs),
      );
      if (elapsed < replayCooldown) return;
      final replayDeltaMs = math.max(0, totalMs - record.listenedBaselineMs);
      final replayThresholdMs = _replayThresholdMs(effectiveDuration);
      if (replayDeltaMs >= replayThresholdMs) {
        record.lastKnownStatus = WorkListenStatus.replay;
        await applyStatus(WorkListenStatus.replay, userRating, reviewText);
        await _persistState();
      }
      return;
    }

    final deltaMs = math.max(0, totalMs - record.baselineMs);

    // Rule 2: `null / marked / listening` -> `listened` (with undo & rate toast).
    if (currentStatus != WorkListenStatus.postponed &&
        !record.suppressAutoListened &&
        !stoppedBySleepTimer) {
      final naturalCompleted = _naturalCompletedWorkKeys.remove(workKey);
      final minCompletionAudibleMs = _minCompletionAudibleMs(effectiveDuration);
      final reachedByQueueEnd =
          naturalCompleted && deltaMs >= minCompletionAudibleMs;
      final reachedByCoverage =
          coverage.totalLogicalTracks > 0 &&
          coverage.coverageRatio >= 0.80 &&
          deltaMs >=
              math.max(
                previewThresholdFloor.inMilliseconds,
                (effectiveDuration.inMilliseconds * 0.40).round(),
              );
      final reachedByDuration =
          effectiveDuration >= const Duration(minutes: 1) &&
          deltaMs >= (effectiveDuration.inMilliseconds * 0.85).round();

      if (reachedByQueueEnd || reachedByCoverage || reachedByDuration) {
        final previousStatus = currentStatus;
        record.lastKnownStatus = WorkListenStatus.listened;
        record.listenedAtMs = now.millisecondsSinceEpoch;
        record.listenedBaselineMs = totalMs;
        await applyStatus(WorkListenStatus.listened, userRating, reviewText);
        await _persistState();
        if (!_disposed) {
          _autoListenedPrompts.add(
            WorkAutoListenedPrompt(
              statusKey: statusKey,
              workTitle: workTitle,
              previousStatus: previousStatus,
              userRating: userRating,
              reviewText: reviewText,
              syncsWithCloud: syncsWithCloud,
              onUndo: () => _enqueue(() async {
                record.lastKnownStatus = previousStatus;
                record.suppressAutoListened = true;
                record.listenedAtMs = null;
                await applyStatus(previousStatus, userRating, reviewText);
                await _persistState();
              }),
              onSaveReview: ({
                required listenStatus,
                required userRating,
                required reviewText,
              }) async {
                await applyManualReview(
                  listenStatus: listenStatus,
                  userRating: userRating,
                  reviewText: reviewText,
                );
              },
            ),
          );
        }
        return;
      }
    }

    // Rule 1: `null / marked` (or actively resumed `postponed`) -> `listening`.
    if ((currentStatus == null ||
            currentStatus == WorkListenStatus.marked ||
            currentStatus == WorkListenStatus.postponed) &&
        !record.suppressAutoListening) {
      final thresholdMs = _listeningThresholdMs(effectiveDuration);
      if (deltaMs >= thresholdMs) {
        record.lastKnownStatus = WorkListenStatus.listening;
        await applyStatus(WorkListenStatus.listening, userRating, reviewText);
        await _persistState();
      }
    }
  }

  Future<void> _sweepStaleListeningWorks() async {
    final now = _now();
    var dirty = false;

    if (_library.library.isNotEmpty) {
      final snapshot = await _library.audioLibraryCategorySnapshot(
        isActive: () => !_disposed,
      );
      if (_disposed) return;
      for (final entry in snapshot.entries) {
        if (_disposed) return;
        final detail = entry.detail;
        if (detail.listenStatus != WorkListenStatus.listening) continue;
        final coverage = computeWorkMainlineCoverage(entry.tracks);
        final lastActive = _latestDate(
          coverage.latestPlayedAt,
          detail.reviewUpdatedAt,
        );
        if (lastActive == null ||
            now.difference(lastActive) < stalePostponeAfter) {
          continue;
        }
        final statusKey = _statusKeyForLocal(entry.target, detail);
        final workKey = _listeningKeyForLocal(entry.target, detail);
        final totals = await _listeningActivity.loadWorkTotalMilliseconds([
          workKey,
        ]);
        final record = _records.putIfAbsent(statusKey, _WorkSmartRecord.new);
        record.lastKnownStatus = WorkListenStatus.postponed;
        record.baselineMs = totals[workKey] ?? 0;
        await _applyLocalAutoStatus(
          statusKey: statusKey,
          target: entry.target,
          listenStatus: WorkListenStatus.postponed,
          userRating: detail.userRating,
          reviewText: detail.reviewText,
        );
        dirty = true;
      }
    }

    if (_asmrLibrary.initialized) {
      final stale = <String, AsmrWork>{};
      for (final work in _asmrLibrary.reviewedWorks) {
        if (_disposed) return;
        if (work.listenStatus != WorkListenStatus.listening) continue;
        final lastActive = work.reviewUpdatedAt;
        if (lastActive == null ||
            now.difference(lastActive) < stalePostponeAfter) {
          continue;
        }
        final workKey = work.rjCode.isNotEmpty
            ? 'rj:${work.rjCode.toUpperCase()}'
            : 'asmr:${work.id}';
        stale[workKey] = work;
      }
      final recent = stale.isEmpty
          ? const <String>{}
          : await _loadRecentlyPlayedWorkKeys?.call(
                  stale.keys,
                  now.subtract(stalePostponeAfter),
                ) ??
                const <String>{};
      final workKeys = stale.keys
          .where((key) => !recent.contains(key))
          .toList();
      final totals = workKeys.isEmpty
          ? const <String, int>{}
          : await _listeningActivity.loadWorkTotalMilliseconds(workKeys);
      for (final workKey in workKeys) {
        if (_disposed) return;
        final work = stale[workKey]!;
        final statusKey = _statusKeyForAsmr(work);
        final record = _records.putIfAbsent(statusKey, _WorkSmartRecord.new);
        record.lastKnownStatus = WorkListenStatus.postponed;
        record.baselineMs = totals[workKey] ?? 0;
        await _applyAsmrAutoStatus(
          statusKey: statusKey,
          work: work,
          listenStatus: WorkListenStatus.postponed,
          userRating: work.userRating,
          reviewText: work.reviewText,
        );
        dirty = true;
      }
    }

    if (dirty) await _persistState();
  }

  Future<void> _applyLocalAutoStatus({
    required String statusKey,
    required AudioDetailTarget target,
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
  }) async {
    _applyingAutoStatusKeys.add(statusKey);
    try {
      await _library.saveAudioUserReview(
        target,
        listenStatus: listenStatus,
        userRating: userRating,
        reviewText: reviewText,
        updatedAt: _now().toUtc(),
      );
    } finally {
      _applyingAutoStatusKeys.remove(statusKey);
    }
  }

  Future<void> _applyAsmrAutoStatus({
    required String statusKey,
    required AsmrWork work,
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
  }) async {
    _applyingAutoStatusKeys.add(statusKey);
    try {
      await _asmrLibrary.saveWorkReview(
        work,
        listenStatus: listenStatus,
        userRating: userRating,
        reviewText: reviewText,
        updatedAt: _now().toUtc(),
      );
      _lastAsmrReviewed = _asmrLibrary.reviewedWorks;
    } finally {
      _applyingAutoStatusKeys.remove(statusKey);
    }
  }

  List<MusicTrack> _tracksForTarget(AudioDetailTarget target) {
    if (!target.isLibraryRootFolder) {
      final single = _library.trackByPath(target.targetPath);
      return single == null ? const <MusicTrack>[] : <MusicTrack>[single];
    }
    final root = target.targetPath;
    return [
      for (final key in _library.activeGroupKeys)
        if (PathMatcher.isWithinOrEqual(key, root) ||
            PathMatcher.isWithinOrEqual(root, key))
          for (final track in _library.tracksInGroup(key))
            if (PathMatcher.isWithinOrEqual(track.path, root)) track,
    ];
  }

  AsmrWork? _resolveRemoteAsmrWork(MusicTrack track) {
    final rj = AudioDetail.findRjCodeInText(
      [
        track.remoteMetadata?['sourceId'],
        track.groupSubtitle,
        track.groupTitle,
      ].join(' '),
    );
    if (rj != null) {
      final existing = _asmrLibrary.reviewForRjCode(rj);
      if (existing != null) return existing;
    }
    final meta = track.remoteMetadata;
    if (meta != null && meta['id'] is int) {
      try {
        return AsmrWork.fromJson(meta);
      } catch (_) {}
    }
    final digits = rj == null ? 0 : (int.tryParse(rj.substring(2)) ?? 0);
    if (digits <= 0 && rj == null) return null;
    return AsmrWork(
      id: digits,
      title: track.groupTitle.trim().isNotEmpty
          ? track.groupTitle.trim()
          : track.displayName,
      circleName: track.remoteCircleName,
      sourceId: rj ?? '',
      sourceType: track.remoteMetadataKind == MusicTrack.remoteMetadataKindAsmrOne
          ? 'asmr-one'
          : 'DLSITE',
      sourceUrl: '',
      coverUrl: track.remoteCoverUrl ?? '',
      thumbnailUrl: track.remoteCoverUrl ?? '',
      mainCoverUrl: track.remoteCoverUrl ?? '',
      releaseDate: null,
      createDate: null,
      duration: track.duration,
      dlCount: 0,
      reviewCount: 0,
      rating: 0,
      voiceActors: const <String>[],
      tags: track.tags,
    );
  }

  static int _listeningThresholdMs(Duration effectiveDuration) {
    if (effectiveDuration <= Duration.zero) {
      return previewThresholdCap.inMilliseconds;
    }
    return math.min(
      previewThresholdCap.inMilliseconds,
      math.max(
        previewThresholdFloor.inMilliseconds,
        (effectiveDuration.inMilliseconds * 0.15).round(),
      ),
    );
  }

  static int _minCompletionAudibleMs(Duration effectiveDuration) {
    if (effectiveDuration <= Duration.zero) {
      return const Duration(seconds: 30).inMilliseconds;
    }
    return math.min(
      previewThresholdCap.inMilliseconds,
      math.max(
        const Duration(seconds: 20).inMilliseconds,
        (effectiveDuration.inMilliseconds * 0.30).round(),
      ),
    );
  }

  static int _replayThresholdMs(Duration effectiveDuration) {
    if (effectiveDuration <= Duration.zero) {
      return replayThresholdCap.inMilliseconds;
    }
    return math.min(
      replayThresholdCap.inMilliseconds,
      math.max(
        replayThresholdFloor.inMilliseconds,
        (effectiveDuration.inMilliseconds * 0.30).round(),
      ),
    );
  }

  static DateTime? _latestDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static String _statusKeyForLocal(
    AudioDetailTarget target,
    AudioDetail detail,
  ) {
    final rj = AudioDetail.findRjCodeInText(detail.rjCode);
    if (rj != null) {
      final normalized = normalizeAsmrWorkCode(rj);
      if (normalized.startsWith('RJ')) return 'rj:$normalized';
    }
    return 'local:${AudioLibraryDetailKey.forTarget(target)}';
  }

  static String _listeningKeyForLocal(
    AudioDetailTarget target,
    AudioDetail detail,
  ) {
    final rj = AudioDetail.findRjCodeInText(
      '${detail.rjCode} ${target.targetPath}',
    );
    if (rj != null) return 'rj:${rj.toUpperCase()}';
    return 'local:${target.targetPath.replaceAll('\\', '/').toLowerCase()}';
  }

  static String _statusKeyForAsmr(AsmrWork work) {
    if (work.rjCode.isNotEmpty) return 'rj:${work.rjCode.toUpperCase()}';
    return 'asmr:${work.workKey}';
  }

  Future<void> _ensureStateLoaded() async {
    if (_stateLoaded) return;
    _stateLoaded = true;
    final reader = _readPersistedState;
    if (reader == null) return;
    try {
      final raw = await reader();
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key?.toString();
        final value = entry.value;
        if (key != null && value is Map) {
          _records[key] = _WorkSmartRecord.fromJson(
            value.cast<String, Object?>(),
          );
        }
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'work_smart_status_state_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _persistState() async {
    final writer = _writePersistedState;
    if (writer == null) return;
    try {
      final payload = <String, Object?>{
        for (final entry in _records.entries) entry.key: entry.value.toJson(),
      };
      await writer(jsonEncode(payload));
    } catch (error, stackTrace) {
      AppLogService.warning(
        'work_smart_status_state_save_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _serialTail.then((_) async {
      if (_disposed) return;
      try {
        await action();
      } catch (error, stackTrace) {
        AppLogService.warning(
          'work_smart_status_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
    _serialTail = next;
    return next;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _asmrLibrary.removeListener(_handleAsmrChanged);
    await _usageSubscription.cancel();
    await _playbackSubscription.cancel();
    await _detailSubscription.cancel();
    await _autoListenedPrompts.close();
  }
}
