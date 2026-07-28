import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/audio_path_coordinator.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_persistence_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const channel = MethodChannel(FileCacheChannel.name);
  late Database database;
  late LibraryFacade library;
  late PlaybackFacade playback;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(database);
    final repository = TestPersistenceRepository(
      database: AppDatabase.test(database),
    );
    library = LibraryFacade.create(
      databaseRepository: repository,
      isAndroid: () => true,
    );
    library.configureCoverArtworkRuntime(
      isActiveCoverKey: (_) => false,
      onActiveCoverChanged: () {},
    );
    playback = PlaybackFacade.create(databaseRepository: repository);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await playback.dispose();
    await library.dispose();
    await database.close();
  });

  test(
    'automatic migration is idempotent and retargets playback paths',
    () async {
      const oldRoot = '/storage/emulated/0/Music';
      const oldTrack = '$oldRoot/Album/01.mp3';
      const grant =
          'content://com.android.externalstorage.documents/tree/primary%3AMusic';
      var lookupCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == FileCacheMethod.findPersistedTreeGrantForPath) {
              lookupCount++;
              return <String, Object?>{'ok': true, 'value': grant};
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      library.addWatchedLibrary(oldRoot, notify: false);
      library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: oldTrack,
            displayName: '01',
            groupKey: '$oldRoot/Album',
            groupTitle: 'Album',
            groupSubtitle: '$oldRoot/Album',
            isSingle: false,
          ),
        ],
        notify: false,
        persist: false,
      );
      final gateway = FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => true,
      );
      expect(await gateway.findPersistedTreeGrantForPath(oldRoot), grant);
      final coordinator = AudioPathCoordinator(
        library: library,
        playback: playback,
        fileGateway: gateway,
      );

      expect(coordinator.legacyAndroidSourceIssues, hasLength(1));
      final first = await coordinator.migratePersistedLibrarySources();
      final second = await coordinator.migratePersistedLibrarySources();

      const migratedTrack = '$grant/document/primary%3AMusic%2FAlbum%2F01.mp3';
      expect(library.watchedLibraries, <String>[grant]);
      expect(first, hasLength(1));
      expect(second, isEmpty);
      expect(lookupCount, 2);
      expect(library.library.single.path, migratedTrack);
      expect(playback.resolveRetargetedPath(oldTrack), migratedTrack);
    },
  );

  test('stale migration result cannot change the loaded graph', () async {
    const oldRoot = '/storage/emulated/0/Music';
    const grant =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';
    final response = Completer<Object?>();
    var current = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => response.future);
    library.addWatchedLibrary(oldRoot, notify: false);
    final coordinator = AudioPathCoordinator(
      library: library,
      playback: playback,
      fileGateway: FileCachePlatformGateway(
        channel: channel,
        isAndroid: () => true,
      ),
    );

    final migration = coordinator.migratePersistedLibrarySources(
      isCurrent: () => current,
    );
    current = false;
    response.complete(<String, Object?>{'ok': true, 'value': grant});

    expect(await migration, isEmpty);
    expect(library.watchedLibraries, <String>[oldRoot]);
  });
}
