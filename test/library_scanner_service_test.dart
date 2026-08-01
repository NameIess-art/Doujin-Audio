import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';
import 'package:nameless_audio/features/library/application/library_catalog.dart';
import 'package:nameless_audio/features/library/application/library_scan_data_source.dart';
import 'package:nameless_audio/features/library/application/library_scanner_service.dart';
import 'package:nameless_audio/features/library/application/library_state_models.dart';
import 'package:nameless_audio/features/library/domain/library_entry.dart';

void main() {
  const labels = LibraryScanLabels(
    chooseMusicFolder: 'Choose folder',
    chooseLibraryFolder: 'Choose library',
    chooseAudioFiles: 'Choose files',
    importedFiles: 'Imported files',
    manuallySelectedFiles: 'Selected files',
  );

  test(
    'folder import scans a resolvable SAF source by file-system path',
    () async {
      final catalog = _RefreshCatalog(watchedFolders: const <String>[]);
      final dataSource = _ResolvedPickedFolderDataSource();

      await LibraryScannerService(
        dataSource: dataSource,
      ).addFolder(provider: catalog, labels: labels);

      expect(dataSource.permissionSources, <String>['C:/media/music']);
      expect(dataSource.scannedFolders, <String>['C:/media/music']);
      expect(catalog.watchedFolders, hasLength(1));
      expect(
        PathMatcher.equalsNormalized(
          catalog.watchedFolders.single,
          'C:/media/music',
        ),
        isTrue,
      );
    },
  );

  test(
    'library import scans a resolvable SAF source by file-system path',
    () async {
      final catalog = _RefreshCatalog(watchedFolders: const <String>[]);
      final dataSource = _ResolvedPickedFolderDataSource();

      await LibraryScannerService(
        dataSource: dataSource,
      ).addLibrary(provider: catalog, labels: labels);

      expect(dataSource.permissionSources, <String>['C:/media/music']);
      expect(dataSource.childFolderListings, hasLength(1));
      expect(
        PathMatcher.equalsNormalized(
          dataSource.childFolderListings.single,
          'C:/media/music',
        ),
        isTrue,
      );
      expect(dataSource.scannedFolders, hasLength(1));
      expect(
        PathMatcher.equalsNormalized(
          dataSource.scannedFolders.single,
          'C:/media/music',
        ),
        isTrue,
      );
      expect(catalog.watchedLibraries, hasLength(1));
      expect(
        PathMatcher.equalsNormalized(
          catalog.watchedLibraries.single,
          'C:/media/music',
        ),
        isTrue,
      );
    },
  );

  test(
    'folder import keeps the SAF source when file permission is denied',
    () async {
      final catalog = _RefreshCatalog(watchedFolders: const <String>[]);
      final dataSource = _ResolvedPickedFolderDataSource(
        permissionGranted: false,
      );

      await LibraryScannerService(
        dataSource: dataSource,
      ).addFolder(provider: catalog, labels: labels);

      expect(dataSource.permissionSources, <String>['C:/media/music']);
      expect(dataSource.scannedFolders, <String>[
        'content://storage/tree/music',
      ]);
    },
  );

  test(
    'file import always finishes scan when batch finalization fails',
    () async {
      final catalog = _FailingBatchCatalog();
      final scanner = LibraryScannerService(
        dataSource: _PickedFilesDataSource(),
      );

      await expectLater(
        scanner.addFiles(provider: catalog, labels: labels),
        throwsA(isA<StateError>()),
      );

      expect(catalog.isScanning, isFalse);
      expect(catalog.finishCount, 1);
    },
  );

  test(
    'refresh consumes native chunks without calling the full scan API',
    () async {
      final removed = _musicTrack('C:/music/removed.mp3');
      final catalog = _RefreshCatalog(
        watchedFolders: <String>['C:/music'],
        initialTracks: <MusicTrack>[removed],
      );
      final dataSource = _ChunkedRefreshDataSource(
        catalog: catalog,
        chunks: <FolderScanChunk>[
          FolderScanChunk(
            tracks: <ScannedTrack>[_scannedTrack('C:/music/one.mp3')],
            paths: <String>{PathMatcher.normalize('C:/music/one.mp3')},
          ),
          FolderScanChunk(
            tracks: <ScannedTrack>[_scannedTrack('C:/music/two.mp3')],
            paths: <String>{PathMatcher.normalize('C:/music/two.mp3')},
          ),
        ],
        terminalPaths: <String>{
          PathMatcher.normalize('C:/music/one.mp3'),
          PathMatcher.normalize('C:/music/two.mp3'),
        },
      );
      final scanner = LibraryScannerService(dataSource: dataSource);

      final outcome = await scanner.refreshWatchedFolders(
        provider: catalog,
        labels: labels,
      );

      expect(outcome.code, LibraryScanOutcomeCode.refreshAdded);
      expect(outcome.addedCount, 2);
      expect(dataSource.chunkedScanCalls, 1);
      expect(dataSource.fullScanCalls, 0);
      expect(dataSource.filesystemScanCalls, 0);
      expect(dataSource.firstChunkWasCommittedBeforeSecond, isTrue);
      expect(catalog.library, hasLength(2));
      expect(catalog.removedTrackPaths, <String>[removed.path]);
    },
  );

  test('incomplete refresh keeps tracks missing from the scan', () async {
    final existing = _musicTrack('C:/music/existing.mp3');
    final catalog = _RefreshCatalog(
      watchedFolders: <String>['C:/music'],
      initialTracks: <MusicTrack>[existing],
    );
    final dataSource = _ChunkedRefreshDataSource(
      catalog: catalog,
      terminalFailureCount: 1,
    );

    await LibraryScannerService(
      dataSource: dataSource,
    ).refreshWatchedFolders(provider: catalog, labels: labels);

    expect(catalog.library, <MusicTrack>[existing]);
    expect(catalog.removedTrackPaths, isEmpty);
    expect(catalog.scanFailureCount, 1);
  });

  test('content URI refresh retains the legacy full-scan fallback', () async {
    const root = 'content://library/tree';
    final catalog = _RefreshCatalog(watchedFolders: <String>[root]);
    final dataSource = _ChunkedRefreshDataSource(
      catalog: catalog,
      nativeChunkingSupported: false,
      legacyResult: NativeScanResult.success(
        <ScannedTrack>[_scannedTrack('$root/one.mp3')],
        <String>{PathMatcher.normalize('$root/one.mp3')},
        completenessKnown: true,
      ),
    );

    await LibraryScannerService(
      dataSource: dataSource,
    ).refreshWatchedFolders(provider: catalog, labels: labels);

    expect(dataSource.fullScanCalls, 1);
    expect(dataSource.filesystemScanCalls, 0);
    expect(catalog.library, hasLength(1));
  });

  test(
    'generation cancellation stops chunks and rolls back additions',
    () async {
      final existing = _musicTrack('C:/music/existing.mp3');
      final catalog = _RefreshCatalog(
        watchedFolders: <String>['C:/music'],
        initialTracks: <MusicTrack>[existing],
        cancelAfterTrackChunk: 2,
      );
      final dataSource = _ChunkedRefreshDataSource(
        catalog: catalog,
        chunks: <FolderScanChunk>[
          FolderScanChunk(
            tracks: <ScannedTrack>[_scannedTrack('C:/music/one.mp3')],
            paths: <String>{PathMatcher.normalize('C:/music/one.mp3')},
          ),
          FolderScanChunk(
            tracks: <ScannedTrack>[_scannedTrack('C:/music/two.mp3')],
            paths: <String>{PathMatcher.normalize('C:/music/two.mp3')},
          ),
          FolderScanChunk(
            tracks: <ScannedTrack>[_scannedTrack('C:/music/three.mp3')],
            paths: <String>{PathMatcher.normalize('C:/music/three.mp3')},
          ),
        ],
        terminalPaths: <String>{
          PathMatcher.normalize('C:/music/one.mp3'),
          PathMatcher.normalize('C:/music/two.mp3'),
        },
      );

      final outcome = await LibraryScannerService(
        dataSource: dataSource,
      ).refreshWatchedFolders(provider: catalog, labels: labels);

      expect(outcome.code, LibraryScanOutcomeCode.cancelled);
      expect(dataSource.deliveredChunks, 2);
      expect(catalog.library, <MusicTrack>[existing]);
      expect(catalog.stagedBatchDepth, 0);
      expect(catalog.stagedBatchBeginCount, 1);
      expect(catalog.stagedBatchFinishCount, 1);
      expect(catalog.rollbackBatchDepth, 0);
      expect(catalog.rollbackBatchBeginCount, 1);
      expect(catalog.rollbackBatchEndCount, 1);
    },
  );
}

