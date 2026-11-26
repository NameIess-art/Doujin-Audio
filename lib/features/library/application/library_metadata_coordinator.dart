import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/platform/windows_media_tools.dart';
import '../domain/library_persistence_repository.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'cover_artwork_cache_service.dart';
import 'cover_artwork_store.dart';
import 'dlsite_metadata_query.dart';
import 'dlsite_metadata_service.dart';
import 'library_organizer.dart';
import 'library_metadata_source.dart';
import 'library_service.dart';
import 'library_snapshot_cache_service.dart';

/// Owns audio-detail, remote metadata, artwork and duration orchestration.
final class LibraryMetadataCoordinator {
  LibraryMetadataCoordinator({
    required LibraryPersistenceRepository databaseRepository,
    required AudioDetailCacheService detailCacheService,
    required DlsiteMetadataService metadataService,
    required LibraryMetadataSource? asmrMetadataService,
    LibraryMetadataSource? japaneseMetadataService,
    required LibraryService service,
    required LibrarySnapshotCacheService snapshotCacheService,
    required CoverArtworkCacheService Function() coverArtwork,
    required void Function() syncState,
    required void Function() notifyCoverChanged,
  }) : _databaseRepository = databaseRepository,
       _detailCacheService = detailCacheService,
       _metadataService = metadataService,
       _asmrMetadataService = asmrMetadataService,
       _japaneseMetadataService = japaneseMetadataService,
       _service = service,
       _snapshotCacheService = snapshotCacheService,
       _coverArtwork = coverArtwork,
       _syncState = syncState,
       _notifyCoverChanged = notifyCoverChanged;

  static const _backupRestoreAuthoritativeKey =
      'backup_restore_authoritative_v1';
  static const _durationDocumentSyncKey = 'audio_detail_duration_document_v1';
  static const _durationProbeFailuresKey = 'library_duration_probe_failures_v1';

  final LibraryPersistenceRepository _databaseRepository;
  final AudioDetailCacheService _detailCacheService;
  final DlsiteMetadataService _metadataService;
  final LibraryMetadataSource? _asmrMetadataService;
  final LibraryMetadataSource? _japaneseMetadataService;
  final LibraryService _service;
  final LibrarySnapshotCacheService _snapshotCacheService;
  final CoverArtworkCacheService Function() _coverArtwork;
  final void Function() _syncState;
  final void Function() _notifyCoverChanged;
  Future<void>? _missingDurationBackfill;
  bool _backfillRequestedAgain = false;
  bool _pendingCoverNotification = false;
  int _epoch = 0;
  bool _disposed = false;

  void prepareForReset() {
    _epoch++;
    _pendingCoverNotification = false;
    _missingDurationBackfill = null;
    _backfillRequestedAgain = false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    prepareForReset();
  }

  Future<AudioDetailLoadResult> loadAudioDetail(
    AudioDetailTarget target, {
    bool Function()? isActive,
  }) => _detailCacheService.load(canonicalTarget(target), isActive: isActive);

  Future<AudioDetailSaveResult> saveAudioDetail(
    AudioDetail detail, {
    bool deferCategoryUpdate = false,
    bool preserveExistingDuration = false,
  }) async {
    final coverPath = detail.cardCoverPath;
    Future<AudioDetailSaveResult> save() => _detailCacheService.save(
      detail.copyWith(target: canonicalTarget(detail.target)),
      preserveExistingDuration: preserveExistingDuration,
    );
    final result =
        coverPath != null && CoverArtworkStore.isStoreArtifactPath(coverPath)
        ? await _coverArtwork().withPreservedCoverReference(coverPath, save)
        : await save();
    _snapshotCacheService.markDetailChanged(result.detail, deferCategoryUpdate);
    if (!deferCategoryUpdate) _syncState();
    return result;
  }

  Future<AudioDetailSaveResult> saveAudioUserReview(
    AudioDetailTarget target, {
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
    DateTime? updatedAt,
    bool deferCategoryUpdate = false,
  }) async {
    final canonical = canonicalTarget(target);
    final cachedCover = _detailCacheService
        .resolvedDetail(canonical)
        ?.cardCoverPath;
    Future<AudioDetailSaveResult> save() => _detailCacheService.saveUserReview(
      canonical,
      listenStatus: listenStatus,
      userRating: userRating,
      reviewText: reviewText,
      updatedAt: updatedAt,
    );
    final result =
        cachedCover != null &&
            CoverArtworkStore.isStoreArtifactPath(cachedCover)
        ? await _coverArtwork().withPreservedCoverReference(cachedCover, save)
        : await save();
    _snapshotCacheService.markDetailChanged(result.detail, deferCategoryUpdate);
    if (!deferCategoryUpdate) _syncState();
    return result;
  }

  void flushMetadataUpdates() {
    _snapshotCacheService.flushDetailChanges();
    _syncState();
    if (_pendingCoverNotification) {
      _pendingCoverNotification = false;
      _notifyCoverChanged();
    }
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await _detailCacheService.delete(canonicalTarget(target));
    _snapshotCacheService.markDetailChanged();
    _syncState();
  }

