import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;

import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/path_display.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/ui/warmup_scheduler.dart';
import '../../asmr/application/asmr_metadata_service.dart';
import '../../player/application/audio_state_services.dart';
import '../../settings/application/app_preferences.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'cover_artwork_cache_service.dart';
import 'dlsite_metadata_query.dart';
import 'dlsite_metadata_service.dart';
import 'library_snapshot_cache_service.dart';
import 'library_catalog.dart';
import 'library_scan_models.dart';
import 'library_organizer.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';

/// Owns the library-side services used by the compatibility audio facade.
///
/// Mutable library state remains owned exclusively by [LibraryService].
final class LibraryFacade implements LibraryCatalog {
  static const _watchedFoldersPreferenceKey = 'watched_folders_v1';
  static const _watchedLibrariesPreferenceKey = 'watched_libraries_v1';
  static const _libraryNodeOrderPreferenceKey = 'library_node_order_v1';
  static const _groupOrderPreferenceKey = 'group_order_v1';
  static const _libraryExclusionsPreferenceKey = 'library_exclusions_v1';
  LibraryFacade({
    required this.databaseRepository,
    required this.detailCacheService,
    required this.metadataService,
    required this.asmrMetadataService,
    required this.service,
    required this.snapshotCacheService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) : _coverArtworkCacheService = coverArtworkCacheService {
    UiInteractionCoordinator.instance.addListener(
      _handleWarmupInteractionChanged,
    );
    _handleWarmupInteractionChanged();
  }

  factory LibraryFacade.create({
    AudioDatabaseRepository? databaseRepository,
    AudioDetailRepository? detailRepository,
    AudioDetailCacheService? detailCacheService,
    DlsiteMetadataService? metadataService,
    AsmrMetadataService? asmrMetadataService,
    LibraryService? service,
    LibrarySnapshotCacheService? snapshotCacheService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) {
    final resolvedDatabase = databaseRepository ?? AudioDatabaseRepository();
    final resolvedDetailCache =
        detailCacheService ??
        AudioDetailCacheService(
          repository:
              detailRepository ??
              AudioDetailRepository(databaseRepository: resolvedDatabase),
        );
    final resolvedService = service ?? LibraryService();
    return LibraryFacade(
      databaseRepository: resolvedDatabase,
      detailCacheService: resolvedDetailCache,
      metadataService: metadataService ?? DlsiteMetadataService(),
      asmrMetadataService: asmrMetadataService ?? AsmrMetadataService(),
      service: resolvedService,
      snapshotCacheService:
          snapshotCacheService ??
          LibrarySnapshotCacheService(
            libraryService: resolvedService,
            detailCacheService: resolvedDetailCache,
          ),
      coverArtworkCacheService: coverArtworkCacheService,
    );
  }

  final AudioDatabaseRepository databaseRepository;
  final AudioDetailCacheService detailCacheService;
  final DlsiteMetadataService metadataService;
  final AsmrMetadataService asmrMetadataService;
  final LibraryService service;
  final LibrarySnapshotCacheService snapshotCacheService;
  CoverArtworkCacheService? _coverArtworkCacheService;
  Future<void>? _missingDurationBackfill;
  bool _missingDurationBackfillRequestedAgain = false;
  bool _persistenceEnabled = true;
  bool _disposed = false;
  void Function(List<String> removedPaths)? _trackRemovalHandler;
  void Function()? _coverChangeHandler;
  final WarmupScheduler _coverWarmupScheduler = WarmupScheduler();

  LibraryState get state => service.slice.state;
  Stream<LibraryState> get states => service.slice.stream;
  List<LibraryNode> get libraryCards => snapshotCacheService.cards;
  @override
  List<MusicTrack> get library =>
      UnmodifiableListView<MusicTrack>(service.library);
  @override
  List<String> get watchedFolders =>
      UnmodifiableListView<String>(service.watchedFolders);
  @override
  List<String> get watchedLibraries =>
      UnmodifiableListView<String>(service.watchedLibraries);
  @override
  bool get isScanning => service.isScanning;
  bool get isBackgroundScanning => service.isBackgroundScanning;
  @override
  int get scanFoundCount => service.scanFoundCount;
  @override
  int get scanDuplicateCount => service.scanDuplicateCount;
  @override
  int get scanFailureCount => service.scanFailureCount;
  AudioLibraryCategorySnapshot? get categorySnapshot =>
      snapshotCacheService.categorySnapshotSync;

  List<LibraryNode> get libraryTree {
    if (snapshotCacheService.treeSnapshotRevision !=
        service.structureRevision) {
      unawaited(loadLibraryTree());
    }
    return snapshotCacheService.tree;
  }

  Future<List<LibraryNode>> loadLibraryTree() async {
    final snapshot = await snapshotCacheService.treeSnapshot(
      onCommitted: _syncStateSlice,
    );
    return snapshot.tree;
  }

  Future<FolderNode?> loadLibraryFolderTree(String folderPath) async {
    final tree = await loadLibraryTree();
    for (final node in tree.whereType<FolderNode>()) {
      if (PathMatcher.equalsNormalized(node.path, folderPath)) return node;
    }
    return null;
  }

  String? libraryRootForPath(String entityPath) {
    for (final libraryPath in service.watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(entityPath, libraryPath)) {
        return libraryPath;
      }
    }
    for (final folderPath in service.watchedFolders) {
      if (PathMatcher.isWithinOrEqual(entityPath, folderPath)) {
        return folderPath;
      }
    }
    return null;
  }

  Future<AudioLibraryCategorySnapshot> audioLibraryCategorySnapshot({
    void Function()? onCommitted,
  }) => snapshotCacheService.categorySnapshot(
    onCommitted: () {
      _syncStateSlice();
      onCommitted?.call();
    },
  );

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) =>
      detailCacheService.load(target);

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) async {
    final result = await detailCacheService.save(detail);
    snapshotCacheService.markDetailChanged(result.detail);
    _syncStateSlice();
    return result;
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await detailCacheService.delete(target);
    snapshotCacheService.markDetailChanged();
    _syncStateSlice();
  }

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCode(
    AudioDetailTarget target,
    String text,
  ) async {
    final result = await detailCacheService.prefillRjCodeFromText(target, text);
    if (result != null) {
      snapshotCacheService.markDetailChanged(result.detail);
      _syncStateSlice();
    }
    return result;
  }

  @override
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  ) async {
    await prefillAudioDetailRjCode(
      AudioDetailTarget.libraryRootFolder(folderPath),
      displayName,
    );
  }

  AudioDetailTarget audioDetailTargetForTrack(MusicTrack track) {
    if (track.isSingle) {
      return AudioDetailTarget.singleAudioFile(track.path);
    }
    final watchedRoots = List<String>.of(service.watchedFolders)
      ..sort((a, b) => b.length.compareTo(a.length));
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootPathForTrack(track, watchedRoots),
    );
  }

  AudioDetailTarget audioDetailTargetForPath(String trackPath) {
    final track = trackByPath(trackPath);
    return track == null
        ? AudioDetailTarget.singleAudioFile(trackPath)
        : audioDetailTargetForTrack(track);
  }

  Future<void> backfillMissingLibraryDurations({
    Future<Duration?> Function(String path)? durationReader,
  }) {
    final inFlight = _missingDurationBackfill;
    if (inFlight != null) {
      _missingDurationBackfillRequestedAgain = true;
      return inFlight;
    }

    final task = () async {
      do {
        _missingDurationBackfillRequestedAgain = false;
        await _backfillMissingLibraryDurations(durationReader: durationReader);
      } while (_missingDurationBackfillRequestedAgain && !_disposed);
    }();
    _missingDurationBackfill = task;
    unawaited(
      task.then<void>(
        (_) => _clearMissingDurationBackfill(task),
        onError: (Object error, StackTrace stackTrace) {
          _clearMissingDurationBackfill(task);
        },
      ),
    );
    return task;
  }

  void _clearMissingDurationBackfill(Future<void> task) {
    if (identical(_missingDurationBackfill, task)) {
      _missingDurationBackfill = null;
    }
  }

  Future<void> _backfillMissingLibraryDurations({
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    final targetsByKey = <String, AudioDetailTarget>{};
    final tracksByTargetKey = <String, List<MusicTrack>>{};
    for (final track in List<MusicTrack>.of(service.library)) {
      final target = audioDetailTargetForTrack(track);
      final key = <String>[
        target.targetType.dbValue,
        PathMatcher.equivalenceKey(target.targetPath),
      ].join('|');
      targetsByKey.putIfAbsent(key, () => target);
      tracksByTargetKey.putIfAbsent(key, () => <MusicTrack>[]).add(track);
    }
    if (targetsByKey.isEmpty) return;

    final targets = targetsByKey.values.toList(growable: false);
    final loadResults = await detailCacheService.loadMany(targets);
    for (var index = 0; index < targets.length; index++) {
      if (_disposed) return;
      final detail = loadResults[index].detail;
      final key = <String>[
        detail.target.targetType.dbValue,
        PathMatcher.equivalenceKey(detail.target.targetPath),
      ].join('|');
      final targetTracks = tracksByTargetKey[key];
      if (targetTracks == null || targetTracks.isEmpty) continue;
      final hasMissingTrack = targetTracks.any(
        (track) => track.duration <= Duration.zero,
      );
      if (detail.duration != null && !hasMissingTrack) continue;

      final duration = await _calculateDurationForTracks(
        targetTracks,
        durationReader: durationReader,
      );
      if (duration == null || _disposed || detail.duration != null) continue;
      final latestDetail =
          detailCacheService.resolvedDetail(detail.target) ?? detail;
      if (latestDetail.duration == null) {
        await saveAudioDetail(latestDetail.copyWith(duration: duration));
      }
    }
  }

  Future<Duration?> calculateMissingLibraryDuration(
    String targetPath, {
    Future<Duration?> Function(String path)? durationReader,
  }) {
    final singleTracks = service.library
        .where(
          (track) =>
              track.isSingle &&
              PathMatcher.equalsNormalized(track.path, targetPath),
        )
        .toList(growable: false);
    final targetTracks = singleTracks.isNotEmpty
        ? singleTracks
        : service.library
              .where(
                (track) =>
                    !track.isSingle &&
                    (PathMatcher.isWithinOrEqual(track.groupKey, targetPath) ||
                        PathMatcher.isWithinOrEqual(track.path, targetPath)),
              )
              .toList(growable: false);
    return _calculateDurationForTracks(
      targetTracks,
      durationReader: durationReader,
    );
  }

  Future<Duration?> _calculateDurationForTracks(
    List<MusicTrack> targetTracks, {
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    if (targetTracks.isEmpty) return null;

    final tracksToUpdate = <MusicTrack>[];
    var totalDuration = Duration.zero;
    var hasUnknownDuration = false;
    final missingTracks = <MusicTrack>[];
    for (final track in targetTracks) {
      if (track.duration > Duration.zero) {
        totalDuration += track.duration;
      } else {
        missingTracks.add(track);
      }
    }

    Future<Duration?> resolveDuration(MusicTrack track) async {
      try {
        if (durationReader != null) return durationReader(track.path);
        final nativeDuration = await FileCachePlatformGateway.instance
            .resolveMediaDuration(track.path);
        if (nativeDuration != null && nativeDuration > Duration.zero) {
          return nativeDuration;
        }
        if (!PathMatcher.isContentUri(track.path) &&
            !PathMatcher.isRemoteUri(track.path) &&
            !await File(track.path).exists()) {
          return null;
        }
        final player = AudioPlayer();
        try {
          return await _readLocalMediaDuration(player, track.path);
        } finally {
          await player.dispose();
        }
      } catch (error, stackTrace) {
        AppLogService.warning(
          'library_duration_probe_failed path=${track.path}',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }

    const concurrency = 2;
    for (var start = 0; start < missingTracks.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, missingTracks.length);
      final chunk = missingTracks.sublist(start, end);
      final durations = await Future.wait(chunk.map(resolveDuration));
      for (var index = 0; index < chunk.length; index++) {
        final track = chunk[index];
        final duration = durations[index] ?? Duration.zero;
        if (duration > Duration.zero) {
          totalDuration += duration;
          tracksToUpdate.add(track.copyWith(duration: duration));
        } else {
          hasUnknownDuration = true;
          AppLogService.warning(
            'library_duration_unresolved path=${track.path} video=${track.isVideo}',
          );
        }
      }
    }

    if (tracksToUpdate.isNotEmpty) {
      for (final track in tracksToUpdate) {
        final index = service.libraryIndexByPath[track.path];
        if (index != null) service.library[index] = track;
        service.libraryByPath[track.path] = track;
      }
      await databaseRepository.upsertTracks(tracksToUpdate);
      service.rebuildLibraryIndexes();
      snapshotCacheService.markStructureChanged();
      _syncStateSlice();
    }

    return !hasUnknownDuration && totalDuration > Duration.zero
        ? totalDuration
        : null;
  }

  DlsiteMetadataQuery buildDlsiteMetadataQuery(AudioDetail detail) =>
      DlsiteMetadataQuery.fromDetail(detail);

  Future<DlsiteMetadata> fetchPreferredMetadata(
    String rjCode, {
    required AppLanguage language,
  }) async {
    DlsiteMetadata? primary;
    try {
      primary = await asmrMetadataService.fetchByRjCode(
        rjCode,
        language: language,
      );
    } catch (_) {
      return metadataService.fetchByRjCode(rjCode, language: language);
    }
    if (!_metadataHasMissingValue(primary)) return primary;
    try {
      final fallback = await metadataService.fetchByRjCode(
        rjCode,
        language: language,
      );
      return _mergeMetadata(primary, fallback);
    } catch (_) {
      return primary;
    }
  }

  Future<List<DlsiteMetadata>> searchPreferredMetadataByTitles(
    Iterable<String> titles, {
    required AppLanguage language,
  }) async {
    List<DlsiteMetadata> primary;
    try {
      primary = await asmrMetadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
    } catch (_) {
      return metadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
    }
    if (primary.every((metadata) => !_metadataHasMissingValue(metadata))) {
      return primary;
    }
    try {
      final fallback = await metadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
      final fallbackByKey = <String, DlsiteMetadata>{};
      for (final metadata in fallback) {
        final key = _metadataMergeKey(metadata);
        if (key.isNotEmpty) fallbackByKey.putIfAbsent(key, () => metadata);
      }
      final singleFallback = primary.length == 1 && fallback.length == 1
          ? fallback.single
          : null;
      return primary
          .map((metadata) {
            final match =
                fallbackByKey[_metadataMergeKey(metadata)] ?? singleFallback;
            return match == null ? metadata : _mergeMetadata(metadata, match);
          })
          .toList(growable: false);
    } catch (_) {
      return primary;
    }
  }

  bool _metadataHasMissingValue(DlsiteMetadata metadata) {
    return metadata.rjCode.trim().isEmpty ||
        metadata.workTitle.trim().isEmpty ||
        metadata.circleName.trim().isEmpty ||
        metadata.voiceActors.isEmpty ||
        metadata.tags.isEmpty ||
        metadata.releaseDate == null ||
        metadata.duration == null ||
        metadata.salesCount == null ||
        metadata.rating == null;
  }

  String _metadataMergeKey(DlsiteMetadata metadata) {
    final rjCode = metadata.rjCode.trim().toUpperCase();
    if (rjCode.isNotEmpty) return 'rj:$rjCode';
    final title = metadata.workTitle.trim().toLowerCase();
    return title.isEmpty ? '' : 'title:$title';
  }

  DlsiteMetadata _mergeMetadata(
    DlsiteMetadata primary,
    DlsiteMetadata fallback,
  ) {
    String fallbackString(String value, String fallbackValue) {
      return value.trim().isNotEmpty ? value : fallbackValue;
    }

    String? fallbackNullableString(String? value, String? fallbackValue) {
      return value != null && value.trim().isNotEmpty ? value : fallbackValue;
    }

    return primary.copyWith(
      rjCode: fallbackString(primary.rjCode, fallback.rjCode),
      workTitle: fallbackString(primary.workTitle, fallback.workTitle),
      circleName: fallbackString(primary.circleName, fallback.circleName),
      voiceActors: primary.voiceActors.isNotEmpty
          ? primary.voiceActors
          : fallback.voiceActors,
      tags: primary.tags.isNotEmpty ? primary.tags : fallback.tags,
      releaseDate: primary.releaseDate ?? fallback.releaseDate,
      duration: primary.duration ?? fallback.duration,
      salesCount: primary.salesCount ?? fallback.salesCount,
      rating: primary.rating ?? fallback.rating,
      coverUrl: fallbackNullableString(primary.coverUrl, fallback.coverUrl),
    );
  }

  AudioDetail? resolvedAudioDetail(AudioDetailTarget target) =>
      detailCacheService.resolvedDetail(target);
  @override
  MusicTrack? trackByPath(String trackPath) => service.trackByPath(trackPath);
  String? resolvedCoverPathForTrack(MusicTrack? track, {String? trackPath}) =>
      coverArtworkCacheService.resolvedForTrack(track, trackPath: trackPath);
  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => coverArtworkCacheService.resolvedForPlaybackTrack(
    track,
    trackPath: trackPath,
  );
  String? resolvedCoverPathForRemoteCover(String url) =>
      coverArtworkCacheService.resolvedForRemoteCover(url);
  String? resolvedCoverPathForFolder(String folderPath) =>
      coverArtworkCacheService.resolvedForFolder(folderPath);
  Future<String?> coverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => coverArtworkCacheService.futureForTrack(track, trackPath: trackPath);
  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => coverArtworkCacheService.futureForPlaybackTrack(
    track,
    trackPath: trackPath,
  );
  Future<String?> coverPathFutureForFolder(String folderPath) =>
      coverArtworkCacheService.futureForFolder(folderPath);
  Future<String?> coverPathFutureForRemoteCover(String url) =>
      coverArtworkCacheService.futureForRemoteCover(url);
  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
  }) => coverArtworkCacheService.discoverCoverCandidatesInFolder(
    folderPath,
    selectedCoverPath: selectedCoverPath,
  );

  Future<String?> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
  }) async {
    final storedCoverPath = await coverArtworkCacheService
        .setFolderCoverSelection(folderPath, imagePath, newlySaved: newlySaved);
    _coverChangeHandler?.call();
    return storedCoverPath;
  }

  Future<DlsiteMetadataApplyResult> applyDlsiteMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
    required AppLanguage language,
    bool missingOnly = false,
  }) async {
    String metadataStringValue(String current, String fetched) {
      return missingOnly && current.trim().isNotEmpty ? current : fetched;
    }

    List<String> metadataListValue(List<String> current, List<String> fetched) {
      return missingOnly && current.isNotEmpty ? current : fetched;
    }

    final nextDetail = detail.copyWith(
      rjCode: metadataStringValue(detail.rjCode, metadata.rjCode),
      workTitle: metadataStringValue(detail.workTitle, metadata.workTitle),
      circleName: metadataStringValue(detail.circleName, metadata.circleName),
      voiceActors: metadataListValue(detail.voiceActors, metadata.voiceActors),
      tags: metadataListValue(detail.tags, metadata.tags),
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
    final saveResult = await saveAudioDetail(nextDetail);

    String? coverPath;
    Object? coverError;
    final coverUrl = metadata.coverUrl;
    if (saveCover &&
        nextDetail.target.isLibraryRootFolder &&
        coverUrl != null) {
      try {
        coverPath = await metadataService.downloadCover(
          coverUrl: coverUrl,
          folderPath: nextDetail.target.targetPath,
          rjCode: metadata.rjCode,
          language: language,
        );
        await setFolderManualCover(
          nextDetail.target.targetPath,
          coverPath,
          newlySaved: true,
        );
      } catch (error) {
        coverError = error;
      }
    }

    return DlsiteMetadataApplyResult(
      detail: saveResult.detail,
      coverPath: coverPath,
      coverError: coverError,
    );
  }

  void warmupCoversForTracks(Iterable<MusicTrack?> tracks) {
    final generation = _coverWarmupScheduler.currentGeneration;
    final scheduledKeys = <String>{};
    var priority = 0;
    for (final track in tracks) {
      if (track == null || track.isVideo) continue;
      if (resolvedCoverPathForTrack(track) != null) continue;
      final coverSearchKey = coverArtworkCacheService.coverSearchKeyForTrack(
        track,
      );
      if (coverSearchKey == null || !scheduledKeys.add(coverSearchKey)) {
        continue;
      }
      _coverWarmupScheduler.schedule(
        key: 'library_track_cover:$coverSearchKey',
        priority: priority++,
        generation: generation,
        group: 'library_cover',
        task: () async {
          if (resolvedCoverPathForTrack(track) == null) {
            await coverPathFutureForTrack(track);
          }
        },
      );
    }
  }

  void _handleWarmupInteractionChanged() {
    _coverWarmupScheduler.setPaused(
      UiInteractionCoordinator.instance.isInteracting,
    );
  }

  String? libraryEntryDisplayNameForPath(
    String libraryPath,
    String entryPath,
  ) => service.libraryEntryDisplayNameForPath(libraryPath, entryPath);
  List<String> excludedTracksForLibrary(String libraryPath) =>
      service.excludedTracksForLibrary(libraryPath);
  List<String> excludedFoldersForLibrary(String libraryPath) =>
      service.excludedFoldersForLibrary(libraryPath);
  List<String> childFoldersForLibrary(String libraryPath) =>
      service.childFoldersForLibrary(libraryPath);
  @override
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      service.libraryEntriesForLibrary(libraryPath);
  @override
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) =>
      service.libraryEntrySnapshotForLibrary(libraryPath);
  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) => service.libraryExclusionMatcherForLibrary(libraryPath);
  @override
  bool hasLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return (service.excludedLibraryFolders[normalizedLibraryPath]?.isNotEmpty ??
            false) ||
        (service.excludedLibraryTracks[normalizedLibraryPath]?.isNotEmpty ??
            false);
  }

  bool isLibraryTrackExplicitlyExcluded(String libraryPath, String trackPath) =>
      service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath);
  bool isLibraryFolderExplicitlyExcluded(
    String libraryPath,
    String folderPath,
  ) => service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath);
  @override
  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      service.isLibraryPathExcluded(libraryPath, entityPath);
  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) =>
      service.isLibraryPathInheritedExcluded(libraryPath, entityPath);

  @override
  bool isScanGenerationActive(int generation) =>
      service.isScanning &&
      generation != 0 &&
      generation == service.scanGeneration;

  @override
  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = service.addWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  @override
  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = service.addWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  @override
  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = service.removeWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = service.removeWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  Future<void> _saveWatchedFolders() async {
    await AppPreferences.setString(
      _watchedFoldersPreferenceKey,
      json.encode(service.watchedFolders),
    );
  }

  Future<void> _saveWatchedLibraries() async {
    await AppPreferences.setString(
      _watchedLibrariesPreferenceKey,
      json.encode(service.watchedLibraries),
    );
  }

  void reorderLibraryNodes(int oldIndex, int newIndex) {
    service.reorderLibraryNodes(
      oldIndex,
      newIndex,
      currentTree: libraryCards,
      onPersist: () => unawaited(_saveLibraryNodeOrder()),
    );
    snapshotCacheService.applyCurrentTopLevelOrder();
    _syncStateSlice();
  }

  Future<void> _saveLibraryNodeOrder() {
    return AppPreferences.setString(
      _libraryNodeOrderPreferenceKey,
      json.encode(service.libraryNodeOrder),
    );
  }

  void configurePersistence({required bool enabled}) {
    _persistenceEnabled = enabled;
  }

  void attachTrackRemovalHandler(
    void Function(List<String> removedPaths) handler,
  ) {
    _trackRemovalHandler ??= handler;
  }

  void attachCoverChangeHandler(void Function() handler) {
    _coverChangeHandler ??= handler;
  }

  @override
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {
    var entries = service.buildLibraryEntries(
      libraryPath,
      tracks,
      folderPaths: folderPaths,
      exclusionMatcher: exclusionMatcher,
    );
    if (entrySnapshot != null) {
      entries = entries
          .where(entrySnapshot.entryNeedsRefresh)
          .toList(growable: false);
    }
    if (entries.isEmpty) return;
    service.replaceLibraryEntries(entries);
    entrySnapshot?.remember(entries);
    _queueOrPersistLibraryEntries(entries, persist: persist);
  }

  void recordEntriesForTracks(List<MusicTrack> tracks, {bool persist = true}) {
    final entries = <LibraryEntry>[];
    final tracksByLibrary = <String, List<MusicTrack>>{};
    for (final track in tracks) {
      final libraryPath = service.libraryPathForTrack(track);
      if (libraryPath == null || libraryPath.isEmpty) continue;
      tracksByLibrary.putIfAbsent(libraryPath, () => <MusicTrack>[]).add(track);
    }
    for (final entry in tracksByLibrary.entries) {
      entries.addAll(service.buildLibraryEntries(entry.key, entry.value));
    }
    if (entries.isEmpty) return;
    service.replaceLibraryEntries(entries);
    _queueOrPersistLibraryEntries(entries, persist: persist);
  }

  @override
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = service.addTracks(tracks, persist: persist);
    if (mutation.tracks.isEmpty) return;
    recordEntriesForTracks(mutation.tracks, persist: persist);
    if (mutation.batched) return;
    _markLibraryStructureChanged();
    if (persist && _persistenceEnabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder) unawaited(_saveGroupOrder());
      unawaited(_saveLibraryNodeOrder());
    }
  }

  @override
  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = service.addOrReplaceTracks(tracks, persist: persist);
    if (mutation.tracks.isEmpty) return;
    recordEntriesForTracks(mutation.tracks, persist: persist);
    if (mutation.batched) return;
    _markLibraryStructureChanged();
    if (persist && _persistenceEnabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder || mutation.didReplaceGroup) {
        unawaited(_saveGroupOrder());
      }
      unawaited(_saveLibraryNodeOrder());
    }
  }

  void _markLibraryStructureChanged() {
    _coverArtworkCacheService?.invalidateAll();
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
  }

  List<String> removeTracksMatching(bool Function(MusicTrack track) test) {
    final mutation = service.removeTracksWhere(test);
    final removedPaths = mutation.tracks
        .map((track) => track.path)
        .toList(growable: false);
    if (removedPaths.isEmpty) return const <String>[];
    _trackRemovalHandler?.call(removedPaths);
    if (_persistenceEnabled) {
      unawaited(databaseRepository.deleteTracks(removedPaths));
    }
    if (!mutation.batched) {
      _markLibraryStructureChanged();
      if (_persistenceEnabled) unawaited(_saveLibraryNodeOrder());
    }
    return removedPaths;
  }

  @override
  void removeTracksByPath(Iterable<String> trackPaths) {
    final paths = trackPaths.toSet();
    if (paths.isEmpty) return;
    removeTracksMatching((track) => paths.contains(track.path));
  }

  @override
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final scannedPathIndex = PathMembershipIndex(scannedPaths);
    removeTracksMatching((track) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        track.path,
        normalizedFolder,
      )) {
        return false;
      }
      return !scannedPathIndex.containsEquivalent(track.path);
    });
  }

  @override
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {
    final removedPaths = service.removeLibraryEntriesMissingFromFolderScan(
      libraryPath,
      folderPath,
      retainedPaths,
    );
    if (removedPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  @override
  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {
    final removedPaths = service.removeLibraryEntriesByPaths(
      libraryPath,
      entryPaths,
    );
    if (removedPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  @override
  void clearLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final removedFolders = service.excludedLibraryFolders.remove(
      normalizedLibraryPath,
    );
    final removedTracks = service.excludedLibraryTracks.remove(
      normalizedLibraryPath,
    );
    if ((removedFolders == null || removedFolders.isEmpty) &&
        (removedTracks == null || removedTracks.isEmpty)) {
      return;
    }

    final restoredEntryPaths = service.setLibraryEntriesSubtreeState(
      normalizedLibraryPath,
      normalizedLibraryPath,
      LibraryEntryState.active,
    );
    final restoredTracks = service
        .libraryEntriesForLibrary(normalizedLibraryPath)
        .where(
          (entry) =>
              entry.isTrack && !service.libraryByPath.containsKey(entry.path),
        )
        .map((entry) => entry.toTrack())
        .toList(growable: false);
    if (restoredTracks.isNotEmpty) {
      addOrReplaceTracks(restoredTracks, notify: false);
    } else {
      _syncStateSlice();
    }
    if (_persistenceEnabled) {
      if (restoredEntryPaths.isNotEmpty) {
        unawaited(
          databaseRepository.setLibraryEntriesState(
            normalizedLibraryPath,
            restoredEntryPaths,
            LibraryEntryState.active,
          ),
        );
      }
      unawaited(_saveLibraryExclusions());
    }
  }

  Future<void> removeTrackFromLibrary(String trackPath) async {
    final removedTrack = service.trackByPath(trackPath);
    if (removedTrack == null) return;
    final removedPaths = removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
    );
    if (removedPaths.isEmpty) return;
    service.syncGroupOrderFromLibrary();
    if (_persistenceEnabled) {
      unawaited(_saveGroupOrder());
    }
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final wasWatched = service.watchedFolders.any(
      (folder) => PathMatcher.equalsNormalized(folder, normalizedFolderPath),
    );
    final removedPaths = removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
    );
    if (removedPaths.isEmpty && !wasWatched) return;

    await deleteAudioDetail(
      AudioDetailTarget.libraryRootFolder(normalizedFolderPath),
    );
    service
      ..removeWatchedFolder(
        normalizedFolderPath,
        onPersist: () => unawaited(_saveWatchedFolders()),
      )
      ..libraryEntriesByLibrary.remove(normalizedFolderPath)
      ..syncGroupOrderFromLibrary()
      ..syncLibraryNodeOrder(persist: false);
    _markLibraryStructureChanged();
    if (_persistenceEnabled) {
      await databaseRepository.deleteLibraryEntriesForLibrary(folderPath);
      unawaited(_saveGroupOrder());
      unawaited(_saveLibraryNodeOrder());
    }
  }

  Future<void> removeLibrary(String libraryPath) async {
    if (isScanning) cancelScan();
    await service.removeLibrary(
      libraryPath,
      removeFolder: removeFolderFromLibrary,
      onSaveWatchedLibraries: () {
        if (_persistenceEnabled) unawaited(_saveWatchedLibraries());
      },
      onSaveLibraryExclusions: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    await removeFolderFromLibrary(libraryPath);
    if (_persistenceEnabled) {
      unawaited(databaseRepository.deleteLibraryEntriesForLibrary(libraryPath));
    }
    _syncStateSlice();
  }

  void excludeLibraryFolder(String libraryPath, String folderPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final changed = service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      true,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!changed) return;
    final affectedEntryPaths = service
        .libraryEntriesForLibrary(normalizedLibraryPath)
        .where(
          (entry) =>
              PathMatcher.isWithinOrEqual(entry.path, normalizedFolderPath),
        )
        .map((entry) => entry.path)
        .toList(growable: false);
    if (affectedEntryPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
      );
    }
    removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
    );
    _syncStateSlice();
  }

  void excludeLibraryTrack(String libraryPath, String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final changed = service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      true,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!changed) return;
    if (service
        .libraryEntriesForLibrary(libraryPath)
        .any(
          (entry) =>
              PathMatcher.equalsNormalized(entry.path, normalizedTrackPath),
        )) {
      if (_persistenceEnabled) {
        unawaited(
          databaseRepository.setLibraryEntriesState(libraryPath, <String>[
            normalizedTrackPath,
          ], LibraryEntryState.excluded),
        );
      }
    }
    removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, normalizedTrackPath),
    );
    _syncStateSlice();
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    if (excluded) {
      excludeLibraryFolder(libraryPath, folderPath);
      return;
    }
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final changed = service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      false,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!changed) return;
    final affectedPaths = service
        .libraryEntriesForLibrary(normalizedLibraryPath)
        .where(
          (entry) =>
              PathMatcher.isWithinOrEqual(entry.path, normalizedFolderPath),
        )
        .map((entry) => entry.path)
        .toList(growable: false);
    if (affectedPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          affectedPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(
      _restoreExcludedFolder(normalizedLibraryPath, normalizedFolderPath),
    );
    _syncStateSlice();
  }

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) {
    if (excluded) {
      excludeLibraryTrack(libraryPath, trackPath);
      return;
    }
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final changed = service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      false,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!changed) return;
    if (_persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(libraryPath, <String>[
          normalizedTrackPath,
        ], LibraryEntryState.active),
      );
    }
    unawaited(_restoreExcludedTrack(libraryPath, normalizedTrackPath));
    _syncStateSlice();
  }

  Future<void> _restoreExcludedTrack(
    String libraryPath,
    String trackPath,
  ) async {
    if (service.libraryByPath.containsKey(trackPath)) return;
    for (final entry in service.libraryEntriesForLibrary(libraryPath)) {
      if (entry.isTrack &&
          PathMatcher.equalsNormalized(entry.path, trackPath)) {
        addTracks(<MusicTrack>[entry.toTrack()], notify: false);
        return;
      }
    }
    final isContentUri = PathMatcher.isContentUri(trackPath);
    FileStat? stat;
    if (!isContentUri) {
      try {
        final file = File(trackPath);
        if (!await file.exists()) return;
        stat = await file.stat();
      } catch (_) {
        return;
      }
    }
    final parentFolder = path.dirname(trackPath);
    final folderName = path.basename(parentFolder);
    addTracks(<MusicTrack>[
      MusicTrack(
        path: trackPath,
        displayName: PathDisplay.fileName(trackPath, withoutExtension: true),
        groupKey: parentFolder,
        groupTitle: folderName.isEmpty
            ? PathDisplay.folderName(parentFolder)
            : PathDisplay.normalizeDisplaySegment(folderName),
        groupSubtitle: parentFolder,
        isSingle: false,
        isVideo: isVideoMediaFile(trackPath),
        scannedAt: DateTime.now(),
        fileSizeBytes: stat?.size,
        modifiedAt: stat?.modified,
      ),
    ], notify: false);
  }

  Future<void> _restoreExcludedFolder(
    String libraryPath,
    String folderPath,
  ) async {
    final persistedTracks = service
        .libraryEntriesForLibrary(libraryPath)
        .where(
          (entry) =>
              entry.isTrack &&
              entry.isActive &&
              PathMatcher.isWithinOrEqual(entry.path, folderPath) &&
              !service.isLibraryPathExcluded(libraryPath, entry.path),
        )
        .map((entry) => entry.toTrack())
        .where((track) => !service.libraryByPath.containsKey(track.path))
        .toList(growable: false);
    if (persistedTracks.isNotEmpty) {
      addOrReplaceTracks(persistedTracks, notify: false);
      return;
    }

    final restoredTracks = PathMatcher.isContentUri(folderPath)
        ? await _scanRestorableContentTracks(folderPath)
        : await _scanRestorableFileTracks(folderPath);
    final candidates = restoredTracks
        .where(
          (track) => !service.isLibraryPathExcluded(libraryPath, track.path),
        )
        .toList(growable: false);
    if (candidates.isNotEmpty) {
      addOrReplaceTracks(candidates, notify: false);
    }
  }

  Future<List<MusicTrack>> _scanRestorableFileTracks(String folderPath) async {
    final directory = Directory(folderPath);
    if (!await directory.exists()) return const <MusicTrack>[];
    final pendingDirectories = <Directory>[directory];
    final restoredTracks = <MusicTrack>[];
    while (pendingDirectories.isNotEmpty) {
      final currentDirectory = pendingDirectories.removeLast();
      late final Stream<FileSystemEntity> entities;
      try {
        entities = currentDirectory.list(followLinks: false);
      } catch (_) {
        continue;
      }
      await for (final entity in entities.handleError((_) {})) {
        if (entity is Directory) {
          pendingDirectories.add(entity);
          continue;
        }
        if (entity is! File) continue;
        final mediaPath = path.normalize(entity.path);
        if (!isSupportedMediaFile(mediaPath) ||
            service.libraryByPath.containsKey(mediaPath)) {
          continue;
        }
        FileStat? stat;
        try {
          stat = await entity.stat();
        } catch (_) {
          // File metadata is optional for restored library entries.
        }
        final parentFolder = path.dirname(mediaPath);
        final folderName = path.basename(parentFolder);
        restoredTracks.add(
          MusicTrack(
            path: mediaPath,
            displayName: path.basenameWithoutExtension(mediaPath),
            groupKey: parentFolder,
            groupTitle: folderName.isEmpty ? parentFolder : folderName,
            groupSubtitle: parentFolder,
            isSingle: false,
            isVideo: isVideoMediaFile(mediaPath),
            scannedAt: DateTime.now(),
            fileSizeBytes: stat?.size,
            modifiedAt: stat?.modified,
          ),
        );
      }
    }
    return restoredTracks;
  }

  Future<List<MusicTrack>> _scanRestorableContentTracks(
    String folderPath,
  ) async {
    try {
      final data = await FileCachePlatformGateway.instance.scanFolderPayload(
        folderPath,
      );
      if (data == null) return const <MusicTrack>[];
      final tracks = <MusicTrack>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final rawPath = map['path']?.toString().trim();
        if (rawPath == null ||
            rawPath.isEmpty ||
            !isSupportedMediaFile(rawPath) ||
            service.libraryByPath.containsKey(rawPath)) {
          continue;
        }
        final mediaPath = PathMatcher.isContentUri(rawPath)
            ? rawPath
            : path.normalize(rawPath);
        final nativeGroupKey = map['groupKey']?.toString().trim();
        final nativeGroupTitle = map['groupTitle']?.toString().trim();
        final nativeGroupSubtitle = map['groupSubtitle']?.toString().trim();
        final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
            ? nativeGroupKey!
            : path.dirname(mediaPath);
        final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
            ? nativeGroupTitle!
            : PathDisplay.folderName(groupKey);
        final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
            ? nativeGroupSubtitle!
            : groupKey;
        final displayName = map['title']?.toString().trim();
        final scannedAtMs = map['scannedAtMs'] as num?;
        final modifiedAtMs = map['modifiedAtMs'] as num?;
        tracks.add(
          MusicTrack(
            path: mediaPath,
            displayName: displayName?.isEmpty ?? true
                ? PathDisplay.fileName(mediaPath, withoutExtension: true)
                : displayName!,
            groupKey: groupKey,
            groupTitle: groupTitle,
            groupSubtitle: groupSubtitle,
            isSingle: false,
            isVideo: map['isVideo'] as bool? ?? isVideoMediaFile(mediaPath),
            scannedAt: scannedAtMs == null
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
            fileSizeBytes: (map['fileSizeBytes'] as num?)?.toInt(),
            modifiedAt: modifiedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
          ),
        );
      }
      return tracks;
    } catch (_) {
      return const <MusicTrack>[];
    }
  }

  Future<AudioDetailRenameResult> renameAudioDetailTarget(
    AudioDetail detail,
  ) async {
    return renameAudioDetailTargetToName(detail, detail.workTitle);
  }

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final name = targetName.trim();
    if (name.isEmpty) {
      throw const AudioDetailRenameException('missingTitle');
    }
    final oldTarget = detail.target;

    final safeName = _safeFileName(name);
    if (safeName.isEmpty) {
      throw const AudioDetailRenameException('invalidTitle');
    }

    final oldPath = PathMatcher.normalize(oldTarget.targetPath);
    final newPath = PathMatcher.isContentUri(oldPath)
        ? await _renameContentAudioDetailTarget(oldTarget, safeName)
        : await _renameFileSystemAudioDetailTarget(
            oldTarget,
            oldPath,
            safeName,
          );
    if (PathMatcher.equalsNormalized(oldPath, newPath)) {
      return AudioDetailRenameResult(detail: detail, renamed: false);
    }

    final newTarget = AudioDetailTarget(
      targetType: oldTarget.targetType,
      targetPath: newPath,
    );
    if (oldTarget.isLibraryRootFolder) {
      await _retargetLibraryFolder(oldPath, newPath, safeName);
    } else {
      await _retargetSingleTrack(oldPath, newPath, safeName);
    }

    final renamedDetail = detail.copyWith(
      target: newTarget,
      cardCoverPath: _retargetNullablePath(
        detail.cardCoverPath,
        oldPath,
        newPath,
      ),
    );
    final saveResult = await saveAudioDetail(renamedDetail);
    await deleteAudioDetail(oldTarget);
    return AudioDetailRenameResult(
      detail: saveResult.detail,
      renamed: true,
      backupFailed: saveResult.backupFailed,
    );
  }

  Future<String> _renameFileSystemAudioDetailTarget(
    AudioDetailTarget oldTarget,
    String oldPath,
    String safeName,
  ) async {
    final newPath = oldTarget.isLibraryRootFolder
        ? path.join(path.dirname(oldPath), safeName)
        : path.join(
            path.dirname(oldPath),
            '$safeName${path.extension(oldPath)}',
          );
    if (PathMatcher.equalsNormalized(oldPath, newPath)) return newPath;
    if (oldTarget.isLibraryRootFolder) {
      await _retryWindowsRename(() async {
        await Directory(oldPath).rename(newPath);
      });
    } else {
      await _retryWindowsRename(() async {
        await File(oldPath).rename(newPath);
      });
    }
    return newPath;
  }

  Future<void> _retryWindowsRename(Future<void> Function() operation) async {
    const retryDelays = <Duration>[
      Duration(milliseconds: 40),
      Duration(milliseconds: 80),
    ];
    for (var attempt = 0; ; attempt++) {
      try {
        await operation();
        return;
      } on PathAccessException {
        if (!Platform.isWindows || attempt >= retryDelays.length) rethrow;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  Future<String> _renameContentAudioDetailTarget(
    AudioDetailTarget oldTarget,
    String safeName,
  ) async {
    final name = oldTarget.isLibraryRootFolder
        ? safeName
        : '$safeName${_contentFileExtension(oldTarget.targetPath)}';
    // If the document already has this name, skip the rename to avoid
    // provider errors on some Android versions when the name is unchanged.
    final currentName = PathMatcher.lastContentPathSegment(
      oldTarget.targetPath,
    );
    if (currentName != null) {
      final decodedCurrent = PathMatcher.safeDecodeComponent(currentName);
      if (decodedCurrent == name) return oldTarget.targetPath;
    }
    final raw = await FileCachePlatformGateway.instance.renameDocument(
      path: oldTarget.targetPath,
      name: name,
    );
    final renamedPath = raw?['path'] as String?;
    if (renamedPath == null || renamedPath.isEmpty) {
      throw const AudioDetailRenameException('renameFailed');
    }
    return renamedPath;
  }

  String _contentFileExtension(String targetPath) {
    final segment = PathMatcher.lastContentPathSegment(targetPath);
    final decoded = segment == null
        ? targetPath
        : PathMatcher.safeDecodeComponent(segment).replaceAll('\\', '/');
    return path.extension(decoded);
  }

  Future<void> _retargetLibraryFolder(
    String oldFolderPath,
    String newFolderPath,
    String folderName,
  ) async {
    await coverArtworkCacheService.retargetFolderCoverSelection(
      oldFolderPath,
      newFolderPath,
    );
    await databaseRepository.retargetTimeSegmentLabelsWithinPath(
      oldRoot: oldFolderPath,
      newRoot: newFolderPath,
    );
    final retargetedTracks = <String, MusicTrack>{};
    for (var i = 0; i < service.library.length; i++) {
      final track = service.library[i];
      if (!PathMatcher.isWithinOrEqual(track.path, oldFolderPath)) continue;

      final nextTrackPath = _replacePathPrefix(
        track.path,
        oldFolderPath,
        newFolderPath,
      );
      final nextGroupKey =
          PathMatcher.isWithinOrEqual(track.groupKey, oldFolderPath)
          ? _replacePathPrefix(track.groupKey, oldFolderPath, newFolderPath)
          : track.groupKey;
      final updatedTrack = _copyTrack(
        track,
        path: nextTrackPath,
        groupKey: nextGroupKey,
        groupTitle: PathMatcher.equalsNormalized(nextGroupKey, newFolderPath)
            ? folderName
            : PathDisplay.folderName(nextGroupKey),
        groupSubtitle: PathDisplay.displayPathFor(nextGroupKey),
        coverCachePath: _retargetNullablePath(
          track.coverCachePath,
          oldFolderPath,
          newFolderPath,
        ),
        lyricsPath: _retargetNullablePath(
          track.lyricsPath,
          oldFolderPath,
          newFolderPath,
        ),
        manualCoverPath: _retargetNullablePath(
          track.manualCoverPath,
          oldFolderPath,
          newFolderPath,
        ),
      );
      service.library[i] = updatedTrack;
      retargetedTracks[track.path] = updatedTrack;
    }

    for (var i = 0; i < service.watchedFolders.length; i++) {
      if (PathMatcher.equalsNormalized(
        service.watchedFolders[i],
        oldFolderPath,
      )) {
        service.watchedFolders[i] = newFolderPath;
      }
    }
    for (var i = 0; i < service.watchedLibraries.length; i++) {
      if (PathMatcher.equalsNormalized(
        service.watchedLibraries[i],
        oldFolderPath,
      )) {
        service.watchedLibraries[i] = newFolderPath;
      }
    }

    for (var i = 0; i < service.libraryNodeOrder.length; i++) {
      if (PathMatcher.equalsNormalized(
        service.libraryNodeOrder[i],
        oldFolderPath,
      )) {
        service.libraryNodeOrder[i] = newFolderPath;
      }
    }

    for (var i = 0; i < service.groupOrder.length; i++) {
      if (PathMatcher.isWithinOrEqual(service.groupOrder[i], oldFolderPath)) {
        service.groupOrder[i] = _replacePathPrefix(
          service.groupOrder[i],
          oldFolderPath,
          newFolderPath,
        );
      }
    }

    _retargetLibraryExclusions(oldFolderPath, newFolderPath);
    final retargetedEntries = _retargetLibraryEntries(
      oldFolderPath,
      newFolderPath,
      folderName,
    );
    coverArtworkCacheService.invalidateFolders([oldFolderPath, newFolderPath]);
    service.syncGroupOrderFromLibrary();
    service.rebuildLibraryIndexes();
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    await databaseRepository.replaceTrackPaths(retargetedTracks);
    await databaseRepository.deleteLibraryEntriesForLibrary(oldFolderPath);
    if (retargetedEntries.isNotEmpty) {
      await databaseRepository.upsertLibraryEntries(retargetedEntries);
    }
    await _saveWatchedFolders();
    await _saveWatchedLibraries();
    await _saveLibraryExclusions();
    await _saveGroupOrder();
    await _saveLibraryNodeOrder();
  }

  void _retargetLibraryExclusions(String oldRoot, String newRoot) {
    if (service.excludedLibraryFolders.isEmpty &&
        service.excludedLibraryTracks.isEmpty) {
      return;
    }

    Map<String, Set<String>> retarget(Map<String, Set<String>> source) {
      final result = <String, Set<String>>{};
      for (final entry in source.entries) {
        final nextKey = PathMatcher.equalsNormalized(entry.key, oldRoot)
            ? newRoot
            : entry.key;
        final nextValues = entry.value
            .map(
              (value) => PathMatcher.isWithinOrEqual(value, oldRoot)
                  ? _replacePathPrefix(value, oldRoot, newRoot)
                  : value,
            )
            .toSet();
        result.putIfAbsent(nextKey, () => <String>{}).addAll(nextValues);
      }
      return result;
    }

    final nextFolderExclusions = retarget(service.excludedLibraryFolders);
    final nextTrackExclusions = retarget(service.excludedLibraryTracks);
    service.excludedLibraryFolders
      ..clear()
      ..addAll(nextFolderExclusions);
    service.excludedLibraryTracks
      ..clear()
      ..addAll(nextTrackExclusions);
  }

  List<LibraryEntry> _retargetLibraryEntries(
    String oldRoot,
    String newRoot,
    String folderName,
  ) {
    final existingEntries = service.libraryEntriesByLibrary.remove(oldRoot);
    if (existingEntries == null || existingEntries.isEmpty) {
      return const <LibraryEntry>[];
    }

    final retargetedEntries = existingEntries.values
        .map(
          (entry) => _retargetLibraryEntry(
            entry,
            oldRoot: oldRoot,
            newRoot: newRoot,
            folderName: folderName,
          ),
        )
        .toList(growable: false);
    service.libraryEntriesByLibrary[newRoot] = {
      for (final entry in retargetedEntries) entry.path: entry,
    };
    service.markStructureChanged();
    snapshotCacheService.markStructureChanged();
    return retargetedEntries;
  }

  LibraryEntry _retargetLibraryEntry(
    LibraryEntry entry, {
    required String oldRoot,
    required String newRoot,
    required String folderName,
  }) {
    final nextPath = PathMatcher.isWithinOrEqual(entry.path, oldRoot)
        ? _replacePathPrefix(entry.path, oldRoot, newRoot)
        : entry.path;
    final nextParentPath =
        entry.parentPath != null &&
            PathMatcher.isWithinOrEqual(entry.parentPath!, oldRoot)
        ? _replacePathPrefix(entry.parentPath!, oldRoot, newRoot)
        : entry.parentPath;
    if (entry.isFolder) {
      return LibraryEntry.folder(
        libraryPath: newRoot,
        path: nextPath,
        parentPath: nextParentPath,
        state: entry.state,
        displayName: entry.displayName,
      );
    }

    final nextGroupKey = PathMatcher.isWithinOrEqual(entry.groupKey, oldRoot)
        ? _replacePathPrefix(entry.groupKey, oldRoot, newRoot)
        : entry.groupKey;
    final nextGroupTitle = PathMatcher.equalsNormalized(nextGroupKey, newRoot)
        ? folderName
        : PathDisplay.folderName(nextGroupKey);
    return LibraryEntry(
      libraryPath: newRoot,
      path: nextPath,
      kind: entry.kind,
      state: entry.state,
      parentPath: nextParentPath,
      displayName: entry.displayName,
      groupKey: nextGroupKey,
      groupTitle: nextGroupTitle,
      groupSubtitle: PathDisplay.displayPathFor(nextGroupKey),
      isSingle: entry.isSingle,
      isVideo: entry.isVideo,
      scannedAt: entry.scannedAt,
      fileSizeBytes: entry.fileSizeBytes,
      modifiedAt: entry.modifiedAt,
    );
  }

  Future<void> _retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) async {
    await databaseRepository.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize(oldTrackPath),
      newTrackKey: PathMatcher.normalize(newTrackPath),
    );
    final track = service.libraryByPath[oldTrackPath];
    if (track != null) {
      final updatedTrack = _copyTrack(
        track,
        path: newTrackPath,
        displayName: displayName,
      );
      final index = service.library.indexWhere(
        (item) => item.path == oldTrackPath,
      );
      if (index >= 0) service.library[index] = updatedTrack;
      for (var i = 0; i < service.libraryNodeOrder.length; i++) {
        if (PathMatcher.equalsNormalized(
          service.libraryNodeOrder[i],
          oldTrackPath,
        )) {
          service.libraryNodeOrder[i] = newTrackPath;
        }
      }
      coverArtworkCacheService.invalidateAll();
      service.rebuildLibraryIndexes();
      snapshotCacheService.markStructureChanged();
      _syncStateSlice();
      await databaseRepository.deleteTracks([oldTrackPath]);
      await databaseRepository.upsertTracks([updatedTrack]);
    }
  }

  String? _retargetNullablePath(String? value, String oldRoot, String newRoot) {
    if (value == null || !PathMatcher.isWithinOrEqual(value, oldRoot)) {
      return value;
    }
    return _replacePathPrefix(value, oldRoot, newRoot);
  }

  String _replacePathPrefix(String value, String oldRoot, String newRoot) {
    return PathMatcher.replaceWithinOrEqual(value, oldRoot, newRoot);
  }

  String _safeFileName(String value) {
    return PathDisplay.safeFileName(value);
  }

  MusicTrack _copyTrack(
    MusicTrack track, {
    String? path,
    String? displayName,
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    String? coverCachePath,
    String? lyricsPath,
    String? manualCoverPath,
  }) {
    return MusicTrack(
      path: path ?? track.path,
      displayName: displayName ?? track.displayName,
      groupKey: groupKey ?? track.groupKey,
      groupTitle: groupTitle ?? track.groupTitle,
      groupSubtitle: groupSubtitle ?? track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
      lastPlayedPosition: track.lastPlayedPosition,
      lastPlayedAt: track.lastPlayedAt,
      isFavorite: track.isFavorite,
      tags: track.tags,
      coverCachePath: coverCachePath ?? track.coverCachePath,
      lyricsPath: lyricsPath ?? track.lyricsPath,
      manualCoverPath: manualCoverPath ?? track.manualCoverPath,
      duration: track.duration,
    );
  }

  Future<void> _saveLibraryExclusions() {
    Map<String, List<String>> encode(Map<String, Set<String>> source) {
      return source.map(
        (key, value) => MapEntry(key, value.toList(growable: false)..sort()),
      );
    }

    return AppPreferences.setString(
      _libraryExclusionsPreferenceKey,
      json.encode(<String, Object?>{
        'folders': encode(service.excludedLibraryFolders),
        'tracks': encode(service.excludedLibraryTracks),
      }),
    );
  }

  Future<void> _saveGroupOrder() {
    return AppPreferences.setString(
      _groupOrderPreferenceKey,
      json.encode(service.groupOrder),
    );
  }

  @override
  void beginLibraryBatch() {
    service.libraryBatchDepth++;
  }

  @override
  void beginStagedLibraryRefresh() {
    beginLibraryBatch();
  }

  @override
  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) {
    for (final folderPath in removeWatchedFolders) {
      removeWatchedFolder(folderPath, notify: false);
    }
    if (tracks.isNotEmpty || folderPaths.isNotEmpty) {
      recordLibraryEntriesForTracks(
        libraryRoot,
        tracks,
        folderPaths: folderPaths,
        persist: persist,
      );
    }
    for (final folderPath in addWatchedFolders) {
      addWatchedFolder(folderPath, notify: false);
    }
    final beforeCount = service.library.length;
    if (tracks.isNotEmpty) {
      addOrReplaceTracks(tracks, notify: false, persist: persist);
    }
    final tracksToRemove = removeTrackPaths.toList(growable: false);
    if (tracksToRemove.isNotEmpty) removeTracksByPath(tracksToRemove);
    final entriesToRemove = removeEntryPaths.toList(growable: false);
    if (entriesToRemove.isNotEmpty) {
      removeLibraryEntriesByPaths(libraryRoot, entriesToRemove);
    }
    return service.library.length - beforeCount;
  }

  @override
  Future<void> finishStagedLibraryRefresh({bool waitForPersistence = false}) {
    return endLibraryBatch(waitForPersistence: waitForPersistence);
  }

  @override
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) async {
    if (service.libraryBatchDepth <= 0) return;
    service.libraryBatchDepth--;
    if (service.libraryBatchDepth > 0) return;

    final didChangeLibrary = service.libraryBatchChanged;
    final entriesToPersist = List<LibraryEntry>.from(
      service.libraryBatchPersistEntriesByKey.values,
    );
    if (!didChangeLibrary && entriesToPersist.isEmpty) return;
    final tracksToPersist = List<MusicTrack>.from(
      service.libraryBatchPersistTracks,
    );
    final didChangeGroupOrder = service.libraryBatchChangedGroupOrder;
    service
      ..libraryBatchChanged = false
      ..libraryBatchChangedGroupOrder = false
      ..libraryBatchPersistTracks.clear()
      ..libraryBatchPersistEntriesByKey.clear();

    if (didChangeLibrary) {
      _coverArtworkCacheService?.invalidateAll();
      service
        ..syncGroupOrderFromLibrary()
        ..syncLibraryNodeOrder(persist: false);
      final derivedGeneration = ++service.libraryDerivedGeneration;
      final derivedSnapshot = await AppLogService.measureAsync(
        'library_derived_snapshot_build',
        () => compute(
          buildLibraryDerivedSnapshot,
          LibraryDerivedSnapshotPayload(
            tracks: List<MusicTrack>.unmodifiable(service.library),
            watchedFolders: List<String>.unmodifiable(service.watchedFolders),
            nodeOrder: List<String>.unmodifiable(service.libraryNodeOrder),
          ),
        ),
        details: <String, Object?>{'tracks': service.library.length},
      );
      if (derivedGeneration == service.libraryDerivedGeneration) {
        service
          ..library = derivedSnapshot.library
          ..libraryByPath = derivedSnapshot.libraryByPath
          ..libraryIndexByPath = derivedSnapshot.libraryIndexByPath
          ..tracksByGroup = derivedSnapshot.tracksByGroup
          ..sortedLibraryTracks = derivedSnapshot.sortedLibraryTracks
          ..sortedLibraryTrackPaths = derivedSnapshot.sortedLibraryTrackPaths
          ..markStructureChanged();
        snapshotCacheService
          ..markStructureChanged()
          ..adoptCardSnapshot(derivedSnapshot.cardSnapshot);
        _syncStateSlice();
      }
    }

    final persistenceTasks = <Future<void>>[];
    if (_persistenceEnabled) {
      if (tracksToPersist.isNotEmpty) {
        persistenceTasks.add(databaseRepository.upsertTracks(tracksToPersist));
      }
      if (entriesToPersist.isNotEmpty) {
        persistenceTasks.add(
          databaseRepository.upsertLibraryEntries(entriesToPersist),
        );
      }
      if (didChangeLibrary && didChangeGroupOrder) {
        persistenceTasks.add(_saveGroupOrder());
      }
      if (didChangeLibrary) persistenceTasks.add(_saveLibraryNodeOrder());
    }
    if (waitForPersistence) {
      await Future.wait(persistenceTasks);
    } else {
      for (final task in persistenceTasks) {
        unawaited(task);
      }
    }
  }

  void _queueOrPersistLibraryEntries(
    List<LibraryEntry> entries, {
    required bool persist,
  }) {
    if (entries.isEmpty || !persist || !_persistenceEnabled) return;
    if (service.libraryBatchDepth > 0) {
      for (final entry in entries) {
        final key = <String>[
          PathMatcher.normalize(entry.libraryPath),
          PathMatcher.normalize(entry.path),
          entry.kind.dbValue,
        ].join('\x1F');
        service.libraryBatchPersistEntriesByKey[key] = entry;
      }
      return;
    }
    unawaited(databaseRepository.upsertLibraryEntries(entries));
  }

  @override
  int tryBeginScan({required String source, bool background = false}) {
    if (service.isScanning) return 0;
    service.scanGenerationSeed++;
    final generation = service.scanGenerationSeed;
    _setScanning(true, background: background);
    service
      ..scanGeneration = generation
      ..scanCurrentFolder = source
      ..scanStage = FolderScanStage.preparing
      ..scanProcessed = 0
      ..scanTotal = null;
    _syncStateSlice();
    return generation;
  }

  @override
  void cancelScan() {
    if (!service.isScanning) return;
    _setScanning(false);
    unawaited(FileCachePlatformGateway.instance.cancelActiveFolderScan());
  }

  @override
  void finishScan(int generation) {
    if (!isScanGenerationActive(generation)) return;
    _setScanning(false);
  }

  @override
  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
    int? generation,
    FolderScanStage? stage,
    int? processed,
    int? total,
  }) {
    if (generation != null && generation != service.scanGeneration) return;
    final nextFolder = currentFolder ?? service.scanCurrentFolder;
    final nextFoundCount = foundCount ?? service.scanFoundCount;
    final nextDuplicateCount = duplicateCount ?? service.scanDuplicateCount;
    final nextFailureCount = failureCount ?? service.scanFailureCount;
    final nextStage = stage ?? service.scanStage;
    final nextProcessed = processed ?? service.scanProcessed;
    final nextTotal = total ?? service.scanTotal;
    final changed =
        nextFolder != service.scanCurrentFolder ||
        nextFoundCount != service.scanFoundCount ||
        nextDuplicateCount != service.scanDuplicateCount ||
        nextFailureCount != service.scanFailureCount ||
        nextStage != service.scanStage ||
        nextProcessed != service.scanProcessed ||
        nextTotal != service.scanTotal;
    if (!changed) return;
    if (currentFolder != null) service.scanCurrentFolder = currentFolder;
    if (foundCount != null) service.scanFoundCount = foundCount;
    if (duplicateCount != null) {
      service.scanDuplicateCount = duplicateCount;
    }
    if (failureCount != null) service.scanFailureCount = failureCount;
    if (stage != null) service.scanStage = stage;
    if (processed != null) service.scanProcessed = processed;
    if (total != null) service.scanTotal = total;
    if (service.isBackgroundScanning) return;
    _scheduleScanProgressSync();
  }

  void _setScanning(bool scanning, {bool background = false}) {
    if (service.isScanning == scanning &&
        service.isBackgroundScanning == background) {
      return;
    }
    service
      ..isScanning = scanning
      ..isBackgroundScanning = scanning && background;
    service.scanProgressNotifyTimer?.cancel();
    service.scanProgressNotifyTimer = null;
    if (scanning) {
      service
        ..scanCurrentFolder = ''
        ..scanFoundCount = 0
        ..scanDuplicateCount = 0
        ..scanFailureCount = 0
        ..scanStage = FolderScanStage.preparing
        ..scanProcessed = 0
        ..scanTotal = null;
    } else {
      service
        ..scanGeneration = 0
        ..scanStage = FolderScanStage.idle
        ..scanTotal = null;
    }
    _syncStateSlice();
  }

  void _scheduleScanProgressSync() {
    if (!service.isScanning) {
      _syncStateSlice();
      return;
    }
    if (service.scanProgressNotifyTimer != null) return;
    service.scanProgressNotifyTimer = Timer(
      const Duration(milliseconds: 160),
      () {
        service.scanProgressNotifyTimer = null;
        if (service.isScanning) _syncStateSlice();
      },
    );
  }

  CoverArtworkCacheService get coverArtworkCacheService {
    final service = _coverArtworkCacheService;
    if (service == null) {
      throw StateError('LibraryFacade cover service has not been attached.');
    }
    return service;
  }

  void attachCoverArtworkCacheService(
    CoverArtworkCacheService Function() create,
  ) {
    _coverArtworkCacheService ??= create();
  }

  void _syncStateSlice() {
    final current = service.slice.state;
    service.syncSlice(
      isInitialized: current.isInitialized,
      detailRevision: detailCacheService.revision,
      treeSnapshotRevision: snapshotCacheService.cardSnapshotRevision,
      categorySnapshotRevision: snapshotCacheService.categorySnapshotRevision,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    UiInteractionCoordinator.instance.removeListener(
      _handleWarmupInteractionChanged,
    );
    await _coverWarmupScheduler.shutdown();
    service.scanProgressNotifyTimer?.cancel();
    service.scanProgressNotifyTimer = null;
    _coverArtworkCacheService?.dispose();
    await service.dispose();
  }
}

class AudioDetailRenameResult {
  const AudioDetailRenameResult({
    required this.detail,
    required this.renamed,
    this.backupFailed = false,
  });

  final AudioDetail detail;
  final bool renamed;
  final bool backupFailed;
}

class AudioDetailRenameException implements Exception {
  const AudioDetailRenameException(this.reason);

  final String reason;
}

Future<Duration?> _readLocalMediaDuration(
  AudioPlayer player,
  String mediaPath,
) {
  if (PathMatcher.isContentUri(mediaPath)) {
    return player
        .setAudioSource(AudioSource.uri(Uri.parse(mediaPath)))
        .timeout(const Duration(seconds: 8));
  }
  return player.setFilePath(mediaPath).timeout(const Duration(seconds: 8));
}