ScannedTrack _scannedTrack(String path) {
  final parent = path.substring(0, path.lastIndexOf('/'));
  return ScannedTrack(
    path: path,
    groupKey: parent,
    groupTitle: 'music',
    groupSubtitle: parent,
    isSingle: false,
    isVideo: false,
  );
}

MusicTrack _musicTrack(String path) {
  final parent = path.substring(0, path.lastIndexOf('/'));
  return MusicTrack(
    path: path,
    displayName: 'existing',
    groupKey: parent,
    groupTitle: 'music',
    groupSubtitle: parent,
    isSingle: false,
  );
}

class _ChunkedRefreshDataSource implements LibraryScanDataSource {
  _ChunkedRefreshDataSource({
    required this.catalog,
    this.chunks = const <FolderScanChunk>[],
    this.terminalPaths = const <String>{},
    this.terminalFailureCount = 0,
    this.nativeChunkingSupported = true,
    NativeScanResult? legacyResult,
  }) : legacyResult =
           legacyResult ??
           NativeScanResult.failed(code: 'unexpected_full_scan');

  final _RefreshCatalog catalog;
  final List<FolderScanChunk> chunks;
  final Set<String> terminalPaths;
  final int terminalFailureCount;
  final bool nativeChunkingSupported;
  final NativeScanResult legacyResult;
  var chunkedScanCalls = 0;
  var fullScanCalls = 0;
  var filesystemScanCalls = 0;
  var deliveredChunks = 0;
  var firstChunkWasCommittedBeforeSecond = false;

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async {
    return true;
  }

