import 'dart:async';

import 'package:path/path.dart' as path;

import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../asmr/application/asmr_metadata_service.dart';
import '../domain/library_persistence_repository.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'cover_artwork_cache_service.dart';
import 'dlsite_metadata_query.dart';
import 'dlsite_metadata_service.dart';
import 'library_organizer.dart';
import 'library_service.dart';
import 'library_snapshot_cache_service.dart';

/// Owns audio-detail, remote metadata, artwork and duration orchestration.
final class LibraryMetadataCoordinator {
  LibraryMetadataCoordinator({
    required LibraryPersistenceRepository databaseRepository,
    required AudioDetailCacheService detailCacheService,
    required DlsiteMetadataService metadataService,
    required AsmrMetadataService asmrMetadataService,
    required LibraryService service,
    required LibrarySnapshotCacheService snapshotCacheService,
    required CoverArtworkCacheService Function() coverArtwork,
    required void Function() syncState,
    required void Function() notifyCoverChanged,
  }) : _databaseRepository = databaseRepository,
       _detailCacheService = detailCacheService,
       _metadataService = metadataService,
       _asmrMetadataService = asmrMetadataService,
       _service = service,
       _snapshotCacheService = snapshotCacheService,
       _coverArtwork = coverArtwork,
       _syncState = syncState,
       _notifyCoverChanged = notifyCoverChanged;

  static const _backupRestoreAuthoritativeKey =
      'backup_restore_authoritative_v1';

  final LibraryPersistenceRepository _databaseRepository;
  final AudioDetailCacheService _detailCacheService;
  final DlsiteMetadataService _metadataService;
  final AsmrMetadataService _asmrMetadataService;
  final LibraryService _service;
  final LibrarySnapshotCacheService _snapshotCacheService;
  final CoverArtworkCacheService Function() _coverArtwork;
  final void Function() _syncState;
  final void Function() _notifyCoverChanged;
  Future<void>? _missingDurationBackfill;
  bool _backfillRequestedAgain = false;
  int _epoch = 0;
  bool _disposed = false;

