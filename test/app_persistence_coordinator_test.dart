import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_persistence_coordinator.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'AppPersistenceCoordinator owns ordered load and restore reload',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      await AppDatabase.createSchemaForTest(database);
      final repository = AudioDatabaseRepository(
        database: AppDatabase.test(database),
      );
      final library = LibraryFacade.create(databaseRepository: repository);
      final native = _FakeNativePlaybackRepository();
      final playback = PlaybackFacade.create(
        databaseRepository: repository,
        nativeRepository: native,
      )..configurePersistence(enabled: false);
      final timer = TimerFacade.create();
      final settings = SettingsRepository();
      final events = <String>[];
      final coordinator = AppPersistenceCoordinator(
        library: library,
        playback: playback,
        settings: settings,
        timer: timer,
        beforeReset: () async => events.add('beforeReset'),
        afterReset: () async => events.add('afterReset'),
        onSettingsLoaded: () async => events.add('settings'),
        onLibraryLoaded: () async => events.add('library'),
        onPlaybackLoaded: () async => events.add('playback'),
        onLoadCompleted: () async => events.add('completed'),
      );
      addTearDown(() async {
        coordinator.dispose();
        await playback.dispose();
        await library.dispose();
        await timer.dispose();
        await database.close();
      });

      await coordinator.loadPersistedState();

      expect(events, <String>['settings', 'library', 'playback', 'completed']);

      events.clear();
      await coordinator.reloadPersistedState();

      expect(events, <String>[
        'beforeReset',
        'afterReset',
        'settings',
        'library',
        'playback',
        'completed',
      ]);
      expect(native.clearAllCount, 1);
    },
  );
}

final class _FakeNativePlaybackRepository extends NativePlaybackRepository {
  int clearAllCount = 0;

  @override
  Future<NativeResult<void>> clearAll() async {
    clearAllCount++;
    return const NativeSuccess<void>();
  }

  @override
  Future<void> dispose() async {}
}
