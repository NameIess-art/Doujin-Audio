import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scan_models.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_persistence_coordinator.dart';
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('renamed watched descendants survive persisted state reload', () async {
    final repository = _RestoredLibraryRepository();
    final service = LibraryService();
    addTearDown(service.dispose);
    service.watchedFolders.addAll([r'C:\Old\Child', r'C:\Old\Child\Nested']);
    service.watchedLibraries.addAll([r'C:\Old', r'C:\Old\Child']);
    service.retargetLibraryFolder(r'C:\Old', r'C:\New', 'New');
    final persistence = LibraryPersistenceCoordinator(
      repository: repository,
      service: service,
    );
    await persistence.saveWatchedFolders();
    await persistence.saveWatchedLibraries();
    final restored = LibraryFacade.create(databaseRepository: repository);
    addTearDown(restored.dispose);
    await restored.loadPersistedState();
    expect(restored.watchedFolders, [r'C:\New\Child', r'C:\New\Child\Nested']);
    expect(restored.watchedLibraries, [r'C:\New', r'C:\New\Child']);
  });

  test('import batch commits only the final watched directory lists', () async {
    final repository = _RestoredLibraryRepository();
    final facade = LibraryFacade.create(databaseRepository: repository);
    addTearDown(facade.dispose);
    facade.beginLibraryBatch();
    facade.addWatchedLibrary('/library', notify: false);
    for (var index = 0; index < 500; index++) {
      facade.addWatchedFolder('/library/$index', notify: false);
    }
    expect(repository.commits, 0);
    await facade.endLibraryBatch();
    expect(repository.commits, 1);
    expect(
      jsonDecode(repository.settings['watched_folders_v1']!),
      hasLength(500),
    );
    expect(jsonDecode(repository.settings['watched_libraries_v1']!), [
      '/library',
    ]);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('watched_folders_v1'), isNull);
  });

  test(
    'failed catalog commit restores watched directories and allows retry',
    () async {
      final repository = _RestoredLibraryRepository()..rejectCommit = true;
      final facade = LibraryFacade.create(databaseRepository: repository);
      addTearDown(facade.dispose);
      facade.beginLibraryBatch();
      facade.addWatchedLibrary('/library', notify: false);
      await expectLater(facade.endLibraryBatch(), throwsStateError);
      expect(facade.watchedLibraries, isEmpty);
      expect(repository.settings, isEmpty);
      repository.rejectCommit = false;
      facade.beginLibraryBatch();
      facade.addWatchedLibrary('/retry', notify: false);
      await facade.endLibraryBatch();
      expect(facade.watchedLibraries, ['/retry']);
      expect(jsonDecode(repository.settings['watched_libraries_v1']!), [
        '/retry',
      ]);
    },
  );

  test(
    'legacy roots migrate to SQLite and override stale preferences on reload',
    () async {
      SharedPreferences.setMockInitialValues({
        'watched_folders_v1': '["/old"]',
      });
      final repository = _RestoredLibraryRepository();
      final first = LibraryFacade.create(databaseRepository: repository);
      addTearDown(first.dispose);
      await first.loadPersistedState();
      expect(first.watchedFolders, ['/old']);
      first.beginLibraryBatch();
      first.removeWatchedFolder('/old');
      first.addWatchedFolder('/new');
      await first.endLibraryBatch();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('watched_folders_v1', '{broken legacy value');
      final second = LibraryFacade.create(databaseRepository: repository);
      addTearDown(second.dispose);
      await second.loadPersistedState();
      expect(second.watchedFolders, ['/new']);
    },
  );

  test(
    'failed batch restores overwritten and removed tracks and entry tree',
    () async {
      final repository = _RestoredLibraryRepository()..rejectCommit = true;
      final original = MusicTrack(
        path: '/existing/01.mp3',
        displayName: 'original',
        groupKey: '/existing',
        groupTitle: 'Existing',
        groupSubtitle: '',
        isSingle: false,
      );
      final service = LibraryService()
        ..library.add(original)
        ..watchedFolders.add('/existing');
      service.rebuildLibraryIndexes();
      final facade = LibraryFacade.create(
        databaseRepository: repository,
        service: service,
      );
      addTearDown(facade.dispose);
      final removedNotifications = <List<String>>[];
      facade.attachTrackRemovalHandler(removedNotifications.add);
      facade.recordLibraryEntriesForTracks('/existing', [
        original,
      ], persist: false);
      final entries = facade.libraryEntriesForLibrary('/existing');
      facade.beginLibraryBatch();
      facade.addOrReplaceTracks([original.copyWith(isFavorite: true)]);
      facade.removeTracksByPath([original.path]);
      facade.removeLibraryEntriesByPaths(
        '/existing',
        entries.map((entry) => entry.path),
      );
      facade.removeWatchedFolder('/existing');
      facade.addWatchedLibrary('/new');
      await expectLater(facade.endLibraryBatch(), throwsStateError);
      expect(facade.library.single.path, original.path);
      expect(facade.trackByPath(original.path)?.isFavorite, isFalse);
      expect(removedNotifications, isEmpty);
      expect(facade.watchedFolders, ['/existing']);
      expect(facade.watchedLibraries, isEmpty);
      expect(
        facade.libraryEntriesForLibrary('/existing').map((entry) => entry.path),
        entries.map((entry) => entry.path),
      );
      repository.rejectCommit = false;
      facade.beginLibraryBatch();
      facade.removeTracksByPath([original.path]);
      expect(removedNotifications, isEmpty);
      await facade.endLibraryBatch();
      expect(removedNotifications, [
        [original.path],
      ]);
    },
  );

  test('facade owns scan generation and rejects stale progress', () async {
    final service = LibraryService();
    final facade = LibraryFacade.create(
      databaseRepository: _RestoredLibraryRepository(),
      service: service,
    );
    addTearDown(facade.dispose);

    final initialScanRevision = facade.scanRevision;
    final initialStructureRevision = facade.structureRevision;
    final generation = facade.tryBeginScan(source: '/library');
    expect(generation, 1);
    expect(facade.tryBeginScan(source: '/other'), 0);
    expect(facade.state.isScanning, isTrue);
    expect(facade.state.scanGeneration, generation);
    expect(facade.state.scanCurrentFolder, '/library');

    facade.setScanProgress(
      generation: generation + 1,
      foundCount: 99,
      stage: FolderScanStage.enumerating,
    );
    expect(service.scanFoundCount, 0);

    facade.setScanProgress(
      generation: generation,
      currentFolder: '/library/disc-1',
      foundCount: 3,
      processed: 4,
      total: 8,
      stage: FolderScanStage.enumerating,
    );
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(facade.state.scanCurrentFolder, '/library/disc-1');
    expect(facade.state.scanFoundCount, 3);
    expect(facade.state.scanProcessed, 4);
    expect(facade.state.scanTotal, 8);
    expect(facade.state.scanStage, FolderScanStage.enumerating);

    facade.finishScan(generation + 1);
    expect(facade.state.isScanning, isTrue);
    facade.finishScan(generation);
    expect(facade.state.isScanning, isFalse);
    expect(facade.state.scanGeneration, 0);
    expect(facade.state.scanStage, FolderScanStage.idle);
    // A completed scan must invalidate directory caches even if no audio changed
    // and no caller observed the intermediate scanning state.
    expect(facade.structureRevision, initialStructureRevision);
    expect(facade.scanRevision, greaterThan(initialScanRevision));
    final completedScanRevision = facade.scanRevision;
    final nextGeneration = facade.tryBeginScan(source: '/library');
    facade.finishScan(nextGeneration);
    expect(facade.scanRevision, greaterThan(completedScanRevision));
    expect(facade.structureRevision, initialStructureRevision);
  });

  test('facade cancellation invalidates the active generation', () async {
    final facade = LibraryFacade.create(
      databaseRepository: _RestoredLibraryRepository(),
    );
    addTearDown(facade.dispose);

    final generation = facade.tryBeginScan(
      source: 'content://library',
      background: true,
    );
    expect(facade.isScanGenerationActive(generation), isTrue);

    facade.cancelScan();

    expect(facade.isScanGenerationActive(generation), isFalse);
    expect(facade.state.isScanning, isFalse);
    expect(facade.state.isBackgroundScanning, isFalse);
  });

  test('cancelled scan must finish cleanup before another scan begins', () {
    final facade = LibraryFacade.create(
      databaseRepository: _RestoredLibraryRepository(),
    );
    addTearDown(facade.dispose);

    final first = facade.tryBeginScan(source: '/music');
    facade.cancelScan();

    expect(facade.tryBeginScan(source: '/music'), 0);
    facade.finishScan(first);
    final second = facade.tryBeginScan(source: '/music');
    expect(second, greaterThan(first));
    facade.finishScan(second);
  });

  test('detail target uses the work root inside a watched library', () async {
    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FASMR.ONE';
    const firstWork = 'First work';
    const nestedWork = 'Nested work';
    final service = LibraryService()..watchedLibraries.add(libraryRoot);
    final facade = LibraryFacade.create(
      databaseRepository: _RestoredLibraryRepository(),
      service: service,
    );
    addTearDown(facade.dispose);

    for (final track in <MusicTrack>[
      MusicTrack(
        path: '$libraryRoot/document/first.wav',
        displayName: 'first.wav',
        groupKey: '$libraryRoot::$firstWork/wav',
        groupTitle: 'wav',
        groupSubtitle: '$firstWork/wav',
        isSingle: false,
      ),
      MusicTrack(
        path: '$libraryRoot/document/nested.wav',
        displayName: 'nested.wav',
        groupKey: '$libraryRoot::$nestedWork/$nestedWork/音声',
        groupTitle: '音声',
        groupSubtitle: '$nestedWork/$nestedWork/音声',
        isSingle: false,
      ),
    ]) {
      expect(
        facade.audioDetailTargetForTrack(track).targetPath,
        '$libraryRoot::${track.groupKey.contains(firstWork) ? firstWork : nestedWork}',
      );
    }
  });

  test(
    'detail operations never pass a child folder to the repository',
    () async {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADownload%2FASMR.ONE';
      const workRoot = '$libraryRoot::Work';
      const childFolder = '$workRoot/Work/音声';
      final repository = _RecordingAudioDetailRepository();
      final service = LibraryService()..watchedLibraries.add(libraryRoot);
      final facade = LibraryFacade.create(
        databaseRepository: _RestoredLibraryRepository(),
        service: service,
        detailCacheService: AudioDetailCacheService(repository: repository),
      );
      addTearDown(facade.dispose);
      final childTarget = AudioDetailTarget.libraryRootFolder(childFolder);

      await facade.loadAudioDetail(childTarget);
      await facade.saveAudioDetail(
        AudioDetail.empty(childTarget).copyWith(workTitle: 'Work'),
      );

      expect(repository.loadedTargets, <AudioDetailTarget>[
        AudioDetailTarget.libraryRootFolder(workRoot),
      ]);
      expect(repository.savedTargets, <AudioDetailTarget>[
        AudioDetailTarget.libraryRootFolder(workRoot),
      ]);
    },
  );

  test(
    'restored roots and tracks rebuild library cards without a scan',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'watched_folders_v1': jsonEncode(<String>['/music']),
        'watched_libraries_v1': jsonEncode(<String>['/music']),
      });
      final facade = LibraryFacade.create(
        databaseRepository: _RestoredLibraryRepository(),
      )..configurePersistence(enabled: false);
      addTearDown(facade.dispose);

      await facade.loadPersistedState();

      expect(facade.watchedFolders, <String>['/music']);
      expect(facade.watchedLibraries, <String>['/music']);
      expect(facade.library, hasLength(1));
      expect(
        facade.libraryCards.single.path.replaceAll('\\', '/'),
        '/music/album',
      );
      expect(facade.isScanning, isFalse);
    },
  );
}

