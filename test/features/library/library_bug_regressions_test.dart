import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/library_catalog.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_coordinator.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_sorting.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_projection.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _scanLabels = LibraryScanLabels(
  chooseMusicFolder: 'music',
  chooseLibraryFolder: 'library',
  chooseAudioFiles: 'files',
  importedFiles: 'imported',
  manuallySelectedFiles: 'selected',
);

MusicTrack _track(
  String trackPath, {
  String? groupKey,
  Duration duration = Duration.zero,
}) {
  final resolvedGroup = groupKey ?? PathMatcher.parentPath(trackPath) ?? '';
  return MusicTrack(
    path: trackPath,
    displayName: path.basenameWithoutExtension(trackPath),
    groupKey: resolvedGroup,
    groupTitle: path.basename(resolvedGroup),
    groupSubtitle: resolvedGroup,
    isSingle: false,
    duration: duration,
    scannedAt: DateTime(2026),
  );
}

Future<({Database db, SqliteLibraryRepository repo, LibraryFacade library})>
_createLibraryFixture() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await AppDatabase.createSchemaForTest(db);
  final repo = SqliteLibraryRepository(database: AppDatabase.test(db));
  final library = LibraryFacade.create(databaseRepository: repo)
    ..configureCoverArtworkRuntime(
      isActiveCoverKey: (_) => false,
      onActiveCoverChanged: () {},
    );
  return (db: db, repo: repo, library: library);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late SqliteLibraryRepository repo;
  late LibraryFacade library;

  setUp(() async {
    final created = await _createLibraryFixture();
    db = created.db;
    repo = created.repo;
    library = created.library;
  });

  tearDown(() async {
    await library.dispose();
    await db.close();
  });

  test(
    '#3 resetPersistedState waits for scanIdle and clears staged refresh batch state',
    () async {
      const folder = 'C:\\Library\\WorkA';
      final original = _track('C:\\Library\\WorkA\\01.mp3', groupKey: folder);
      library.addWatchedFolder(folder);
      library.addTracks([original]);

      final generation = library.tryBeginScan(source: 'refresh');
      expect(generation, isPositive);
      library.beginStagedLibraryRefresh();
      library.applyStagedLibraryRefreshChunk(
        sourceFolderPath: folder,
        libraryRoot: folder,
        tracks: [_track('C:\\Library\\WorkA\\02.mp3', groupKey: folder)],
      );

      var resetCompleted = false;
      final resetFuture = library.resetPersistedState().then((_) {
        resetCompleted = true;
      });
      await pumpEventQueue();
      expect(resetCompleted, isFalse);

      await library.finishStagedLibraryRefresh(commit: false);
      library.finishScan(generation);
      await resetFuture;

      expect(resetCompleted, isTrue);
      expect(library.library, isEmpty);
      expect(library.watchedFolders, isEmpty);

      // Subsequent rollback call must be a no-op since batch state was cleared.
      await library.finishStagedLibraryRefresh(commit: false);
      expect(library.library, isEmpty);
    },
  );

  test(
    '#4 refreshWatchedFolders rolls back and skips cleanup when a later folder throws',
    () async {
      const folderA = 'C:\\RefreshErr\\WorkA';
      const folderB = 'C:\\RefreshErr\\WorkB';
      final staleInA = _track(
        'C:\\RefreshErr\\WorkA\\stale.mp3',
        groupKey: folderA,
      );
      final keptInA = _track(
        'C:\\RefreshErr\\WorkA\\kept.mp3',
        groupKey: folderA,
      );
      final keptInB = _track(
        'C:\\RefreshErr\\WorkB\\b.mp3',
        groupKey: folderB,
      );
      library.addWatchedFolder(folderA);
      library.addWatchedFolder(folderB);
      library.addTracks([staleInA, keptInA, keptInB]);

      final scanner = LibraryScannerService(
        dataSource: _ThrowingSecondFolderScanDataSource(
          firstFolder: folderA,
          firstFolderTracks: [keptInA],
          throwingFolder: folderB,
        ),
      );

      await expectLater(
        scanner.refreshWatchedFolders(provider: library, labels: _scanLabels),
        throwsA(isA<StateError>()),
      );

      expect(
        library.library.map((track) => track.path),
        containsAll(<String>[staleInA.path, keptInA.path, keptInB.path]),
      );
    },
  );

  test(
    '#24 updateTrackDuration and updatePlaybackHistory stay safe during batch and sync tracksByGroup + SQLite',
    () async {
      library.configurePersistence(enabled: true);
      const group = 'C:\\BatchDur\\Work';
      final first = _track('C:\\BatchDur\\Work\\01.mp3', groupKey: group);
      final second = _track('C:\\BatchDur\\Work\\02.mp3', groupKey: group);
      library.addWatchedFolder(group);
      library.addTracks([first, second]);
      await library.flushPendingPersistence();

      // Remove the first track inside a batch so libraryIndexByPath for second is stale.
      library.beginLibraryBatch(snapshotAllEntries: false);
      library.removeTracksByPath([first.path]);

      // Call with different casing on Windows; must not throw RangeError and must update canonical path.
      library.updateTrackDuration(
        'c:\\batchdur\\work\\02.mp3',
        const Duration(seconds: 95),
      );
      expect(
        library.trackByPath(second.path)?.duration,
        const Duration(seconds: 95),
      );
      expect(
        library
            .tracksInGroup(group)
            .firstWhere((track) => track.path == second.path)
            .duration,
        const Duration(seconds: 95),
      );

      await library.endLibraryBatch();
      await pumpEventQueue();
      expect(
        library.trackByPath(second.path)?.duration,
        const Duration(seconds: 95),
      );
      final persisted = await repo.loadTrackDetail(second.path);
      expect(persisted?.duration, const Duration(seconds: 95));

      final playedAt = DateTime(2026, 5, 1, 12);
      library.updatePlaybackHistory(
        trackPath: 'c:\\batchdur\\work\\02.mp3',
        position: const Duration(seconds: 40),
        now: playedAt,
        updatePlayedAt: true,
      );
      final groupTrack = library
          .tracksInGroup(group)
          .firstWhere((track) => track.path == second.path);
      expect(groupTrack.lastPlayedPosition, const Duration(seconds: 40));
      expect(groupTrack.lastPlayedAt, playedAt);
    },
  );

  test(
    '#25 renaming work folder inside watched library retargets library_entries in memory and SQLite',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'lib_retarget_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final libRoot = PathMatcher.normalize(tempRoot.path);
      final workDir = Directory(path.join(libRoot, 'RJ12345'))..createSync();
      final audioFile = File(path.join(workDir.path, '01.mp3'))
        ..writeAsBytesSync(const [1, 2, 3]);

      library.configurePersistence(enabled: true);
      final oldWorkPath = PathMatcher.normalize(workDir.path);
      final oldTrackPath = PathMatcher.normalize(audioFile.path);
      final track = _track(oldTrackPath, groupKey: oldWorkPath);

      library.addWatchedLibrary(libRoot);
      library.addWatchedFolder(oldWorkPath);
      library.addTracks([track]);
      library.recordLibraryEntriesForTracks(
        libRoot,
        [track],
        folderPaths: [oldWorkPath],
      );
      await library.flushPendingPersistence();

      final detail = AudioDetail.empty(
        AudioDetailTarget.libraryRootFolder(oldWorkPath),
      ).copyWith(workTitle: 'RJ12345');
      final result = await library.renameAudioDetailTargetToName(
        detail,
        'RJ12345_Renamed',
      );
      expect(result.renamed, isTrue);

      final expectedNewWork = PathMatcher.normalize(
        path.join(libRoot, 'RJ12345_Renamed'),
      );
      final expectedNewTrack = PathMatcher.normalize(
        path.join(expectedNewWork, '01.mp3'),
      );

      final memEntries = library.libraryEntriesForLibrary(libRoot);
      expect(
        memEntries.any(
          (entry) => PathMatcher.equalsNormalized(entry.path, expectedNewTrack),
        ),
        isTrue,
      );
      expect(
        memEntries.any(
          (entry) => PathMatcher.equalsNormalized(entry.path, oldTrackPath),
        ),
        isFalse,
      );

      final libEntries = await repo.loadLibraryEntries(libRoot);
      expect(
        libEntries.any(
          (entry) => PathMatcher.equalsNormalized(entry.path, expectedNewTrack),
        ),
        isTrue,
      );
      expect(
        libEntries.any(
          (entry) => PathMatcher.equalsNormalized(entry.path, oldTrackPath),
        ),
        isFalse,
      );
    },
  );

  test(
    '#26 applyStagedLibraryRefreshChunk does not resurrect Android SAF tracks under excluded folder',
    () async {
      const root = 'content://provider/tree/primary%3ALibrary';
      const excludedSub = '$root::WorkA/Bonus';
      const opaqueTrack = '$root/document/opaque-track-id-99';

      library.addWatchedLibrary(root);
      library.excludeLibraryFolder(root, excludedSub);

      final track = _track(opaqueTrack, groupKey: excludedSub);
      library.beginStagedLibraryRefresh();
      library.applyStagedLibraryRefreshChunk(
        sourceFolderPath: root,
        libraryRoot: root,
        tracks: [track],
        entryTracks: [track],
      );
      await library.finishStagedLibraryRefresh();

      expect(library.trackByPath(opaqueTrack), isNull);
    },
  );

  test(
    '#27 removing standalone watched folder permanently clears its exclusions in memory and SQLite',
    () async {
      library.configurePersistence(enabled: true);
      const folder = 'C:\\StandaloneExcl\\Work';
      const sub = 'C:\\StandaloneExcl\\Work\\Bonus';
      const trackA = 'C:\\StandaloneExcl\\Work\\01.mp3';
      const trackB = 'C:\\StandaloneExcl\\Work\\Bonus\\02.mp3';

      library.addWatchedFolder(folder);
      library.addTracks([
        _track(trackA, groupKey: folder),
        _track(trackB, groupKey: sub),
      ]);
      library.excludeLibraryFolder(folder, sub);
      library.excludeLibraryTrack(folder, trackA);
      await library.flushPendingPersistence();
      expect(library.hasLibraryExclusions(folder), isTrue);

      await library.removeFolder(folder);
      expect(library.hasLibraryExclusions(folder), isFalse);
      expect(library.isLibraryPathExcluded(folder, sub), isFalse);
      expect(library.isLibraryPathExcluded(folder, trackA), isFalse);

      // Reload from the same SQLite DB to confirm exclusions were persisted as cleared.
      final reloaded = LibraryFacade.create(databaseRepository: repo)
        ..configureCoverArtworkRuntime(
          isActiveCoverKey: (_) => false,
          onActiveCoverChanged: () {},
        );
      addTearDown(reloaded.dispose);
      await reloaded.loadPersistedState();
      expect(reloaded.hasLibraryExclusions(folder), isFalse);
    },
  );

  test(
    '#49 LibraryScanCoordinator rejects re-entrant invocation without dropping active scan post-processing',
    () async {
      final firstPending = Completer<LibraryScanOutcome>();
      final scanner = _ControllableScanner(
        onRefresh: () => firstPending.future,
        onAddFolder: () async => null,
      );
      final coordinator = LibraryScanCoordinator(scanner: scanner);
      final catalog = _FakeScanCatalog();
      addTearDown(coordinator.dispose);

      final activeRefresh = coordinator.refresh(
        catalog: catalog,
        labels: _scanLabels,
      );
      await pumpEventQueue();

      final reentrantOutcome = await coordinator.importFolder(
        catalog: catalog,
        labels: _scanLabels,
      );
      expect(reentrantOutcome?.code, LibraryScanOutcomeCode.alreadyRunning);
      expect(scanner.addFolderCalls, 0);
      expect(coordinator.state.phase, LibraryScanPhase.running);

      firstPending.complete(
        LibraryScanOutcome(
          code: LibraryScanOutcomeCode.refreshAdded,
          source: 'refresh',
          details: const <String, Object?>{'count': 1},
        ),
      );
      final outcome = await activeRefresh;
      expect(outcome?.code, LibraryScanOutcomeCode.refreshAdded);
      expect(catalog.detailImportCount, 1);
      expect(catalog.durationBackfillCount, 1);
    },
  );

  test(
    '#50 cancelled _addLibraryFromPath rollback preserves existing entries across Windows casing',
    () async {
      const libRoot = 'C:\\CaseRollbackLib';
      const existingTrackPath = 'C:\\CaseRollbackLib\\WorkA\\01.mp3';
      const existingWork = 'C:\\CaseRollbackLib\\WorkA';
      library.recordLibraryEntriesForTracks(
        libRoot,
        [_track(existingTrackPath, groupKey: existingWork)],
        folderPaths: [existingWork],
      );

      final scanner = LibraryScannerService(
        dataSource: _FailingLibraryImportDataSource(
          selectedPath: 'c:\\caserollbacklib',
        ),
      );
      final outcome = await scanner.addLibrary(
        provider: library,
        labels: _scanLabels,
      );
      expect(outcome?.code, LibraryScanOutcomeCode.failed);

      final remaining = library.libraryEntriesForLibrary(libRoot);
      expect(
        remaining.any(
          (entry) =>
              PathMatcher.equalsNormalized(entry.path, existingTrackPath),
        ),
        isTrue,
      );
    },
  );

  test(
    '#51 renameWorkEntryToName retargets manual cover in _folderCoverSelections and AudioDetail',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'cover_rename_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final workPath = PathMatcher.normalize(tempRoot.path);
      final oldCover = File(path.join(workPath, 'cover.jpg'))
        ..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);

      library.configurePersistence(enabled: true);
      library.addWatchedFolder(workPath);

      final oldCoverNormalized = PathMatcher.normalize(oldCover.path);
      final savedCover = await library.setFolderManualCover(
        workPath,
        oldCoverNormalized,
      );
      expect(savedCover, isNotNull);

      // Trigger rename with mismatched casing on Windows.
      final renamed = await library.renameWorkEntryToName(
        libraryRootPath: workPath,
        entryPath: oldCoverNormalized.toLowerCase(),
        targetName: 'poster',
        isMedia: false,
        isDirectory: false,
      );
      final expectedNewCover = PathMatcher.normalize(
        path.join(workPath, 'poster.jpg'),
      );
      expect(PathMatcher.equalsNormalized(renamed, expectedNewCover), isTrue);

      final reloadedDetail = await library.loadAudioDetail(
        AudioDetailTarget.libraryRootFolder(workPath),
      );
      expect(
        PathMatcher.equalsNormalized(
          reloadedDetail.detail.cardCoverPath ?? '',
          expectedNewCover,
        ),
        isTrue,
      );
    },
  );

  test(
    '#53 LibraryEditTreeProjection deduplicates and retains Windows paths across casing differences',
    () async {
      const root = 'C:\\CaseEditLib';
      final request = LibraryEditTreeRequest(
        libraryPath: root,
        tracks: [
          _track(
            'C:\\CaseEditLib\\WorkA\\01.mp3',
            groupKey: 'C:\\CaseEditLib\\WorkA',
          ),
        ],
        diskTrackPaths: const ['c:\\caseeditlib\\worka\\01.mp3'],
        diskTrackPathSet: const {'c:\\caseeditlib\\worka\\01.mp3'},
        diskTrackParents: const {
          'c:\\caseeditlib\\worka\\01.mp3': 'c:\\caseeditlib\\worka',
        },
        liveFolders: const {'c:\\caseeditlib\\worka'},
        authoritative: true,
        excludedTracks: const [],
        excludedFolders: const [],
        entries: [
          LibraryEntry.folder(
            libraryPath: root,
            path: 'C:\\CaseEditLib\\WorkA',
            parentPath: root,
            state: LibraryEntryState.active,
            displayName: 'WorkA',
          ),
        ],
        childFolders: const ['C:\\CaseEditLib\\WorkA', 'c:\\caseeditlib\\worka'],
        restoringFolders: const [],
      );

      final snapshot = await request.project();
      expect(snapshot.nodes, hasLength(1));
      final folder = snapshot.nodes.single as LibraryEditFolderTreeNode;
      expect(folder.children, hasLength(1));
    },
  );

  test(
    '#55 pinned sorting, category filtering, and exportTimeSegmentLabels match Windows casing',
    () async {
      final nodeA = FolderNode('WorkA', 'C:\\PinnedLib\\WorkA');
      final nodeB = FolderNode('WorkB', 'C:\\PinnedLib\\WorkB');

      final payload = await LibrarySortRequest(
        nodes: [nodeA, nodeB],
        criterion: LibrarySortCriterion.name,
        ascending: true,
        groupByLibrary: false,
        pinnedPaths: const {'c:\\pinnedlib\\workb'},
      ).toPayload();
      final indices = buildLibrarySortedIndices(payload);
      expect(indices, [1, 0]);

      final targetA = AudioDetailTarget.libraryRootFolder(
        'C:\\PinnedLib\\WorkA',
      );
      final targetB = AudioDetailTarget.libraryRootFolder(
        'C:\\PinnedLib\\WorkB',
      );
      final categorySnapshot = AudioLibraryCategorySnapshot(
        entries: [
          AudioLibraryCategoryEntry(
            target: targetA,
            title: 'WorkA',
            path: targetA.targetPath,
            isFolder: true,
            detail: AudioDetail.empty(targetA).copyWith(workTitle: 'WorkA'),
            tracks: const [],
          ),
          AudioLibraryCategoryEntry(
            target: targetB,
            title: 'WorkB',
            path: targetB.targetPath,
            isFolder: true,
            detail: AudioDetail.empty(targetB).copyWith(workTitle: 'WorkB'),
            tracks: const [],
          ),
        ],
        structureRevision: 1,
        detailRevision: 1,
      );
      final filtered = filterLibraryCategoryEntries((
        snapshot: categorySnapshot,
        category: AudioLibraryCategoryType.all,
        queryTerms: const [],
        termKeywords: const [],
        selectedTerms: const {},
        pinnedPaths: const {'c:\\pinnedlib\\workb'},
      ));
      expect(
        filtered.entries.map((entry) => entry.title).toList(),
        ['WorkB', 'WorkA'],
      );

      // Verify exportTimeSegmentLabels finds track case-insensitively.
      final tempDir = await Directory.systemTemp.createTemp('seg_export_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final workPath = PathMatcher.normalize(tempDir.path);
      final trackPath = PathMatcher.normalize(path.join(workPath, '01.mp3'));
      File(trackPath).writeAsBytesSync(const [1, 2, 3]);
      library.addWatchedFolder(workPath);
      library.addTracks([_track(trackPath, groupKey: workPath)]);
      final exported = await library.exportTimeSegmentLabels(
        trackPath.toLowerCase(),
      );
      expect(exported, isTrue);
    },
  );
}

