import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/library/application/library_scan_models.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/library/domain/library_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test('facade owns scan generation and rejects stale progress', () async {
    final service = LibraryService();
    final facade = LibraryFacade.create(service: service);
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
    final facade = LibraryFacade.create();
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

  test(
    'backup export preparation flushes current folder and library roots',
    () async {
      final facade = LibraryFacade.create();
      addTearDown(facade.dispose);
      facade
        ..addWatchedFolder('/music/folder')
        ..addWatchedLibrary('/music/library');

      await facade.prepareForBackupExport();

      final preferences = await SharedPreferences.getInstance();
      expect(jsonDecode(preferences.getString('watched_folders_v1')!), <String>[
        '/music/folder',
      ]);
      expect(
        jsonDecode(preferences.getString('watched_libraries_v1')!),
        <String>['/music/library'],
      );
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
      expect(facade.libraryCards.single.path, '/music');
      expect(facade.isScanning, isFalse);
    },
  );
}

final class _RestoredLibraryRepository extends AudioDatabaseRepository {
  @override
  Future<List<MusicTrack>> loadStartupTracks() async {
    return const <MusicTrack>[
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
