import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../../../core/media/audio_detail.dart';
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
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';

/// Owns the library-side services used by the compatibility audio facade.
///
/// Mutable library state remains owned exclusively by [LibraryService].
final class LibraryFacade implements LibraryCatalogReader {
  static const _watchedFoldersPreferenceKey = 'watched_folders_v1';
  static const _watchedLibrariesPreferenceKey = 'watched_libraries_v1';
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

  DlsiteMetadataQuery buildDlsiteMetadataQuery(AudioDetail detail) =>
      DlsiteMetadataQuery.fromDetail(detail);

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
    service.scanProgressNotifyTimer?.cancel();
    service.scanProgressNotifyTimer = null;
    _coverArtworkCacheService?.dispose();
    await service.dispose();
  }
}