  void prepareForReset() {
    _epoch++;
    _missingDurationBackfill = null;
    _backfillRequestedAgain = false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    prepareForReset();
  }

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) =>
      _detailCacheService.load(canonicalTarget(target));

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) async {
    final result = await _detailCacheService.save(
      detail.copyWith(target: canonicalTarget(detail.target)),
    );
    _snapshotCacheService.markDetailChanged(result.detail);
    _syncState();
    return result;
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await _detailCacheService.delete(canonicalTarget(target));
    _snapshotCacheService.markDetailChanged();
    _syncState();
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
  }) async {
    final targetsByKey = <String, AudioDetailTarget>{};
    for (final track in _service.library) {
      final target = canonicalTarget(targetForTrack(track));
      targetsByKey[AudioLibraryDetailKey.forTarget(target)] = target;
    }
    Iterable<AudioDetailTarget> targets = targetsByKey.values;
    if (onlyMissing && targetsByKey.isNotEmpty) {
      final orderedTargets = targetsByKey.values.toList(growable: false);
      final databaseDetails = await _detailCacheService.loadMany(
        orderedTargets,
      );
      targets = <AudioDetailTarget>[
        for (var index = 0; index < orderedTargets.length; index++)
          if (databaseDetails[index].detail.isEmpty) orderedTargets[index],
      ];
    }
    final result = await _detailCacheService.importBackupsMany(targets);
    await _databaseRepository.saveAppSetting(
      _backupRestoreAuthoritativeKey,
      '0',
    );
    if (result.changedDetails.isNotEmpty) {
      _snapshotCacheService.markDetailChanged();
      _syncState();
    }
    return result;
  }

  AudioDetailTarget targetForTrack(MusicTrack track) {
    if (track.isSingle) return AudioDetailTarget.singleAudioFile(track.path);
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootPathForTrack(
        track,
        _service.watchedFolders,
        watchedLibraries: _service.watchedLibraries,
      ),
    );
  }

  AudioDetailTarget canonicalTarget(AudioDetailTarget target) {
    if (!target.isLibraryRootFolder) return target;
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootFolderPath(
        target.targetPath,
        _service.watchedFolders,
        watchedLibraries: _service.watchedLibraries,
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
        await _backfillDurations(epoch: epoch, durationReader: durationReader);
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
  }) async {
    final targetsByKey = <String, AudioDetailTarget>{};
    final tracksByTargetKey = <String, List<MusicTrack>>{};
    for (final track in List<MusicTrack>.of(_service.library)) {
      final target = targetForTrack(track);
      final key = _targetKey(target);
      targetsByKey.putIfAbsent(key, () => target);
      tracksByTargetKey.putIfAbsent(key, () => <MusicTrack>[]).add(track);
    }
    if (targetsByKey.isEmpty) return;
    final targets = targetsByKey.values.toList(growable: false);
    var loadResults = await _detailCacheService.loadMany(targets);
    if (!_isCurrent(epoch)) return;
    final missing = <AudioDetailTarget>[
      for (var index = 0; index < loadResults.length; index++)
        if (loadResults[index].detail.isEmpty) targets[index],
    ];
    if (missing.isNotEmpty) {
      final databaseIsAuthoritative =
          await _databaseRepository.loadAppSetting(
            _backupRestoreAuthoritativeKey,
          ) ==
          '1';
      final imported = databaseIsAuthoritative
          ? const AudioDetailBackupImportResult()
          : await _detailCacheService.importBackupsMany(missing);
      if (imported.changedDetails.isNotEmpty) {
        _snapshotCacheService.markDetailChanged();
        _syncState();
      }
      if (!_isCurrent(epoch)) return;
      loadResults = await _detailCacheService.loadMany(targets);
      if (!_isCurrent(epoch)) return;
    }
    for (var index = 0; index < targets.length; index++) {
      if (!_isCurrent(epoch)) return;
      final detail = loadResults[index].detail;
      final tracks = tracksByTargetKey[_targetKey(detail.target)];
      if (tracks == null || tracks.isEmpty) continue;
      if (detail.duration != null &&
          tracks.every((track) => track.duration > Duration.zero)) {
        continue;
      }
      final probe = await _probeDurations(tracks, durationReader);
      if (!await _commitDurations(probe.updatedTracks, epoch)) return;
      if (!_isCurrent(epoch) ||
          probe.totalDuration == null ||
          detail.duration != null) {
        continue;
      }
      final latest =
          _detailCacheService.resolvedDetail(detail.target) ?? detail;
      if (latest.duration == null) {
        final updated = await _detailCacheService.updateDerivedFields(
          latest.copyWith(duration: probe.totalDuration),
        );
        if (!_isCurrent(epoch)) return;
        _snapshotCacheService.markDetailChanged(updated);
        _syncState();
      }
    }
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
    final tracks = singleTracks.isNotEmpty
        ? singleTracks
        : _service.library
              .where(
                (track) =>
                    !track.isSingle &&
                    (PathMatcher.isWithinOrEqual(track.groupKey, targetPath) ||
                        PathMatcher.isWithinOrEqual(track.path, targetPath)),
              )
              .toList(growable: false);
    final probe = await _probeDurations(tracks, durationReader);
    return await _commitDurations(probe.updatedTracks, epoch)
        ? probe.totalDuration
        : null;
  }

  Future<({Duration? totalDuration, List<MusicTrack> updatedTracks})>
  _probeDurations(
    List<MusicTrack> tracks,
    Future<Duration?> Function(String path)? durationReader,
  ) async {
    if (tracks.isEmpty) {
      return (totalDuration: null, updatedTracks: const <MusicTrack>[]);
    }
    var total = Duration.zero;
    var hasUnknown = false;
    final missing = <MusicTrack>[];
    for (final track in tracks) {
      if (track.duration > Duration.zero) {
        total += track.duration;
      } else {
        missing.add(track);
      }
    }
    Future<Duration?> resolve(MusicTrack track) async {
      try {
        if (durationReader != null) return durationReader(track.path);
        final duration = await FileCachePlatformGateway.instance
            .resolveMediaDuration(track.path);
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
    const concurrency = 2;
    for (var start = 0; start < missing.length; start += concurrency) {
      final chunk = missing.sublist(
        start,
        (start + concurrency).clamp(0, missing.length),
      );
      final durations = await Future.wait(chunk.map(resolve));
      for (var index = 0; index < chunk.length; index++) {
        final duration = durations[index] ?? Duration.zero;
        if (duration > Duration.zero) {
          total += duration;
          updated.add(chunk[index].copyWith(duration: duration));
        } else {
          hasUnknown = true;
          AppLogService.warning(
            'library_duration_unresolved path=${chunk[index].path} '
            'video=${chunk[index].isVideo}',
          );
        }
      }
    }
    return (
      totalDuration: !hasUnknown && total > Duration.zero ? total : null,
      updatedTracks: List<MusicTrack>.unmodifiable(updated),
    );
  }

  Future<bool> _commitDurations(List<MusicTrack> tracks, int epoch) async {
    if (!_isCurrent(epoch)) return false;
    if (tracks.isEmpty) return true;
    await _databaseRepository.upsertTracks(tracks);
    if (!_isCurrent(epoch)) return false;
    for (final track in tracks) {
      final index = _service.libraryIndexByPath[track.path];
      if (index != null) _service.library[index] = track;
      _service.libraryByPath[track.path] = track;
    }
    _service.rebuildLibraryIndexes();
    _snapshotCacheService.markStructureChanged();
    _syncState();
    return true;
  }

  DlsiteMetadataQuery buildQuery(AudioDetail detail) =>
      DlsiteMetadataQuery.fromDetail(detail);

  Future<DlsiteMetadata> fetchPreferredMetadata(
    String rjCode, {
    required AppLanguage language,
  }) async {
    DlsiteMetadata primary;
    try {
      primary = await _asmrMetadataService.fetchByRjCode(
        rjCode,
        language: language,
      );
    } catch (_) {
      return _metadataService.fetchByRjCode(rjCode, language: language);
    }
    if (!_hasMissingValue(primary)) return primary;
    try {
      return _mergeMetadata(
        primary,
        await _metadataService.fetchByRjCode(rjCode, language: language),
      );
    } catch (_) {
      return primary;
    }
  }

  Future<List<DlsiteMetadata>> searchPreferredMetadata(
    Iterable<String> titles, {
    required AppLanguage language,
  }) async {
    List<DlsiteMetadata> primary;
    try {
      primary = await _asmrMetadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
    } catch (_) {
      return _metadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
    }
    if (primary.every((metadata) => !_hasMissingValue(metadata))) {
      return primary;
    }
    try {
      final fallback = await _metadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
      final byKey = <String, DlsiteMetadata>{};
      for (final metadata in fallback) {
        final key = _mergeKey(metadata);
        if (key.isNotEmpty) byKey.putIfAbsent(key, () => metadata);
      }
      final singleFallback = primary.length == 1 && fallback.length == 1
          ? fallback.single
          : null;
      return primary
          .map((metadata) {
            final match = byKey[_mergeKey(metadata)] ?? singleFallback;
            return match == null ? metadata : _mergeMetadata(metadata, match);
          })
          .toList(growable: false);
    } catch (_) {
      return primary;
    }
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
  }) => _coverArtwork().discoverCoverCandidatesInFolder(
    folderPath,
    selectedCoverPath: selectedCoverPath,
  );

  Future<String?> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
    String? sourcePath,
  }) async {
    final stored = await _coverArtwork().setFolderCoverSelection(
      folderPath,
      imagePath,
      newlySaved: newlySaved,
      sourcePath: sourcePath,
    );
    _notifyCoverChanged();
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
          : metadata.duration,
      salesCount: missingOnly && detail.salesCount != null
          ? detail.salesCount
          : metadata.salesCount,
      rating: missingOnly && detail.rating != null
          ? detail.rating
          : metadata.rating,
    );
    final saved = await saveAudioDetail(next);
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
    return path.normalize(path.join(targetPath, '..', 'cover'));
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

  static DlsiteMetadata _mergeMetadata(
    DlsiteMetadata primary,
    DlsiteMetadata fallback,
  ) {
    String stringValue(String value, String fallbackValue) =>
        value.trim().isNotEmpty ? value : fallbackValue;
    String? nullableValue(String? value, String? fallbackValue) =>
        value != null && value.trim().isNotEmpty ? value : fallbackValue;
    return primary.copyWith(
      rjCode: stringValue(primary.rjCode, fallback.rjCode),
      workTitle: stringValue(primary.workTitle, fallback.workTitle),
      circleName: stringValue(primary.circleName, fallback.circleName),
      voiceActors: primary.voiceActors.isNotEmpty
          ? primary.voiceActors
          : fallback.voiceActors,
      tags: primary.tags.isNotEmpty ? primary.tags : fallback.tags,
      releaseDate: primary.releaseDate ?? fallback.releaseDate,
      duration: primary.duration ?? fallback.duration,
      salesCount: primary.salesCount ?? fallback.salesCount,
      rating: primary.rating ?? fallback.rating,
      coverUrl: nullableValue(primary.coverUrl, fallback.coverUrl),
    );
  }
}
