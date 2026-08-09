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
import 'package:doujin_audio/features/library/domain/library_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('facade owns scan generation and rejects stale progress', () async {
    final service = LibraryService();
    final facade = LibraryFacade.create(
      databaseRepository: _RestoredLibraryRepository(),
      service: service,
    );
    addTearDown(facade.dispose);

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
  Future<AudioDetail> updateDerivedFields(AudioDetail detail) async {
    savedTargets.add(detail.target);
    return detail;
  }
}