final class _RestoredLibraryRepository extends TestPersistenceRepository {
  final settings = <String, String>{};
  int commits = 0;
  bool rejectCommit = false;
  @override
  Future<String?> loadAppSetting(String key) async => settings[key];
  @override
  Future<void> commitLibraryBatch({
    required List<MusicTrack> tracks,
    required List<LibraryEntry> entries,
    required Map<String, String> catalogSettings,
    List<String> removedTrackPaths = const [],
    Map<String, List<String>> removedEntryPaths = const {},
  }) async {
    commits++;
    if (rejectCommit) throw StateError('catalog commit rejected');
    settings.addAll(catalogSettings);
  }

  @override
  Future<List<MusicTrack>> loadStartupTracks() async {
    return <MusicTrack>[
      MusicTrack(
        path: '/music/album/01.wav',
        displayName: '01.wav',
        groupKey: '/music/album',
        groupTitle: 'album',
        groupSubtitle: '/music/album',
        isSingle: false,
      ),
    ];
  }

  @override
  Future<List<LibraryEntry>> loadAllLibraryEntries() async {
    return const <LibraryEntry>[];
  }
}

final class _RecordingAudioDetailRepository extends AudioDetailRepository {
  _RecordingAudioDetailRepository()
    : super(databaseRepository: _RestoredLibraryRepository());

  final List<AudioDetailTarget> loadedTargets = <AudioDetailTarget>[];
  final List<AudioDetailTarget> savedTargets = <AudioDetailTarget>[];

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) async {
    loadedTargets.add(target);
    return AudioDetailLoadResult(detail: AudioDetail.empty(target));
  }

  @override
  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    savedTargets.add(detail.target);
    return AudioDetailSaveResult(
      detail: detail,
      documentStatus: JsonDocumentWriteStatus.replaced,
    );
  }

  @override
  Future<AudioDetail> updateDerivedFields(
    AudioDetailTarget target, {
    String? rjCode,
    Duration? duration,
    String? cardCoverPath,
    bool? cardCoverSelected,
  }) async {
    savedTargets.add(target);
    return AudioDetail.empty(target).copyWith(
      rjCode: rjCode,
      duration: duration,
      cardCoverPath: cardCoverPath,
      cardCoverSelected: cardCoverSelected,
    );
  }
}
