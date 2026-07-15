import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/persistence/audio_database_repository.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
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
final class LibraryFacade implements LibraryCatalogReader {
  static const _watchedFoldersPreferenceKey = 'watched_folders_v1';
  static const _watchedLibrariesPreferenceKey = 'watched_libraries_v1';
  static const _libraryNodeOrderPreferenceKey = 'library_node_order_v1';
  LibraryFacade({
    required this.databaseRepository,
    required this.detailCacheService,
    required this.metadataService,
    required this.asmrMetadataService,
    required this.service,
    required this.snapshotCacheService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) : _coverArtworkCacheService = coverArtworkCacheService;

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
  LibraryCatalog? _catalog;
  Future<void>? _missingDurationBackfill;
  bool _missingDurationBackfillRequestedAgain = false;
  bool _disposed = false;

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

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCodeFromText(
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

  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = service.addWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = service.addWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

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

  void cancelScan() {
    if (!service.isScanning) return;
    _setScanning(false);
    unawaited(FileCachePlatformGateway.instance.cancelActiveFolderScan());
  }

  void finishScan(int generation) {
    if (!isScanGenerationActive(generation)) return;
    _setScanning(false);
  }

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

  LibraryCatalog get catalog {
    final catalog = _catalog;
    if (catalog == null) {
      throw StateError(
        'LibraryFacade catalog commands have not been attached.',
      );
    }
    return catalog;
  }

  void attachCatalog(LibraryCatalog catalog) {
    _catalog ??= catalog;
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
    service.scanProgressNotifyTimer?.cancel();
    service.scanProgressNotifyTimer = null;
    _coverArtworkCacheService?.dispose();
    await service.dispose();
  }
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
