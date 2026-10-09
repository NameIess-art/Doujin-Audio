import 'dart:async';
import 'dart:collection';

import '../../../core/app_language.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/persistence/json_document_store.dart';
import '../../../core/cache/app_cache_service.dart';
import '../../player/domain/playback_library_catalog.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'cover_artwork_cache_service.dart';
import 'dlsite_metadata_query.dart';
import 'dlsite_metadata_service.dart';
import 'library_snapshot_cache_service.dart';
import 'library_startup_maintenance_coordinator.dart';
import 'library_catalog.dart';
import 'library_catalog_write_coordinator.dart';
import 'library_entry_editor_service.dart';
import 'library_scan_models.dart';
import 'library_metadata_coordinator.dart';
import 'library_metadata_source.dart';
import 'library_mutation_coordinator.dart';
import 'library_persistence_coordinator.dart';
import 'library_service.dart';
import '../domain/audio_library_category.dart';
import '../domain/audio_detail_store.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_state_models.dart';

export 'library_mutation_coordinator.dart'
    show
        AudioDetailRenameException,
        AudioDetailRenameResult,
        LibraryRemovalKind;

/// Coordinates library services while mutable state stays in [LibraryService].
final class LibraryFacade implements LibraryCatalog, PlaybackLibraryCatalog {
  LibraryFacade({
    required this.databaseRepository,
    required this.detailCacheService,
    required this.metadataService,
    required this.asmrMetadataService,
    required LibraryService service,
    required this.snapshotCacheService,
    LibraryEntryEditorService? entryEditorService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) : _service = service,
       entryEditorService = entryEditorService ?? LibraryEntryEditorService(),
       _coverArtworkCacheService = coverArtworkCacheService;

  factory LibraryFacade.create({
    required LibraryPersistenceRepository databaseRepository,
    AudioDetailStore? audioDetailStore,
    JsonDocumentStore? jsonDocumentStore,
    AudioDetailRepository? detailRepository,
    AudioDetailCacheService? detailCacheService,
    DlsiteMetadataService? metadataService,
    LibraryMetadataSource? asmrMetadataService,
    LibraryService? service,
    LibrarySnapshotCacheService? snapshotCacheService,
    LibraryEntryEditorService? entryEditorService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) {
    final resolvedAudioDetailStore =
        audioDetailStore ??
        (databaseRepository is AudioDetailStore
            ? databaseRepository as AudioDetailStore
            : throw ArgumentError.value(
                databaseRepository,
                'databaseRepository',
                'must also implement AudioDetailStore',
              ));
    final resolvedDetailCache =
        detailCacheService ??
        AudioDetailCacheService(
          repository:
              detailRepository ??
              AudioDetailRepository(
                databaseRepository: resolvedAudioDetailStore,
                jsonDocumentStore: jsonDocumentStore,
              ),
        );
    final resolvedService = service ?? LibraryService();
    return LibraryFacade(
      databaseRepository: databaseRepository,
      detailCacheService: resolvedDetailCache,
      metadataService: metadataService ?? DlsiteMetadataService(),
      asmrMetadataService: asmrMetadataService,
      service: resolvedService,
      snapshotCacheService:
          snapshotCacheService ??
          LibrarySnapshotCacheService(
            libraryService: resolvedService,
            detailCacheService: resolvedDetailCache,
          ),
      entryEditorService: entryEditorService ?? LibraryEntryEditorService(),
      coverArtworkCacheService: coverArtworkCacheService,
    );
  }

  final LibraryPersistenceRepository databaseRepository;
  final AudioDetailCacheService detailCacheService;
  final DlsiteMetadataService metadataService;
  final LibraryMetadataSource? asmrMetadataService;
  final LibraryService _service;
  final LibrarySnapshotCacheService snapshotCacheService;
  final LibraryEntryEditorService entryEditorService;
  late final LibraryPersistenceCoordinator _persistenceCoordinator =
      LibraryPersistenceCoordinator(
        repository: databaseRepository,
        service: _service,
      );
  late final LibraryCatalogWriteCoordinator _catalogWrites =
      LibraryCatalogWriteCoordinator(
        service: _service,
        databaseRepository: databaseRepository,
        snapshotCacheService: snapshotCacheService,
        persistenceCoordinator: _persistenceCoordinator,
        coverArtwork: () => _coverArtworkCacheService,
        syncState: _syncStateSlice,
      );
  late final LibraryMetadataCoordinator _metadataCoordinator =
      LibraryMetadataCoordinator(
        databaseRepository: databaseRepository,
        detailCacheService: detailCacheService,
        metadataService: metadataService,
        asmrMetadataService: asmrMetadataService,
        service: _service,
        snapshotCacheService: snapshotCacheService,
        coverArtwork: () => coverArtworkCacheService,
        syncState: _syncStateSlice,
        notifyCoverChanged: () => _coverChangeHandler?.call(),
      );
  late final LibraryMutationCoordinator _mutationCoordinator =
      LibraryMutationCoordinator(
        databaseRepository: databaseRepository,
        detailCacheService: detailCacheService,
        service: _service,
        snapshotCacheService: snapshotCacheService,
        entryEditorService: entryEditorService,
        persistenceCoordinator: _persistenceCoordinator,
        coverArtwork: () => coverArtworkCacheService,
        catalogWrites: _catalogWrites,
        cancelScan: cancelScan,
        deleteAudioDetail: _metadataCoordinator.deleteAudioDetail,
        syncState: _syncStateSlice,
      );
  CoverArtworkCacheService? _coverArtworkCacheService;
  bool _disposed = false;
  int _scanOperationGeneration = 0;
  Completer<void>? _scanCompletion;
  bool _interactionPaused = false;
  void Function()? _coverChangeHandler;
  late final LibraryStartupMaintenanceCoordinator
  _startupMaintenanceCoordinator =
      LibraryStartupMaintenanceCoordinator.forLibrary(
        waitForUiIdle: _waitForContinuousUiIdle,
        cleanupOrphanedImports: (retainedPaths) =>
            AppCacheService.cleanupOrphanedPersistentImports(retainedPaths),
        libraryService: _service,
        repository: databaseRepository,
        metadataCoordinator: _metadataCoordinator,
        coverArtwork: () => coverArtworkCacheService,
      );

  LibraryState get state => _service.slice.state;
  Stream<LibraryState> get states => _service.slice.stream;
  // Cancellation stops mutations before the scan has released its lease.
  Future<void> get scanIdle => _scanCompletion?.future ?? Future<void>.value();
  List<LibraryNode> get libraryCards => snapshotCacheService.cards;
  @override
  List<MusicTrack> get library =>
      UnmodifiableListView<MusicTrack>(_service.library);
  @override
  int get structureRevision => _service.structureRevision;
  @override
  int get contentRevision => _service.contentRevision;
  @override
  int get coverGeneration => coverArtworkCacheService.generation;
  int get scanRevision => _service.scanGenerationSeed;
  bool get persistedUriReferencesReady => state.isInitialized;
  int get persistedUriReferenceRevision => structureRevision;
  Set<String> get persistedContentUris => <String>{
    ..._service.watchedFolders.where(PathMatcher.isContentUri),
    ..._service.watchedLibraries.where(PathMatcher.isContentUri),
    ..._service.library
        .map((track) => track.path)
        .where(PathMatcher.isContentUri),
  };
  List<String> get sortedLibraryTrackPaths =>
      UnmodifiableListView<String>(_service.sortedLibraryTrackPaths);
  Map<String, List<MusicTrack>> get tracksByGroup =>
      UnmodifiableMapView<String, List<MusicTrack>>(
        _service.tracksByGroup.map(
          (key, value) =>
              MapEntry(key, UnmodifiableListView<MusicTrack>(value)),
        ),
      );
  @override
  List<String> get watchedFolders =>
      UnmodifiableListView<String>(_service.watchedFolders);
  @override
  List<String> get watchedLibraries =>
      UnmodifiableListView<String>(_service.watchedLibraries);
  @override
  bool get isScanning => _service.isScanning;
  bool get isBackgroundScanning => _service.isBackgroundScanning;
  @override
  int get scanFoundCount => _service.scanFoundCount;
  @override
  int get scanDuplicateCount => _service.scanDuplicateCount;
  @override
  int get scanFailureCount => _service.scanFailureCount;
  AudioLibraryCategorySnapshot? get categorySnapshot =>
      snapshotCacheService.categorySnapshotSync;

  Future<void> loadPersistedState() async {
    final persisted = await _persistenceCoordinator.load();

    _service
      ..library.addAll(persisted.tracks)
      ..groupOrder.addAll(persisted.groupOrder)
      ..groupOrderSet.addAll(persisted.groupOrder)
      ..watchedFolders.addAll(persisted.watchedFolders)
      ..watchedLibraries.addAll(persisted.watchedLibraries)
      ..excludedLibraryFolders.addAll(persisted.folderExclusions)
      ..excludedLibraryTracks.addAll(persisted.trackExclusions);
    _service
      ..replaceLibraryEntries(persisted.entries)
      ..rebuildExclusionsFromEntries(persisted.entries);
    for (final entry in persisted.legacyFolderExclusions.entries) {
      _service.excludedLibraryFolders
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(entry.value);
    }
    _applyExclusionsToLibrary();

    beginLibraryBatch();
    _service.libraryBatchChanged = _service.library.isNotEmpty;
    await endLibraryBatch(notify: false);
    _service.syncGroupOrderFromLibrary();
    // Startup caches shallow cards; nested trees stay lazy until requested.
    _syncStateSlice(isInitialized: true);
  }

  Future<void> prepareForPersistedStateReset() async {
    _metadataCoordinator.prepareForReset();
    cancelScan();
    await _startupMaintenanceCoordinator.cancelAndWait();
    await _persistenceCoordinator.prepareForReset();
    await detailCacheService.suspendAndWait();
  }

  Future<void> flushPendingPersistence() async {
    await _persistenceCoordinator.flush();
    await detailCacheService.waitForPendingOperations();
  }

  Future<void> resetPersistedState() async {
    await prepareForPersistedStateReset();
    cancelPendingScanProgressNotification();
    _service
      ..library.clear()
      ..libraryByPath.clear()
      ..libraryIndexByPath.clear()
      ..tracksByGroup.clear()
      ..sortedLibraryTracks = const <MusicTrack>[]
      ..sortedLibraryTrackPaths = const <String>[]
      ..groupOrder.clear()
      ..groupOrderSet.clear()
      ..watchedFolders.clear()
      ..watchedLibraries.clear()
      ..excludedLibraryFolders.clear()
      ..excludedLibraryTracks.clear()
      ..libraryEntriesByLibrary.clear()
      ..isScanning = false
      ..isBackgroundScanning = false
      ..scanCurrentFolder = ''
      ..scanFoundCount = 0
      ..scanDuplicateCount = 0
      ..scanFailureCount = 0
      ..libraryBatchDepth = 0
      ..libraryBatchChanged = false
      ..libraryBatchPersistTracks.clear()
      ..libraryBatchPersistEntriesByKey.clear()
      ..markStructureChanged();
    snapshotCacheService.clear();
    _coverArtworkCacheService?.invalidateAll();
    detailCacheService.resume();
    _syncStateSlice(isInitialized: false);
  }

  void _applyExclusionsToLibrary() {
    final excludedTracks = _service.excludedLibraryTracks.values
        .expand((paths) => paths)
        .toSet();
    final excludedFolders = _service.excludedLibraryFolders.values
        .expand((paths) => paths)
        .toSet();
    if (excludedTracks.isEmpty && excludedFolders.isEmpty) return;
    final trackIndex = PathMembershipIndex(excludedTracks);
    final folderIndex = PathMembershipIndex(excludedFolders);
    removeTracksMatching(
      (track) =>
          trackIndex.containsEquivalent(track.path) ||
          folderIndex.containsAncestorOrEqual(track.path) ||
          folderIndex.containsAncestorOrEqual(track.groupKey),
    );
  }

  List<LibraryNode> get libraryTree {
    if (snapshotCacheService.treeSnapshotRevision !=
        _service.structureRevision) {
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

  Future<FolderNode?> loadLibraryFolderTree(String folderPath) =>
      snapshotCacheService.loadFolderTree(folderPath);

  FolderNode? resolvedLibraryFolderTree(String folderPath) =>
      snapshotCacheService.resolvedFolderTree(folderPath);

  String? libraryRootForPath(String entityPath) =>
      _service.libraryRootForPath(entityPath);

  Future<AudioLibraryCategorySnapshot> audioLibraryCategorySnapshot({
    void Function()? onCommitted,
  }) => snapshotCacheService.categorySnapshot(
    onCommitted: () {
      _syncStateSlice();
      onCommitted?.call();
    },
  );

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) =>
      _metadataCoordinator.loadAudioDetail(target);

  Future<AudioDetailSaveResult> saveAudioDetail(
    AudioDetail detail, {
    bool preserveExistingDuration = false,
  }) => _metadataCoordinator.saveAudioDetail(
    detail,
    preserveExistingDuration: preserveExistingDuration,
  );

  Future<AudioDetailSaveResult> saveMissingLibraryDuration(
    AudioDetailTarget target,
    Duration duration,
  ) => _metadataCoordinator.saveMissingDuration(target, duration);

  Future<bool> exportTimeSegmentLabels(String trackKey) =>
      _metadataCoordinator.exportTimeSegmentLabels(trackKey);

  Future<void> deleteAudioDetail(AudioDetailTarget target) =>
      _metadataCoordinator.deleteAudioDetail(target);

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCode(
    AudioDetailTarget target,
    String text,
  ) => _metadataCoordinator.prefillRjCode(target, text);

  @override
  Future<AudioDetailBackupImportResult> importAudioDetailBackups({
    bool onlyMissing = false,
  }) => _metadataCoordinator.importBackups(onlyMissing: onlyMissing);

  @override
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  ) => _metadataCoordinator.prefillRjCode(
    AudioDetailTarget.libraryRootFolder(folderPath),
    displayName,
  );

  AudioDetailTarget audioDetailTargetForTrack(MusicTrack track) =>
      _metadataCoordinator.targetForTrack(track);

  AudioDetailTarget canonicalAudioDetailTarget(AudioDetailTarget target) =>
      _metadataCoordinator.canonicalTarget(target);

  AudioDetailTarget audioDetailTargetForPath(String trackPath) =>
      _metadataCoordinator.targetForPath(trackPath);

  @override
  Future<void> backfillMissingLibraryDurations({
    Future<Duration?> Function(String path)? durationReader,
  }) => _metadataCoordinator.backfillMissingDurations(
    durationReader: durationReader,
  );

  Future<Duration?> calculateMissingLibraryDuration(
    String targetPath, {
    Future<Duration?> Function(String path)? durationReader,
  }) => _metadataCoordinator.calculateMissingDuration(
    targetPath,
    durationReader: durationReader,
  );

  DlsiteMetadataQuery buildDlsiteMetadataQuery(AudioDetail detail) =>
      _metadataCoordinator.buildQuery(detail);

  Future<DlsiteMetadata> fetchPreferredMetadata(
    String rjCode, {
    required AppLanguage language,
  }) => _metadataCoordinator.fetchPreferredMetadata(rjCode, language: language);

  Future<List<DlsiteMetadata>> searchPreferredMetadataByTitles(
    Iterable<String> titles, {
    required AppLanguage language,
  }) =>
      _metadataCoordinator.searchPreferredMetadata(titles, language: language);

  AudioDetail? resolvedAudioDetail(AudioDetailTarget target) =>
      _metadataCoordinator.resolvedDetail(target);

  @override
  MusicTrack? trackByPath(String trackPath) => _service.trackByPath(trackPath);

  MusicTrack? updatePlaybackHistory({
    required String trackPath,
    required Duration position,
    required DateTime now,
    required bool updatePlayedAt,
  }) {
    final track = _service.libraryByPath[trackPath];
    if (track == null) return null;
    final updated = track.copyWith(
      lastPlayedPosition: position,
      lastPlayedAt: updatePlayedAt ? now : track.lastPlayedAt,
    );
    _service.libraryByPath[track.path] = updated;
    final index = _service.libraryIndexByPath[track.path];
    if (index != null &&
        index < _service.library.length &&
        _service.library[index].path == track.path) {
      _service.library[index] = updated;
    }
    return updated;
  }

  @override
  List<MusicTrack> tracksInGroup(String groupKey, {int? limit}) =>
      List<MusicTrack>.unmodifiable(
        limit == null
            ? _service.tracksByGroup[groupKey] ?? const <MusicTrack>[]
            : (_service.tracksByGroup[groupKey] ?? const <MusicTrack>[]).take(
                limit,
              ),
      );
  int compareTracks(MusicTrack first, MusicTrack second) =>
      _service.compareTracks(first, second);
  String? resolvedCoverPathForTrack(MusicTrack? track, {String? trackPath}) =>
      _metadataCoordinator.resolvedCoverForTrack(track, trackPath: trackPath);

  @override
  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _metadataCoordinator.resolvedPlaybackCoverForTrack(
    track,
    trackPath: trackPath,
  );

  String? resolvedCoverPathForRemoteCover(String url) =>
      _metadataCoordinator.resolvedRemoteCover(url);

  String? resolvedCoverPathForFolder(String folderPath) =>
      _metadataCoordinator.resolvedFolderCover(folderPath);

  Future<String?> coverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _metadataCoordinator.coverForTrack(track, trackPath: trackPath);

  String? resolvedEmbeddedCoverPathForFile(String filePath) =>
      _metadataCoordinator.resolvedEmbeddedCoverForPath(filePath);

  Future<String?> embeddedCoverPathFutureForFile(String filePath) =>
      _metadataCoordinator.resolveEmbeddedCoverForPath(filePath);

  @override
  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _metadataCoordinator.playbackCoverForTrack(track, trackPath: trackPath);

  Future<String?> coverPathFutureForFolder(String folderPath) =>
      _metadataCoordinator.coverForFolder(folderPath);

  Future<String?> coverPathFutureForRemoteCover(String url) =>
      _metadataCoordinator.coverForRemote(url);

  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
  }) => _metadataCoordinator.discoverCoverCandidates(
    folderPath,
    selectedCoverPath: selectedCoverPath,
    includeVideoFrames: includeVideoFrames,
    includeEmbeddedCovers: includeEmbeddedCovers,
    propagateFailure: propagateFailure,
  );