  Future<bool> exportTimeSegmentLabels(String trackKey) async {
    final track = _service.trackByPath(trackKey);
    if (track == null || track.isRemoteAsmr) return true;
    try {
      return await _detailCacheService.exportTimeSegments(
        targetForTrack(track),
      );
    } on AudioDetailOperationCancelled {
      return false;
    }
  }

  Future<AudioDetailSaveResult?> prefillRjCode(
    AudioDetailTarget target,
    String text,
  ) async {
    final result = await _detailCacheService.prefillRjCodeFromText(
      canonicalTarget(target),
      text,
    );
    if (result != null) {
      _snapshotCacheService.markDetailChanged(result.detail);
      _syncState();
    }
    return result;
  }

  Future<AudioDetailBackupImportResult> importBackups({
    bool onlyMissing = false,
    Future<bool> Function()? waitForIdle,
  }) async {
    final epoch = _epoch;
    final targetsByKey = <String, AudioDetailTarget>{};
    final folderTargets = <String, AudioDetailTarget>{};
    final tracks = List<MusicTrack>.of(_service.library);
    for (var index = 0; index < tracks.length; index++) {
      final track = tracks[index];
      final target = track.isSingle
          ? targetForTrack(track)
          : folderTargets.putIfAbsent(
              track.groupKey,
              () => canonicalTarget(targetForTrack(track)),
            );
      targetsByKey[AudioLibraryDetailKey.forTarget(target)] = target;
      if ((index + 1) % 120 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!_isCurrent(epoch)) throw const AudioDetailOperationCancelled();
      }
    }
    final targets = targetsByKey.values.toList(growable: false);
    final changedDetails = <AudioDetail>[];
    var importedCount = 0;
    var failureCount = 0;
    var cancelled = false;
    const batchSize = 32;
    for (var start = 0; start < targets.length; start += batchSize) {
      await Future<void>.delayed(Duration.zero);
      if (!(await waitForIdle?.call() ?? true)) {
        cancelled = true;
        break;
      }
      if (!_isCurrent(epoch)) throw const AudioDetailOperationCancelled();
      var batch = targets.sublist(
        start,
        (start + batchSize).clamp(0, targets.length),
      );
      if (onlyMissing) {
        final loaded = await _detailCacheService.loadMany(batch);
        if (!_isCurrent(epoch)) throw const AudioDetailOperationCancelled();
        batch = <AudioDetailTarget>[
          for (var index = 0; index < batch.length; index++)
            if (loaded[index].detail.isEmpty) batch[index],
        ];
      }
      final result = await _detailCacheService.importBackupsMany(batch);
      if (!_isCurrent(epoch)) throw const AudioDetailOperationCancelled();
      changedDetails.addAll(result.changedDetails);
      importedCount += result.importedCount;
      failureCount += result.failureCount;
    }
    if (!cancelled) {
      await _databaseRepository.saveAppSetting(
        _backupRestoreAuthoritativeKey,
        '0',
      );
    }
    if (changedDetails.isNotEmpty && _isCurrent(epoch)) {
      _snapshotCacheService.markDetailChanged();
      _syncState();
    }
    return AudioDetailBackupImportResult(
      changedDetails: changedDetails,
      importedCount: importedCount,
      failureCount: failureCount,
    );
  }

  AudioDetailTarget targetForTrack(MusicTrack track) {
    if (track.isSingle) return AudioDetailTarget.singleAudioFile(track.path);
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootPathForTrack(
        track,
        _service.sortedWatchedFolders,
        watchedLibraries: _service.sortedWatchedLibraries,
        rootsAlreadySorted: true,
        watchedRootsIndex: _service.watchedFoldersIndex,
        watchedLibrariesIndex: _service.watchedLibrariesIndex,
      ),
    );
  }

  AudioDetailTarget canonicalTarget(AudioDetailTarget target) {
    if (!target.isLibraryRootFolder) return target;
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootFolderPath(
        target.targetPath,
        _service.sortedWatchedFolders,
        watchedLibraries: _service.sortedWatchedLibraries,
        rootsAlreadySorted: true,
        watchedFolderByPath: _service.watchedFolderByPath,
        watchedFoldersIndex: _service.watchedFoldersIndex,
        watchedLibrariesIndex: _service.watchedLibrariesIndex,
      ),
    );
  }

  AudioDetailTarget targetForPath(String trackPath) {
    final track = _service.trackByPath(trackPath);
    return track == null
        ? AudioDetailTarget.singleAudioFile(trackPath)
        : targetForTrack(track);
  }

  Future<void> backfillMissingDurations({
    Future<Duration?> Function(String path)? durationReader,
    Future<bool> Function()? waitForIdle,
  }) {
    final inFlight = _missingDurationBackfill;
    if (inFlight != null) {
      _backfillRequestedAgain = true;
      return inFlight;
    }
    final epoch = _epoch;
    final task = () async {
      do {
        _backfillRequestedAgain = false;
        await _backfillDurations(
          epoch: epoch,
          durationReader: durationReader,
          waitForIdle: waitForIdle,
        );
      } while (_backfillRequestedAgain && !_disposed && epoch == _epoch);
    }();
    _missingDurationBackfill = task;
    unawaited(
      task.then<void>(
        (_) => _clearBackfill(task),
        onError: (Object _, StackTrace _) => _clearBackfill(task),
      ),
    );
    return task;
  }

  void _clearBackfill(Future<void> task) {
    if (identical(_missingDurationBackfill, task)) {
      _missingDurationBackfill = null;
    }
  }

  Future<void> _backfillDurations({
    required int epoch,
    Future<Duration?> Function(String path)? durationReader,
    Future<bool> Function()? waitForIdle,
  }) async {
    Future<bool> checkpoint() async =>
        (await waitForIdle?.call() ?? true) && _isCurrent(epoch);
    if (!await checkpoint()) return;
    final targetsByKey = <String, AudioDetailTarget>{};
    var cachedRootsGeneration = -1;
    final folderTargetCache =
        <String, ({AudioDetailTarget target, String key})>{};
    ({AudioDetailTarget target, String key}) resolveTarget(MusicTrack track) {
      if (_service.libraryDerivedGeneration != cachedRootsGeneration) {
        folderTargetCache.clear();
        cachedRootsGeneration = _service.libraryDerivedGeneration;
      }
      final groupKey = track.groupKey;
      if (!track.isSingle &&
          groupKey.isNotEmpty &&
          groupKey != LibraryOrganizer.singleFilesGroupKey) {
        return folderTargetCache.putIfAbsent(groupKey, () {
          final target = targetForTrack(track);
          return (target: target, key: _targetKey(target));
        });
      }
      final target = targetForTrack(track);
      return (target: target, key: _targetKey(target));
    }

    final tracks = List<MusicTrack>.of(_service.library);
    final slice = Stopwatch()..start();
    for (final track in tracks) {
      final resolved = resolveTarget(track);
      targetsByKey.putIfAbsent(resolved.key, () => resolved.target);
      if (slice.elapsedMicroseconds >= 4000) {
        await Future<void>.delayed(Duration.zero);
        if (!await checkpoint()) return;
        slice.reset();
      }
    }
    if (targetsByKey.isEmpty) return;
    final settings = await _databaseRepository.loadAppSettings([
      _backupRestoreAuthoritativeKey,
      _durationDocumentSyncKey,
      _durationProbeFailuresKey,
    ]);
    final syncSetting = settings[_durationDocumentSyncKey];
    final synchronized = syncSetting == null
        ? <String, int>{}
        : await _readDurationDocumentSync(syncSetting);
    final previousSyncCount = synchronized.length;
    synchronized.removeWhere((key, _) => !targetsByKey.containsKey(key));
    var syncChanged = synchronized.length != previousSyncCount;
    final failureSetting = settings[_durationProbeFailuresKey];
    final failedProbes = failureSetting == null
        ? <String, String>{}
        : await _readDurationProbeFailures(failureSetting);
    var failuresChanged = false;
    if (failedProbes.isNotEmpty) {
      final missingTrackKeys = <String>{
        for (final track in tracks)
          if (track.duration <= Duration.zero)
            PathMatcher.equivalenceKey(track.path),
      };
      final previousFailureCount = failedProbes.length;
      failedProbes.removeWhere((key, _) => !missingTrackKeys.contains(key));
      failuresChanged = failedProbes.length != previousFailureCount;
    }
    final targets = targetsByKey.values.toList(growable: false);
    final targetKeys = <String>[
      for (final target in targets) _targetKey(target),
    ];
    final fastDurations = await _detailCacheService.loadDurationsIfSupported(
      targets,
    );
    if (!await checkpoint()) return;
    final knownDurations = <String, Duration?>{};
    final missing = <AudioDetailTarget>[];
    if (fastDurations != null) {
      final nullDurationCandidates = <AudioDetailTarget>[];
      for (var index = 0; index < targets.length; index++) {
        final key = targetKeys[index];
        final duration = fastDurations[key];
        if (!fastDurations.containsKey(key)) {
          missing.add(targets[index]);
        } else if (duration != null) {
          knownDurations[key] = duration;
        } else {
          knownDurations[key] = null;
          final cached = _detailCacheService.resolvedDetail(targets[index]);
          if (cached == null) {
            nullDurationCandidates.add(targets[index]);
          } else if (cached.isEmpty) {
            missing.add(targets[index]);
          }
        }
      }
      if (nullDurationCandidates.isNotEmpty) {
        if (!await checkpoint()) return;
        final checkedDetails = await _detailCacheService.loadSearchDetails(
          nullDurationCandidates,
        );
        if (!_isCurrent(epoch)) return;
        for (var index = 0; index < nullDurationCandidates.length; index++) {
          final detail = checkedDetails[index];
          final key = _targetKey(nullDurationCandidates[index]);
          knownDurations[key] = detail.duration;
          if (detail.isEmpty && detail.duration == null) {
            missing.add(nullDurationCandidates[index]);
          }
        }
      }
    } else {
      final loadResults = <AudioDetailLoadResult>[];
      for (var start = 0; start < targets.length; start += 64) {
        if (!await checkpoint()) return;
        loadResults.addAll(
          await _detailCacheService.loadMany(targets.skip(start).take(64)),
        );
      }
      if (!_isCurrent(epoch)) return;
      for (var index = 0; index < loadResults.length; index++) {
        final detail = loadResults[index].detail;
        knownDurations[targetKeys[index]] = detail.duration;
        if (detail.isEmpty && detail.duration == null) {
          missing.add(targets[index]);
        }
      }
    }
    if (missing.isNotEmpty) {
      if (!await checkpoint()) return;
      final databaseIsAuthoritative =
          settings[_backupRestoreAuthoritativeKey] == '1';
      if (!databaseIsAuthoritative) {
        final importedDetails = <String, AudioDetail>{};
        for (var start = 0; start < missing.length; start += 64) {
          if (!await checkpoint()) return;
          final imported = await _detailCacheService.importBackupsMany(
            missing.skip(start).take(64),
          );
          if (imported.changedDetails.isNotEmpty) {
            for (final detail in imported.changedDetails) {
              importedDetails[_targetKey(detail.target)] = detail;
            }
            _snapshotCacheService.markDetailChanged();
            _syncState();
          }
        }
        // The first pass already owns a complete snapshot, even when its rows
        // outgrow the LRU. Only imported records need to replace that snapshot.
        for (var index = 0; index < targets.length; index++) {
          final key = targetKeys[index];
          final imported = importedDetails[key];
          if (imported != null) {
            knownDurations[key] = imported.duration;
          }
        }
      }
      if (!_isCurrent(epoch)) return;
    }

    var hasTracksToProbe = false;
    for (final track in tracks) {
      if (track.duration <= Duration.zero &&
          failedProbes[PathMatcher.equivalenceKey(track.path)] !=
              _durationFailureFingerprint(track)) {
        hasTracksToProbe = true;
        break;
      }
    }
    final unsynchronizedIndices = <int>[];
    final unsynchronizedKeys = <String>{};
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      final targetKey = targetKeys[index];
      final known =
          _detailCacheService.resolvedDetail(target)?.duration ??
          knownDurations[targetKey];
      if (known != null && synchronized[targetKey] == known.inMilliseconds) {
        continue;
      }
      unsynchronizedIndices.add(index);
      unsynchronizedKeys.add(targetKey);
    }

    var didUpdateTrackDurations = false;
    try {
      if (!hasTracksToProbe && unsynchronizedIndices.isEmpty) {
        return;
      }
      if (hasTracksToProbe) {
        await _probeDurations(
          tracks,
          durationReader,
          epoch: epoch,
          waitForIdle: waitForIdle,
          failedFingerprints: failedProbes,
          onResolved: (track) {
            if (failedProbes.remove(PathMatcher.equivalenceKey(track.path)) !=
                null) {
              failuresChanged = true;
            }
          },
          onUnresolved: (track) {
            final key = PathMatcher.equivalenceKey(track.path);
            final fingerprint = _durationFailureFingerprint(track);
            if (failedProbes[key] != fingerprint) {
              failedProbes[key] = fingerprint;
              failuresChanged = true;
            }
          },
          commitBatch: (batch) => _commitDurations(
            batch,
            epoch,
            notify: false,
            invalidateSnapshots: false,
            onUpdated: () => didUpdateTrackDurations = true,
          ),
        );
      }
      if (!await checkpoint()) return;
      if (unsynchronizedIndices.isEmpty) return;

      final currentLibrary = List<MusicTrack>.of(_service.library);
      final tracksByTargetKey = <String, List<MusicTrack>>{};
      slice.reset();
      for (final track in currentLibrary) {
        final key = resolveTarget(track).key;
        if (!unsynchronizedKeys.contains(key)) continue;
        tracksByTargetKey.putIfAbsent(key, () => <MusicTrack>[]).add(track);
        if (slice.elapsedMicroseconds >= 4000) {
          await Future<void>.delayed(Duration.zero);
          if (!await checkpoint()) return;
          slice.reset();
        }
      }

      final pendingSaves =
          <({AudioDetailTarget target, String targetKey, Duration duration})>[];
      for (final index in unsynchronizedIndices) {
        if (!await checkpoint()) return;
        final target = targets[index];
        final targetKey = targetKeys[index];
        final knownDuration =
            _detailCacheService.resolvedDetail(target)?.duration ??
            knownDurations[targetKey];
        if (knownDuration != null &&
            synchronized[targetKey] == knownDuration.inMilliseconds) {
          continue;
        }
        if (synchronized.remove(targetKey) != null) syncChanged = true;
        final currentTracks = <MusicTrack>[
          for (final track in tracksByTargetKey[targetKey] ?? <MusicTrack>[])
            if (_service.libraryByPath[track.path] case final current?)
              if (resolveTarget(current).key == targetKey) current,
        ];
        if (currentTracks.isEmpty) continue;
        var total = Duration.zero;
        var hasUnknown = false;
        for (final track in currentTracks) {
          if (track.duration <= Duration.zero) hasUnknown = true;
          total += track.duration;
        }
        final duration =
            knownDuration ??
            (!hasUnknown && total > Duration.zero ? total : null);
        if (duration != null) {
          pendingSaves.add((
            target: target,
            targetKey: targetKey,
            duration: duration,
          ));
        }
      }

      if (pendingSaves.isNotEmpty) {
        const prewarmChunkSize = 64;
        const maxConcurrentSaves = 4;
        for (
          var chunkStart = 0;
          chunkStart < pendingSaves.length;
          chunkStart += prewarmChunkSize
        ) {
          if (!await checkpoint()) return;
          final chunkEnd = (chunkStart + prewarmChunkSize).clamp(
            0,
            pendingSaves.length,
          );
          final chunk = pendingSaves.sublist(chunkStart, chunkEnd);
          if (chunk.length > 1) {
            await _detailCacheService.loadMany(
              chunk.map((item) => item.target),
            );
            if (!await checkpoint()) return;
          }
          for (
            var start = 0;
            start < chunk.length;
            start += maxConcurrentSaves
          ) {
            if (!await checkpoint()) return;
            final end = (start + maxConcurrentSaves).clamp(0, chunk.length);
            final wave = chunk.sublist(start, end);
            final results = await Future.wait([
              for (final item in wave)
                saveMissingDuration(
                  item.target,
                  item.duration,
                  deferCategoryUpdate: true,
                  skipSynchronizedDocument: true,
                ),
            ]);
            if (!_isCurrent(epoch)) return;
            for (var i = 0; i < wave.length; i++) {
              final result = results[i];
              if (!result.documentFailed && result.detail.duration != null) {
                synchronized[wave[i].targetKey] =
                    result.detail.duration!.inMilliseconds;
                syncChanged = true;
              }
            }
          }
        }
      }
    } finally {
      if (_isCurrent(epoch)) {
        if (didUpdateTrackDurations) {
          _service.markStructureChanged();
          _snapshotCacheService.markStructureChanged();
        }
        flushMetadataUpdates();
        if (syncChanged) {
          await _persistDurationDocumentSync(synchronized, epoch);
        }
        if (failuresChanged) {
          await _persistDurationProbeFailures(failedProbes, epoch);
        }
      }
    }
  }

  static String _durationFailureFingerprint(MusicTrack track) =>
      '${track.fileSizeBytes ?? -1}|${track.modifiedAt?.millisecondsSinceEpoch ?? -1}';

  static Future<Map<String, String>> _readDurationProbeFailures(String value) =>
      Isolate.run(() => _decodeDurationProbeFailures(value));

  static Map<String, String> _decodeDurationProbeFailures(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return <String, String>{
          for (final entry in decoded.entries)
            if (entry.value case final String fingerprint
                when entry.key.isNotEmpty && fingerprint.isNotEmpty)
              entry.key: fingerprint,
        };
      }
    } on FormatException {
      // Negative cache is an optimization and can be regenerated.
    }
    return <String, String>{};
  }

  static Future<String> _encodeDurationProbeFailures(
    Map<String, String> values,
  ) => Isolate.run(() => jsonEncode(values));

  Future<void> _persistDurationProbeFailures(
    Map<String, String> failedProbes,
    int epoch,
  ) async {
    try {
      final encoded = failedProbes.isEmpty
          ? null
          : await _encodeDurationProbeFailures(failedProbes);
      if (!_isCurrent(epoch)) return;
      await _databaseRepository.saveAppSetting(
        _durationProbeFailuresKey,
        encoded,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'library_duration_probe_failures_checkpoint_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<Map<String, int>> _readDurationDocumentSync(String value) =>
      Isolate.run(() => _decodeDurationDocumentSync(value));

  static Map<String, int> _decodeDurationDocumentSync(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return {
          for (final entry in decoded.entries)
            if (entry.value case final int duration when duration > 0)
              entry.key: duration,
        };
      }
    } on FormatException {
      // The marker is an optimization and can be regenerated from source docs.
    }
    return {};
  }

  static Future<String> _encodeDurationDocumentSync(Map<String, int> values) =>
      Isolate.run(() => jsonEncode(values));

  Future<void> _persistDurationDocumentSync(
    Map<String, int> synchronized,
    int epoch,
  ) async {
    try {
      final encoded = synchronized.isEmpty
          ? null
          : await _encodeDurationDocumentSync(synchronized);
      if (!_isCurrent(epoch)) return;
      await _databaseRepository.saveAppSetting(
        _durationDocumentSyncKey,
        encoded,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'library_duration_document_checkpoint_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<AudioDetailSaveResult> saveMissingDuration(
    AudioDetailTarget target,
    Duration duration, {
    bool deferCategoryUpdate = false,
    bool skipSynchronizedDocument = false,
  }) async {
    final epoch = _epoch;
    if (!_isCurrent(epoch)) throw const AudioDetailOperationCancelled();
    final canonical = canonicalTarget(target);
    final previous = _detailCacheService.resolvedDetail(canonical);
    final result = await _detailCacheService.saveMissingDuration(
      canonical,
      duration,
      skipSynchronizedDocument: skipSynchronizedDocument,
    );
    if (!_isCurrent(epoch)) throw const AudioDetailOperationCancelled();
    if (previous?.duration != result.detail.duration) {
      _snapshotCacheService.markDetailChanged(
        result.detail,
        deferCategoryUpdate,
      );
      if (!deferCategoryUpdate) _syncState();
    }
    if (result.documentFailed) {
      AppLogService.warning(
        'library_duration_document_sync_failed '
        'target=${canonical.targetPath} error=${result.documentError}',
      );
    }
    return result;
  }

  Future<Duration?> calculateMissingDuration(
    String targetPath, {
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    final epoch = _epoch;
    final singleTracks = _service.library
        .where(
          (track) =>
              track.isSingle &&
              PathMatcher.equalsNormalized(track.path, targetPath),
        )
        .toList(growable: false);
    final target = singleTracks.isNotEmpty
        ? targetForTrack(singleTracks.first)
        : canonicalTarget(AudioDetailTarget.libraryRootFolder(targetPath));
    final tracks = singleTracks.isNotEmpty
        ? singleTracks
        : _service.library
              .where(
                (track) =>
                    !track.isSingle &&
                    (PathMatcher.isWithinOrEqual(
                          track.groupKey,
                          target.targetPath,
                        ) ||
                        PathMatcher.isWithinOrEqual(
                          track.path,
                          target.targetPath,
                        )),
              )
              .toList(growable: false);
    final probe = await _probeDurations(tracks, durationReader, epoch: epoch);
    if (!await _commitDurations(probe.updatedTracks, epoch) ||
        !_isCurrent(epoch) ||
        probe.totalDuration == null) {
      return null;
    }
    return (await saveMissingDuration(
      target,
      probe.totalDuration!,
    )).detail.duration;
  }

  Future<({Duration? totalDuration, List<MusicTrack> updatedTracks})>
  _probeDurations(
    List<MusicTrack> tracks,
    Future<Duration?> Function(String path)? durationReader, {
    required int epoch,
    Future<bool> Function()? waitForIdle,
    Map<String, String>? failedFingerprints,
    void Function(MusicTrack track)? onResolved,
    void Function(MusicTrack track)? onUnresolved,
    Future<bool> Function(List<MusicTrack>)? commitBatch,
  }) async {
    if (tracks.isEmpty || !_isCurrent(epoch)) {
      return (totalDuration: null, updatedTracks: const <MusicTrack>[]);
    }
    var total = Duration.zero;
    var hasUnknown = false;
    final missing = <MusicTrack>[];
    for (final track in tracks) {
      if (track.duration > Duration.zero) {
        total += track.duration;
      } else if (failedFingerprints != null &&
          failedFingerprints[PathMatcher.equivalenceKey(track.path)] ==
              _durationFailureFingerprint(track)) {
        hasUnknown = true;
      } else {
        missing.add(track);
      }
    }
    if (missing.isEmpty) {
      return (
        totalDuration: !hasUnknown && total > Duration.zero ? total : null,
        updatedTracks: const <MusicTrack>[],
      );
    }
    final useWindowsBatchHeaders = Platform.isWindows && durationReader == null;
    Future<Duration?> resolve(MusicTrack track) async {
      try {
        if (durationReader != null) return await durationReader(track.path);
        final duration = useWindowsBatchHeaders
            ? await WindowsMediaTools.instance.readDuration(
                track.path,
                skipHeaderParse: true,
              )
            : await FileCachePlatformGateway.instance.resolveMediaDuration(
                track.path,
              );
        return duration != null && duration > Duration.zero ? duration : null;
      } catch (error, stackTrace) {
        AppLogService.warning(
          'library_duration_probe_failed path=${track.path}',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }

    final updated = <MusicTrack>[];
    final concurrency = Platform.isWindows ? 4 : 2;
    const commitBatchSize = 64;
    var aborted = false;

    for (
      var batchStart = 0;
      batchStart < missing.length && !aborted;
      batchStart += commitBatchSize
    ) {
      final batchEnd = (batchStart + commitBatchSize < missing.length)
          ? batchStart + commitBatchSize
          : missing.length;
      final batchTracks = missing.sublist(batchStart, batchEnd);
      List<MusicTrack> fallbackTracks = batchTracks;
      if (useWindowsBatchHeaders) {
        if (!(await waitForIdle?.call() ?? true) || !_isCurrent(epoch)) {
          aborted = true;
          break;
        }
        final headerDurations = await WindowsMediaTools.instance
            .readHeaderDurationsBatch([
              for (final track in batchTracks) track.path,
            ]);
        if (!_isCurrent(epoch)) {
          aborted = true;
          break;
        }
        final remaining = <MusicTrack>[];
        for (final track in batchTracks) {
          final parsed = headerDurations[track.path];
          if (parsed != null && parsed > Duration.zero) {
            total += parsed;
            updated.add(track.copyWith(duration: parsed));
            onResolved?.call(track);
          } else {
            remaining.add(track);
          }
        }
        fallbackTracks = remaining;
      }

      if (fallbackTracks.isNotEmpty) {
        var nextIndex = 0;
        Future<void> worker() async {
          while (!aborted) {
            if (!(await waitForIdle?.call() ?? true) || !_isCurrent(epoch)) {
              aborted = true;
              return;
            }
            if (aborted || nextIndex >= fallbackTracks.length) return;
            final track = fallbackTracks[nextIndex++];
            final duration = await resolve(track) ?? Duration.zero;
            if (aborted || !_isCurrent(epoch)) {
              aborted = true;
              return;
            }
            if (duration > Duration.zero) {
              total += duration;
              updated.add(track.copyWith(duration: duration));
              onResolved?.call(track);
            } else {
              hasUnknown = true;
              onUnresolved?.call(track);
              AppLogService.warning(
                'library_duration_unresolved path=${track.path} '
                'video=${track.isVideo}',
              );
            }
          }
        }

        final remaining = fallbackTracks.length;
        final workerCount = remaining < concurrency ? remaining : concurrency;
        await Future.wait(List.generate(workerCount, (_) => worker()));
      }
      if (aborted || !_isCurrent(epoch)) {
        return (totalDuration: null, updatedTracks: const <MusicTrack>[]);
      }
      if (commitBatch != null && updated.isNotEmpty) {
        final batch = List<MusicTrack>.of(updated);
        updated.clear();
        if (!await commitBatch(batch)) {
          return (totalDuration: null, updatedTracks: const <MusicTrack>[]);
        }
      }
    }
    return (
      totalDuration: !hasUnknown && total > Duration.zero ? total : null,
      updatedTracks: List<MusicTrack>.unmodifiable(updated),
    );
  }

  Future<bool> _commitDurations(
    List<MusicTrack> tracks,
    int epoch, {
    bool notify = true,
    bool invalidateSnapshots = true,
    void Function()? onUpdated,
  }) async {
    if (!_isCurrent(epoch)) return false;
    if (tracks.isEmpty) return true;
    // Probing is asynchronous; retain edits made to a track while it ran.
    final durations = <String, Duration>{
      for (final track in tracks)
        if (_service.libraryByPath[track.path] case final current?)
          if (current.duration <= Duration.zero) current.path: track.duration,
    };
    if (durations.isEmpty) return true;
    await _databaseRepository.updateTrackDurations(durations);
    if (!_isCurrent(epoch)) return false;
    if (!_service.fillMissingTrackDurations(
      durations,
      notifyStructure: invalidateSnapshots,
    )) {
      return true;
    }
    onUpdated?.call();
    if (invalidateSnapshots) _snapshotCacheService.markStructureChanged();
    if (notify) _syncState();
    return true;
  }

  DlsiteMetadataQuery buildQuery(AudioDetail detail) =>
      DlsiteMetadataQuery.fromDetail(detail);

  Future<DlsiteMetadata> fetchPreferredMetadata(
    String rjCode, {
    required AppLanguage language,
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) _metadataService.clearCache();
    return (await _lookupPreferredMetadata(
      (source) async => [await source.fetchByRjCode(rjCode, language: language)],
    )).single;
  }

  Future<List<DlsiteMetadata>> searchPreferredMetadata(
    Iterable<String> titles, {
    required AppLanguage language,
    bool forceRefresh = false,
  }) {
    if (forceRefresh) _metadataService.clearCache();
    return _lookupPreferredMetadata(
      (source) => source.searchByTitleCandidates(titles, language: language),
    );
  }

  Future<List<DlsiteMetadata>> _lookupPreferredMetadata(
    Future<List<DlsiteMetadata>> Function(LibraryMetadataSource) lookup,
  ) async {
    final sources = <({String name, LibraryMetadataSource source})>[
      (name: 'DLsite', source: _metadataService),
      if (_asmrMetadataService case final source?)
        (name: 'ASMR.ONE', source: source),
      if (_japaneseMetadataService case final source?)
        (name: 'Japanese ASMR', source: source),
    ];
    var primary = <DlsiteMetadata>[];
    ({Object error, StackTrace stackTrace})? lastFailure;
    for (final entry in sources) {
      List<DlsiteMetadata> fallback;
      try {
        fallback = await lookup(entry.source);
      } catch (error, stackTrace) {
        AppLogService.warning(
          'metadata_lookup_failed source=${entry.name}',
          error: error,
          stackTrace: stackTrace,
        );
        lastFailure = (error: error, stackTrace: stackTrace);
        continue;
      }
      if (primary.isEmpty) {
        primary = fallback;
      } else {
        final byKey = <String, DlsiteMetadata>{};
        for (final metadata in fallback) {
          final key = _mergeKey(metadata);
          if (key.isNotEmpty) byKey.putIfAbsent(key, () => metadata);
        }
        primary = primary
            .map((metadata) {
              final match = byKey[_mergeKey(metadata)];
              return match == null ? metadata : metadata.fillMissingFrom(match);
            })
            .toList(growable: false);
      }
      if (primary.isNotEmpty &&
          primary.every((metadata) => !_hasMissingValue(metadata))) {
        return primary;
      }
    }
    if (primary.isNotEmpty) return primary;
    if (lastFailure case final failure?) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    throw const DlsiteMetadataException(
      'No work metadata found',
      kind: DlsiteMetadataFailureKind.notFound,
    );
  }

  AudioDetail? resolvedDetail(AudioDetailTarget target) =>
      _detailCacheService.resolvedDetail(canonicalTarget(target));

  String? resolvedCoverForTrack(MusicTrack? track, {String? trackPath}) =>
      _coverArtwork().resolvedForTrack(track, trackPath: trackPath);

  String? resolvedPlaybackCoverForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _coverArtwork().resolvedForPlaybackTrack(track, trackPath: trackPath);

  String? resolvedRemoteCover(String url) =>
      _coverArtwork().resolvedForRemoteCover(url);

  String? resolvedFolderCover(String folderPath) =>
      _coverArtwork().resolvedForFolder(folderPath);

  Future<String?> coverForTrack(MusicTrack? track, {String? trackPath}) =>
      _coverArtwork().futureForTrack(track, trackPath: trackPath);

  String? resolvedEmbeddedCoverForPath(String filePath) =>
      _coverArtwork().resolvedEmbeddedCoverForPath(filePath);

  Future<String?> resolveEmbeddedCoverForPath(String filePath) =>
      _coverArtwork().resolveEmbeddedCoverForPath(filePath);

  Future<String?> playbackCoverForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _coverArtwork().futureForPlaybackTrack(track, trackPath: trackPath);

  Future<String?> coverForFolder(String folderPath) =>
      _coverArtwork().futureForFolder(folderPath);

  Future<String?> coverForRemote(String url) =>
      _coverArtwork().futureForRemoteCover(url);

  Future<List<String>> discoverCoverCandidates(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
    bool Function()? isCancelled,
  }) => _coverArtwork().discoverCoverCandidatesInFolder(
    folderPath,
    selectedCoverPath: selectedCoverPath,
    includeVideoFrames: includeVideoFrames,
    includeEmbeddedCovers: includeEmbeddedCovers,
    propagateFailure: propagateFailure,
    isCancelled: isCancelled,
  );

  Future<String?> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
    String? sourcePath,
    bool deferNotification = false,
  }) async {
    final stored = await _coverArtwork().setFolderCoverSelection(
      folderPath,
      imagePath,
      newlySaved: newlySaved,
      sourcePath: sourcePath,
    );
    if (deferNotification) {
      // The runtime cover callback also publishes detail revisions.
      _pendingCoverNotification = true;
    } else {
      _notifyCoverChanged();
    }
    return stored;
  }

  void invalidateCoverArtwork() {
    _coverArtwork().invalidateAll();
    _notifyCoverChanged();
  }

  Future<DlsiteMetadataApplyResult> applyMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
    required AppLanguage language,
    bool missingOnly = false,
    bool deferCategoryUpdate = false,
  }) async {
    String stringValue(String current, String fetched) =>
        missingOnly && current.trim().isNotEmpty ? current : fetched;
    List<String> listValue(List<String> current, List<String> fetched) =>
        missingOnly && current.isNotEmpty ? current : fetched;
    final next = detail.copyWith(
      rjCode: stringValue(detail.rjCode, metadata.rjCode),
      workTitle: stringValue(detail.workTitle, metadata.workTitle),
      circleName: stringValue(detail.circleName, metadata.circleName),
      voiceActors: listValue(detail.voiceActors, metadata.voiceActors),
      tags: listValue(detail.tags, metadata.tags),
      releaseDate: missingOnly && detail.releaseDate != null
          ? detail.releaseDate
          : metadata.releaseDate,
      duration: missingOnly && detail.duration != null
          ? detail.duration
          : metadata.duration ?? detail.duration,
      rating: missingOnly && detail.rating != null
          ? detail.rating
          : metadata.rating,
    );
    final saved = await saveAudioDetail(
      next,
      deferCategoryUpdate: deferCategoryUpdate,
      preserveExistingDuration: metadata.duration == null,
    );
    String? coverPath;
    Object? coverError;
    if (saveCover &&
        next.target.isLibraryRootFolder &&
        metadata.coverUrl != null) {
      try {
        final downloaded = await _metadataService.downloadCover(
          coverUrl: metadata.coverUrl!,
          folderPath: _metadataCoverFolder(next.target.targetPath),
          rjCode: metadata.rjCode,
          fileName: 'cover.jpg',
          language: language,
        );
        coverPath = downloaded.displayPath;
        await setFolderManualCover(
          next.target.targetPath,
          coverPath,
          newlySaved: true,
          sourcePath: downloaded.sourcePath,
          deferNotification: deferCategoryUpdate,
        );
      } catch (error) {
        coverError = error;
      }
    }
    return DlsiteMetadataApplyResult(
      detail: saved.detail,
      coverPath: coverPath,
      coverError: coverError,
    );
  }

  String _metadataCoverFolder(String targetPath) {
    if (PathMatcher.isContentUri(targetPath)) return targetPath;
    return path.normalize(path.join(targetPath, 'cover'));
  }

  bool _isCurrent(int epoch) => !_disposed && epoch == _epoch;

  static String _targetKey(AudioDetailTarget target) => <String>[
    target.targetType.dbValue,
    PathMatcher.equivalenceKey(target.targetPath),
  ].join('|');

  static bool _hasMissingValue(DlsiteMetadata metadata) =>
      metadata.rjCode.trim().isEmpty ||
      metadata.workTitle.trim().isEmpty ||
      metadata.circleName.trim().isEmpty ||
      (metadata.coverUrl?.trim().isEmpty ?? true) ||
      metadata.voiceActors.isEmpty ||
      metadata.tags.isEmpty ||
      metadata.releaseDate == null ||
      metadata.duration == null ||
      metadata.salesCount == null ||
      metadata.rating == null;

  static String _mergeKey(DlsiteMetadata metadata) {
    final rjCode = metadata.rjCode.trim().toUpperCase();
    if (rjCode.isNotEmpty) return 'rj:$rjCode';
    final title = metadata.workTitle.trim().toLowerCase();
    return title.isEmpty ? '' : 'title:$title';
  }
}