final class _ThrowingSecondFolderScanDataSource
    extends PlatformLibraryScanDataSource {
  _ThrowingSecondFolderScanDataSource({
    required this.firstFolder,
    required this.firstFolderTracks,
    required this.throwingFolder,
  });

  final String firstFolder;
  final List<MusicTrack> firstFolderTracks;
  final String throwingFolder;

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async =>
      true;

  @override
  Future<bool> sourceExists(String sourcePath) async => true;

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    void Function(FolderScanSessionEvent event)? onProgress,
  }) async {
    if (PathMatcher.equalsNormalized(folderPath, throwingFolder)) {
      throw StateError('Simulated unexpected scan failure');
    }
    final tracks = [
      for (final track in firstFolderTracks)
        ScannedTrack(
          path: track.path,
          displayName: track.displayName,
          groupKey: track.groupKey,
          groupTitle: track.groupTitle,
          groupSubtitle: track.groupSubtitle,
          isSingle: track.isSingle,
          isVideo: track.isVideo,
        ),
    ];
    final paths = {for (final track in firstFolderTracks) track.path};
    await onChunk(FolderScanChunk(tracks: tracks, paths: paths));
    return NativeScanResult.success(
      const <ScannedTrack>[],
      paths,
      completenessKnown: true,
    );
  }
}