  Future<List<CoverImageReference>> discoverCoverImageReferencesInFolder(
    String folderPath, {
    bool refresh = false,
  }) => coverArtworkCacheService.discoverCoverImageReferencesInFolder(
    folderPath,
    refresh: refresh,
  );

  Future<String?> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
    String? sourcePath,
  }) => _metadataCoordinator.setFolderManualCover(
    folderPath,
    imagePath,
    newlySaved: newlySaved,
    sourcePath: sourcePath,
  );

  void invalidateCoverArtwork() =>
      _metadataCoordinator.invalidateCoverArtwork();

  Future<DlsiteMetadataApplyResult> applyDlsiteMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
    required AppLanguage language,
    bool missingOnly = false,
    bool deferCategoryUpdate = false,
  }) => _metadataCoordinator.applyMetadata(
    detail,
    metadata,
    saveCover: saveCover,
    language: language,
    missingOnly: missingOnly,
    deferCategoryUpdate: deferCategoryUpdate,
  );

  void flushMetadataUpdates() => _metadataCoordinator.flushMetadataUpdates();

  void setInteractionPaused(bool paused) {
    if (_interactionPaused == paused) return;
    _interactionPaused = paused;
  }

  String? libraryEntryDisplayNameForPath(
    String libraryPath,
    String entryPath,
  ) => _service.libraryEntryDisplayNameForPath(libraryPath, entryPath);
  List<String> excludedTracksForLibrary(String libraryPath) =>
      _service.excludedTracksForLibrary(libraryPath);
  List<String> excludedFoldersForLibrary(String libraryPath) =>
      _service.excludedFoldersForLibrary(libraryPath);
  List<String> childFoldersForLibrary(String libraryPath) =>
      _service.childFoldersForLibrary(libraryPath);
  @override
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      _service.libraryEntriesForLibrary(libraryPath);
  @override
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) =>
      _service.libraryEntrySnapshotForLibrary(libraryPath);
  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) => _service.libraryExclusionMatcherForLibrary(libraryPath);
  @override
  bool hasLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return (_service
                .excludedLibraryFolders[normalizedLibraryPath]
                ?.isNotEmpty ??
            false) ||
        (_service.excludedLibraryTracks[normalizedLibraryPath]?.isNotEmpty ??
            false);
  }

  bool isLibraryTrackExplicitlyExcluded(String libraryPath, String trackPath) =>
      _service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath);
  bool isLibraryFolderExplicitlyExcluded(
    String libraryPath,
    String folderPath,
  ) => _service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath);
  @override
  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      _service.isLibraryPathExcluded(libraryPath, entityPath);

  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) =>
      _service.isLibraryPathInheritedExcluded(libraryPath, entityPath);

  @override
  bool isScanGenerationActive(int generation) =>
      _service.isScanning &&
      generation != 0 &&
      generation == _service.scanGeneration;

  @override
  void addWatchedFolder(String folderPath, {bool notify = true}) =>
      _catalogWrites.addWatchedFolder(folderPath, notify: notify);

  @override
  void addWatchedLibrary(String folderPath, {bool notify = true}) =>
      _catalogWrites.addWatchedLibrary(folderPath, notify: notify);

  @override
  void removeWatchedFolder(String folderPath, {bool notify = true}) =>
      _catalogWrites.removeWatchedFolder(folderPath, notify: notify);

  void removeWatchedLibrary(String folderPath, {bool notify = true}) =>
      _catalogWrites.removeWatchedLibrary(folderPath, notify: notify);

  void configurePersistence({required bool enabled}) {
    _persistenceCoordinator.configure(enabled: enabled);
  }

  void attachTrackRemovalHandler(
    void Function(List<String> removedPaths) handler,
  ) {
    _catalogWrites.attachTrackRemovalHandler(handler);
  }

  void attachCoverChangeHandler(void Function() handler) {
    _coverChangeHandler ??= handler;
  }

  void detachRuntimeHandlers() {
    _catalogWrites.detachRuntimeHandlers();
    _coverChangeHandler = null;
  }

  @override
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) => _catalogWrites.recordLibraryEntriesForTracks(
    libraryPath,
    tracks,
    folderPaths: folderPaths,
    persist: persist,
    exclusionMatcher: exclusionMatcher,
    entrySnapshot: entrySnapshot,
  );

  void recordEntriesForTracks(List<MusicTrack> tracks, {bool persist = true}) =>
      _catalogWrites.recordEntriesForTracks(tracks, persist: persist);

  @override
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) => _catalogWrites.addTracks(tracks, notify: notify, persist: persist);

  @override
  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
    bool mergeExistingState = true,
  }) => _catalogWrites.addOrReplaceTracks(
    tracks,
    notify: notify,
    persist: persist,
    mergeExistingState: mergeExistingState,
  );

  List<String> removeTracksMatching(
    bool Function(MusicTrack track) test, {
    bool persist = true,
  }) => _catalogWrites.removeTracksMatching(test, persist: persist);

  @override
  void removeTracksByPath(Iterable<String> trackPaths) =>
      _catalogWrites.removeTracksByPath(trackPaths);

  @override
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) => _catalogWrites.removeTracksDeletedFromFolder(folderPath, scannedPaths);

  @override
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) => _catalogWrites.removeLibraryEntriesDeletedFromFolder(
    libraryPath,
    folderPath,
    retainedPaths,
  );

  @override
  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) => _catalogWrites.removeLibraryEntriesByPaths(libraryPath, entryPaths);

  @override
  void clearLibraryExclusions(String libraryPath) =>
      _mutationCoordinator.clearLibraryExclusions(libraryPath);

  Future<LibraryRemovalKind?> removeTrack(String trackPath) =>
      _mutationCoordinator.removeTrack(trackPath);

  Future<LibraryRemovalKind?> removeFolder(String folderPath) =>
      _mutationCoordinator.removeFolder(folderPath);

  void excludeLibraryFolder(String libraryPath, String folderPath) =>
      _mutationCoordinator.excludeLibraryFolder(libraryPath, folderPath);

  void excludeLibraryTrack(String libraryPath, String trackPath) =>
      _mutationCoordinator.excludeLibraryTrack(libraryPath, trackPath);

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) => _mutationCoordinator.setLibraryFolderExcluded(
    libraryPath,
    folderPath,
    excluded,
  );

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) => _mutationCoordinator.setLibraryTrackExcluded(
    libraryPath,
    trackPath,
    excluded,
  );

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) => _mutationCoordinator.renameAudioDetailTargetToName(detail, targetName);

  Future<String> renameWorkEntryToName({
    required String libraryRootPath,
    required String entryPath,
    required String targetName,
    required bool isMedia,
    required bool isDirectory,
  }) => _mutationCoordinator.renameWorkEntryToName(
    libraryRootPath: libraryRootPath,
    entryPath: entryPath,
    targetName: targetName,
    isMedia: isMedia,
    isDirectory: isDirectory,
  );

  @override
  void beginLibraryBatch() => _catalogWrites.beginLibraryBatch();

  @override
  void beginStagedLibraryRefresh() =>
      _catalogWrites.beginStagedLibraryRefresh();

  @override
  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    List<MusicTrack> entryTracks = const <MusicTrack>[],
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) => _catalogWrites.applyStagedLibraryRefreshChunk(
    sourceFolderPath: sourceFolderPath,
    libraryRoot: libraryRoot,
    tracks: tracks,
    entryTracks: entryTracks,
    exclusionMatcher: exclusionMatcher,
    entrySnapshot: entrySnapshot,
    folderPaths: folderPaths,
    removeWatchedFolders: removeWatchedFolders,
    addWatchedFolders: addWatchedFolders,
    removeTrackPaths: removeTrackPaths,
    removeEntryPaths: removeEntryPaths,
    persist: persist,
  );

  @override
  Future<void> finishStagedLibraryRefresh({bool commit = true}) =>
      _catalogWrites.finishStagedLibraryRefresh(commit: commit);

  @override
  Future<void> endLibraryBatch({bool notify = true}) =>
      _catalogWrites.endLibraryBatch(notify: notify);

  @override
  int tryBeginScan({required String source, bool background = false}) {
    if (_scanOperationGeneration != 0) return 0;
    _service.scanGenerationSeed++;
    final generation = _service.scanGenerationSeed;
    _scanOperationGeneration = generation;
    _scanCompletion = Completer<void>();
    _setScanning(true, background: background);
    _service
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
    if (!_service.isScanning) return;
    _setScanning(false);
    unawaited(FileCachePlatformGateway.instance.cancelActiveFolderScan());
  }

  @override
  void finishScan(int generation) {
    if (_scanOperationGeneration != generation) return;
    _scanOperationGeneration = 0;
    if (_service.isScanning) _setScanning(false);
    final completion = _scanCompletion;
    _scanCompletion = null;
    completion?.complete();
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
    if (generation != null && generation != _service.scanGeneration) return;
    final nextFolder = currentFolder ?? _service.scanCurrentFolder;
    final nextFoundCount = foundCount ?? _service.scanFoundCount;
    final nextDuplicateCount = duplicateCount ?? _service.scanDuplicateCount;
    final nextFailureCount = failureCount ?? _service.scanFailureCount;
    final nextStage = stage ?? _service.scanStage;
    final nextProcessed = processed ?? _service.scanProcessed;
    final nextTotal = total ?? _service.scanTotal;
    final changed =
        nextFolder != _service.scanCurrentFolder ||
        nextFoundCount != _service.scanFoundCount ||
        nextDuplicateCount != _service.scanDuplicateCount ||
        nextFailureCount != _service.scanFailureCount ||
        nextStage != _service.scanStage ||
        nextProcessed != _service.scanProcessed ||
        nextTotal != _service.scanTotal;
    if (!changed) return;
    _service
      ..scanCurrentFolder = nextFolder
      ..scanFoundCount = nextFoundCount
      ..scanDuplicateCount = nextDuplicateCount
      ..scanFailureCount = nextFailureCount
      ..scanStage = nextStage
      ..scanProcessed = nextProcessed
      ..scanTotal = nextTotal;
    if (_service.isBackgroundScanning) return;
    _scheduleScanProgressSync();
  }

  void _setScanning(bool scanning, {bool background = false}) {
    if (_service.isScanning == scanning &&
        _service.isBackgroundScanning == background) {
      return;
    }
    _service
      ..isScanning = scanning
      ..isBackgroundScanning = scanning && background;
    cancelPendingScanProgressNotification();
    if (scanning) {
      _service
        ..scanCurrentFolder = ''
        ..scanFoundCount = 0
        ..scanDuplicateCount = 0
        ..scanFailureCount = 0
        ..scanStage = FolderScanStage.preparing
        ..scanProcessed = 0
        ..scanTotal = null;
    } else {
      _service
        ..scanGeneration = 0
        ..scanStage = FolderScanStage.idle
        ..scanTotal = null;
    }
    _syncStateSlice();
  }

  void _scheduleScanProgressSync() {
    if (!_service.isScanning) {
      _syncStateSlice();
      return;
    }
    if (_service.scanProgressNotifyTimer != null) return;
    _service.scanProgressNotifyTimer = Timer(
      const Duration(milliseconds: 160),
      () {
        _service.scanProgressNotifyTimer = null;
        if (_service.isScanning) _syncStateSlice();
      },
    );
  }

  CoverArtworkCacheService get coverArtworkCacheService {
    final coverService = _coverArtworkCacheService;
    if (coverService == null) {
      throw StateError('LibraryFacade cover service has not been attached.');
    }
    return coverService;
  }

  void attachCoverArtworkCacheService(
    CoverArtworkCacheService Function() create,
  ) {
    _coverArtworkCacheService ??= create();
  }

  void configureCoverArtworkRuntime({
    required bool Function(String key) isActiveCoverKey,
    required void Function() onActiveCoverChanged,
    bool Function()? preferEmbeddedCover,
  }) {
    _coverArtworkCacheService ??= CoverArtworkCacheService(
      libraryService: _service,
      databaseRepository: databaseRepository,
      audioDetailCacheService: detailCacheService,
      persistRetargetedManualCovers: _persistRetargetedManualCovers,
      isActiveCoverKey: isActiveCoverKey,
      onActiveCoverChanged: onActiveCoverChanged,
      preferEmbeddedCover: preferEmbeddedCover,
    );
  }

  void cancelPendingScanProgressNotification() {
    _service.scanProgressNotifyTimer?.cancel();
    _service.scanProgressNotifyTimer = null;
  }

  void trimMemory() {
    _coverArtworkCacheService?.trimMemory();
    detailCacheService.trimMemory();
  }

  void syncPresentationState({bool? isInitialized}) {
    _syncStateSlice(isInitialized: isInitialized);
  }

  @override
  void updateTrackDuration(String trackPath, Duration duration) {
    final currentTrack = _service.libraryByPath[trackPath];
    if (currentTrack == null ||
        currentTrack.duration > Duration.zero ||
        duration <= Duration.zero) {
      return;
    }
    final updatedTrack = currentTrack.copyWith(duration: duration);
    _service.libraryByPath[trackPath] = updatedTrack;
    final index = _service.libraryIndexByPath[trackPath];
    if (index != null) _service.library[index] = updatedTrack;
    if (_persistenceCoordinator.enabled) {
      unawaited(databaseRepository.updateTrackDurations({trackPath: duration}));
    }
  }

  Future<void> _persistRetargetedManualCovers(
    List<({MusicTrack original, String savedPath})> tracks,
  ) async {
    final updated = <MusicTrack>[
      for (final selection in tracks)
        if (_service.libraryByPath[selection.original.path] case final current?)
          if (current.manualCoverPath == selection.original.manualCoverPath)
            current.copyWith(manualCoverPath: selection.savedPath),
    ];
    _catalogWrites.addOrReplaceTracks(
      updated,
      mergeExistingState: false,
      persist: false,
      recordEntries: false,
    );
    if (_persistenceCoordinator.enabled) {
      await databaseRepository.updateTrackManualCoverPaths({
        for (final track in updated) track.path: track.manualCoverPath!,
      });
    }
  }

  Future<LibraryTreeSnapshot> ensureCardSnapshot() {
    return snapshotCacheService.cardSnapshot(onCommitted: _syncStateSlice);
  }

  void schedulePostStartupMaintenance() {
    final retainedPaths = _service.library
        .map((track) => track.path)
        .toList(growable: false);
    _startupMaintenanceCoordinator.schedule(retainedPaths);
  }

  Future<bool> _waitForContinuousUiIdle(Duration quietWindow) async {
    DateTime? idleSince;
    while (!_disposed) {
      if (_interactionPaused) {
        idleSince = null;
      } else {
        idleSince ??= DateTime.now();
        if (DateTime.now().difference(idleSince) >= quietWindow) return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    return false;
  }

  void _syncStateSlice({bool? isInitialized}) {
    final current = _service.slice.state;
    _service.syncSlice(
      isInitialized: isInitialized ?? current.isInitialized,
      detailRevision: detailCacheService.revision,
      treeSnapshotRevision: snapshotCacheService.cardSnapshotRevision,
      categorySnapshotRevision: snapshotCacheService.categorySnapshotRevision,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _metadataCoordinator.dispose();
    await _startupMaintenanceCoordinator.dispose();
    await detailCacheService.suspendAndWait();
    cancelPendingScanProgressNotification();
    await _coverArtworkCacheService?.dispose();
    await _service.dispose();
  }
}