  @override
  Future<NativeScanResult> scanFolder(String folderPath) async {
    fullScanCalls++;
    return legacyResult;
  }

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) async {
    chunkedScanCalls++;
    if (!nativeChunkingSupported) {
      return NativeScanResult.notSupported();
    }
    return _deliverChunks(onChunk);
  }

  @override
  Future<NativeScanResult> scanFileSystemFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk,
  ) {
    filesystemScanCalls++;
    return _deliverChunks(onChunk);
  }

  Future<NativeScanResult> _deliverChunks(
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk,
  ) async {
    final deliveredPaths = <String>{};
    for (var index = 0; index < chunks.length; index++) {
      final keepGoing = await onChunk(chunks[index]);
      deliveredChunks++;
      deliveredPaths.addAll(chunks[index].paths);
      if (index == 0 && chunks.length > 1) {
        firstChunkWasCommittedBeforeSecond = catalog.library.any(
          (track) => PathMatcher.equalsNormalized(
            track.path,
            chunks.first.tracks.first.path,
          ),
        );
      }
      if (!keepGoing) {
        return NativeScanResult.success(
          const <ScannedTrack>[],
          deliveredPaths,
          completenessKnown: true,
          wasCancelled: true,
        );
      }
    }
    return NativeScanResult.success(
      const <ScannedTrack>[],
      terminalPaths,
      failureCount: terminalFailureCount,
      completenessKnown: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RefreshCatalog implements LibraryCatalog {
  _RefreshCatalog({
    required List<String> watchedFolders,
    List<MusicTrack> initialTracks = const <MusicTrack>[],
    this.cancelAfterTrackChunk,
  }) : watchedFolders = List<String>.of(watchedFolders),
       library = List<MusicTrack>.of(initialTracks);

  @override
  final List<MusicTrack> library;

  @override
  final List<String> watchedFolders;

  @override
  final List<String> watchedLibraries = <String>[];
  final int? cancelAfterTrackChunk;

  @override
  bool isScanning = false;

  @override
  int scanFoundCount = 0;

  @override
  int scanDuplicateCount = 0;

  @override
  int scanFailureCount = 0;

  final removedTrackPaths = <String>[];
  int _generation = 0;
  var _appliedTrackChunks = 0;
  var stagedBatchDepth = 0;
  var stagedBatchBeginCount = 0;
  var stagedBatchFinishCount = 0;
  var rollbackBatchDepth = 0;
  var rollbackBatchBeginCount = 0;
  var rollbackBatchEndCount = 0;

  @override
  int tryBeginScan({required String source, bool background = false}) {
    isScanning = true;
    return _generation = 1;
  }

  @override
  bool isScanGenerationActive(int generation) {
    return isScanning && generation == _generation;
  }

  @override
  void finishScan(int generation) {
    if (generation != _generation) return;
    isScanning = false;
    _generation = 0;
  }

  @override
  MusicTrack? trackByPath(String trackPath) {
    for (final track in library) {
      if (PathMatcher.equalsNormalized(track.path, trackPath)) return track;
    }
    return null;
  }

  @override
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) {
    return const <LibraryEntry>[];
  }

  @override
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) {
    return LibraryEntrySnapshot(libraryPath: libraryPath);
  }

  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) {
    return LibraryExclusionMatcher(libraryPath: libraryPath);
  }

  @override
  bool isLibraryPathExcluded(String libraryPath, String entityPath) => false;

  @override
  void beginStagedLibraryRefresh() {
    stagedBatchDepth++;
    stagedBatchBeginCount++;
  }

  @override
  Future<void> finishStagedLibraryRefresh({
    bool waitForPersistence = false,
  }) async {
    stagedBatchDepth--;
    stagedBatchFinishCount++;
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
    final before = library.length;
    for (final track in tracks) {
      library.removeWhere(
        (existing) => PathMatcher.equalsNormalized(existing.path, track.path),
      );
      library.add(track);
    }
    if (tracks.isNotEmpty &&
        cancelAfterTrackChunk != null &&
        ++_appliedTrackChunks == cancelAfterTrackChunk) {
      isScanning = false;
    }
    final pathsToRemove = removeTrackPaths.toList(growable: false);
    removedTrackPaths.addAll(pathsToRemove);
    library.removeWhere(
      (track) => pathsToRemove.any(
        (trackPath) => PathMatcher.equalsNormalized(track.path, trackPath),
      ),
    );
    for (final folder in removeWatchedFolders) {
      watchedFolders.removeWhere(
        (candidate) => PathMatcher.equalsNormalized(candidate, folder),
      );
    }
    for (final folder in addWatchedFolders) {
      if (!watchedFolders.any(
        (candidate) => PathMatcher.equalsNormalized(candidate, folder),
      )) {
        watchedFolders.add(folder);
      }
    }
    return library.length - before;
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
    scanFoundCount = foundCount ?? scanFoundCount;
    scanDuplicateCount = duplicateCount ?? scanDuplicateCount;
    scanFailureCount = failureCount ?? scanFailureCount;
  }

  @override
  void beginLibraryBatch() {
    rollbackBatchDepth++;
    rollbackBatchBeginCount++;
  }

  @override
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) async {
    rollbackBatchDepth--;
    rollbackBatchEndCount++;
  }

  @override
  void removeTracksByPath(Iterable<String> trackPaths) {
    final paths = trackPaths.toList(growable: false);
    library.removeWhere(
      (track) => paths.any(
        (candidate) => PathMatcher.equalsNormalized(candidate, track.path),
      ),
    );
  }

  @override
  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {}

  @override
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) {}

  @override
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {}

  @override
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {}

  @override
  void addWatchedFolder(String folderPath, {bool notify = true}) {
    watchedFolders.add(folderPath);
  }

  @override
  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    watchedLibraries.add(folderPath);
  }

  @override
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PickedFilesDataSource implements LibraryScanDataSource {
  @override
  Future<List<PickedAudioFile>?> pickAudioFiles({required String dialogTitle}) {
    return Future<List<PickedAudioFile>?>.value(const <PickedAudioFile>[
      PickedAudioFile(uri: 'content://audio/track.mp3', name: 'track.mp3'),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResolvedPickedFolderDataSource implements LibraryScanDataSource {
  _ResolvedPickedFolderDataSource({this.permissionGranted = true});

  final bool permissionGranted;
  final permissionSources = <String>[];
  final scannedFolders = <String>[];
  final childFolderListings = <String>[];

  @override
  Future<String?> pickAudioFolder({required String dialogTitle}) async {
    return 'content://storage/tree/music';
  }

  @override
  Future<String> resolveRestorablePath(String source) async {
    return source == 'content://storage/tree/music' ? 'C:/media/music' : source;
  }

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async {
    permissionSources.addAll(sources);
    return permissionGranted;
  }

  @override
  Future<bool> sourceExists(String source) async => source == 'C:/media/music';

  @override
  Future<LibraryChildFolderListing> listImmediateChildFolders(
    String folderPath,
  ) async {
    childFolderListings.add(folderPath);
    return (folders: const <String>[], complete: true);
  }

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) async {
    scannedFolders.add(folderPath);
    return NativeScanResult.success(
      const <ScannedTrack>[],
      const <String>{},
      completenessKnown: true,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingBatchCatalog implements LibraryCatalog {
  @override
  final List<MusicTrack> library = <MusicTrack>[];

  @override
  final List<String> watchedFolders = <String>[];

  @override
  final List<String> watchedLibraries = <String>[];

  @override
  bool isScanning = false;

  int finishCount = 0;
  int _generation = 0;

  @override
  int tryBeginScan({required String source, bool background = false}) {
    isScanning = true;
    return _generation = 1;
  }

  @override
  bool isScanGenerationActive(int generation) {
    return isScanning && generation == _generation;
  }

  @override
  void beginLibraryBatch() {}

  @override
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    library.addAll(tracks);
  }

  @override
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) {
    return Future<void>.error(StateError('persistence failed'));
  }

  @override
  void finishScan(int generation) {
    if (generation != _generation) return;
    finishCount++;
    isScanning = false;
    _generation = 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