final class _FailingLibraryImportDataSource
    extends PlatformLibraryScanDataSource {
  _FailingLibraryImportDataSource({required this.selectedPath});

  final String selectedPath;

  @override
  Future<String?> pickAudioFolder({required String dialogTitle}) async =>
      selectedPath;

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async =>
      true;

  @override
  Future<bool> sourceExists(String sourcePath) async => true;

  @override
  Future<({List<String> folders, bool complete})> listImmediateChildFolders(
    String folderPath,
  ) async => (folders: const <String>[], complete: false);
}

final class _ControllableScanner extends LibraryScannerService {
  _ControllableScanner({
    required this.onRefresh,
    required this.onAddFolder,
  });

  final Future<LibraryScanOutcome> Function() onRefresh;
  final Future<LibraryScanOutcome?> Function() onAddFolder;
  int addFolderCalls = 0;

  @override
  Future<LibraryScanOutcome> refreshWatchedFolders({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
    void Function(int generation)? onScanStarted,
  }) => onRefresh();

  @override
  Future<LibraryScanOutcome?> addFolder({
    required LibraryCatalog provider,
    required LibraryScanLabels labels,
  }) {
    addFolderCalls++;
    return onAddFolder();
  }
}

final class _FakeScanCatalog implements LibraryCatalog {
  int detailImportCount = 0;
  int durationBackfillCount = 0;

  @override
  void cancelScan() {}

  @override
  Future<AudioDetailBackupImportResult> importAudioDetailBackups({
    bool onlyMissing = false,
  }) async {
    detailImportCount++;
    return const AudioDetailBackupImportResult();
  }

  @override
  Future<void> backfillMissingLibraryDurations({
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    durationBackfillCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
