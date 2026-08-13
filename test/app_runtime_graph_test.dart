import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/app_runtime_graph.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_persistence_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production facade constructor requires only five high-level owners',
    () {
      final library = _createLibraryFacade();
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      );
      final timer = TimerFacade.create();
      final notification = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final settings = SettingsRepository();
      final runtimeGraph = createAppRuntimeGraph(
        library: library,
        playback: playback,
        timer: timer,
        notifications: notification,
        settings: settings,
      );
      addTearDown(runtimeGraph.runtime.dispose);

      expect(runtimeGraph.library, same(library));
      expect(runtimeGraph.playback, same(playback));
      expect(runtimeGraph.timer, same(timer));
      expect(runtimeGraph.notifications, same(notification));
      expect(runtimeGraph.settings, same(settings));
    },
  );

  test(
    'production subtitles resolve ASMR tracks from session queues',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('[00:01.00]ASMR subtitle');
        await request.response.close();
      });

      final library = _createLibraryFacade();
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      );
      final runtimeGraph = createAppRuntimeGraph(
        library: library,
        playback: playback,
        timer: TimerFacade.create(),
        notifications: NotificationFacade.create(
          service: PlaybackNotificationService(),
        ),
        settings: SettingsRepository(),
        persistenceEnabled: false,
      );
      addTearDown(runtimeGraph.runtime.dispose);

      final track = MusicTrack(
        path: 'https://example.com/asmr/track.mp3',
        displayName: 'track',
        groupKey: 'asmr-work-1',
        groupTitle: 'ASMR Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{
          'subtitleUrl':
              'http://${server.address.host}:${server.port}/track.lrc',
          'subtitleSourcePath': 'track.lrc',
          'subtitleExtension': '.lrc',
        },
      );
      playback.createTrackSession(
        track,
        customQueueTracks: <MusicTrack>[track],
      );

      expect(library.trackByPath(track.path), isNull);
      expect(runtimeGraph.audioPaths.trackByPath(track.path), same(track));
      final subtitle = await runtimeGraph.subtitles.load(track.path);
      expect(subtitle, isNotNull);
      expect(subtitle!.cues.single.text, 'ASMR subtitle');
    },
  );

  test('ASMR session lookup skips the normalized local library fallback', () {
    final libraryService = LibraryService();
    final library = _createLibraryFacade(service: libraryService);
    library.addTracks(
      List<MusicTrack>.generate(
        512,
        (index) => MusicTrack(
          path: 'C:\\Audio\\Library\\track_$index.mp3',
          displayName: 'track_$index',
          groupKey: r'C:\Audio\Library',
          groupTitle: 'Local Library',
          groupSubtitle: r'C:\Audio\Library',
          isSingle: false,
        ),
      ),
      notify: false,
      persist: false,
    );
    final countedLibrary = _ElementReadCountingList<MusicTrack>(
      libraryService.library,
    );
    libraryService.library = countedLibrary;

    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final runtimeGraph = createAppRuntimeGraph(
      library: library,
      playback: playback,
      timer: TimerFacade.create(),
      notifications: NotificationFacade.create(
        service: PlaybackNotificationService(),
      ),
      settings: SettingsRepository(),
      persistenceEnabled: false,
    );
    addTearDown(runtimeGraph.runtime.dispose);
    final asmrTrack = MusicTrack(
      path: 'https://example.com/asmr/track.mp3',
      displayName: 'ASMR track',
      groupKey: 'asmr-work-1',
      groupTitle: 'ASMR Work',
      groupSubtitle: 'RJ000001',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
    );
    playback.createTrackSession(
      asmrTrack,
      customQueueTracks: <MusicTrack>[asmrTrack],
    );
    countedLibrary.resetReadCount();

    expect(
      runtimeGraph.audioPaths.trackByPath(asmrTrack.path),
      same(asmrTrack),
    );
    expect(countedLibrary.elementReadCount, 0);
  });

  test('normalized local path fallback remains available', () {
    final library = _createLibraryFacade();
    final localTrack = MusicTrack(
      path: r'C:\Audio\Library\Track.mp3',
      displayName: 'Track',
      groupKey: r'C:\Audio\Library',
      groupTitle: 'Local Library',
      groupSubtitle: r'C:\Audio\Library',
      isSingle: false,
    );
    library.addTracks(<MusicTrack>[localTrack], notify: false, persist: false);
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final runtimeGraph = createAppRuntimeGraph(
      library: library,
      playback: playback,
      timer: TimerFacade.create(),
      notifications: NotificationFacade.create(
        service: PlaybackNotificationService(),
      ),
      settings: SettingsRepository(),
      persistenceEnabled: false,
    );
    addTearDown(runtimeGraph.runtime.dispose);

    expect(
      runtimeGraph.audioPaths.trackByPath(r'c:\audio\library\track.mp3'),
      same(localTrack),
    );
  });

  test('native-only restored content session retains its SAF grant', () async {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    addTearDown(playback.dispose);

    playback.updateNativeSessionRetainedContentUris(
      'native-only-session',
      const <String>[
        'content://provider/document/audio-1',
        'https://example.com/audio.mp3',
      ],
    );

    expect(playback.sessions, isEmpty);
    expect(playback.persistedContentUris, <String>{
      'content://provider/document/audio-1',
    });

    playback.forgetNativeSessionRetainedContentUris('native-only-session');
    expect(playback.persistedContentUris, isEmpty);
  });

  test('saved ASMR download folder retains its SAF grant', () async {
    const destinationA =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3ADownload%2FASMR';
    const destinationB =
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic%2FASMR';
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final firstSettings = SettingsRepository();
    await firstSettings.setAsmrDownloadDestinationRoot(destinationA);
    await firstSettings.dispose();

    final settings = SettingsRepository();
    await settings.loadPersistedState();
    final library = _createLibraryFacade();
    library.syncPresentationState(isInitialized: true);
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    playback.syncPresentationState(
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    playback.replaceNativeRetainedContentUris(const []);
    final downloads = AsmrDownloadManager(persistTasks: false);
    await downloads.initialize();
    final gateway = _RecordingFileCachePlatformGateway();
    final retainedA = gateway.calls.firstWhere(
      (uris) => uris.contains(destinationA),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final graph = createAppRuntimeGraph(
      library: library,
      playback: playback,
      timer: TimerFacade.create(),
      notifications: NotificationFacade.create(
        service: PlaybackNotificationService(),
      ),
      settings: settings,
      asmrDownloads: downloads,
      fileCacheGateway: gateway,
      persistenceEnabled: false,
    );
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await graph.runtime.dispose();
      await gateway.dispose();
    });

    expect(await retainedA.timeout(const Duration(seconds: 1)), {destinationA});
    await Future<void>.delayed(Duration.zero);
    final startupCallCount = gateway.recordedCalls.length;
    expect(startupCallCount, greaterThan(0));
    expect(gateway.recordedCalls.last, <String>{destinationA});

    await settings.setAsmrDownloadDestinationRoot(destinationA);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.recordedCalls, hasLength(startupCallCount));

    final retainedB = gateway.calls.firstWhere(
      (uris) => uris.contains(destinationB),
    );
    await settings.setAsmrDownloadDestinationRoot(destinationB);
    expect(await retainedB.timeout(const Duration(seconds: 1)), {destinationB});

    final releasedCall = gateway.calls.firstWhere((uris) => uris.isEmpty);
    await settings.setAsmrDownloadDestinationRoot(null);
    expect(await releasedCall.timeout(const Duration(seconds: 1)), isEmpty);
    expect(gateway.recordedCalls.skip(startupCallCount), <Set<String>>[
      <String>{destinationB},
      <String>{},
    ]);
  });
}

LibraryFacade _createLibraryFacade({LibraryService? service}) {
  return LibraryFacade.create(
    databaseRepository: TestPersistenceRepository(),
    service: service,
  );
}

final class _ElementReadCountingList<E> extends ListBase<E> {
  _ElementReadCountingList(Iterable<E> values) : _values = List<E>.of(values);

  final List<E> _values;
  int elementReadCount = 0;

  void resetReadCount() => elementReadCount = 0;

  @override
  int get length => _values.length;

  @override
  set length(int value) => _values.length = value;

  @override
  E operator [](int index) {
    elementReadCount++;
    return _values[index];
  }

  @override
  void operator []=(int index, E value) => _values[index] = value;
}

final class _RecordingFileCachePlatformGateway
    extends FileCachePlatformGateway {
  _RecordingFileCachePlatformGateway() : super(isAndroid: () => true);

  final StreamController<Set<String>> _calls =
      StreamController<Set<String>>.broadcast();
  final List<Set<String>> recordedCalls = <Set<String>>[];

  Stream<Set<String>> get calls => _calls.stream;

  @override
  Future<PersistedUriPermissionReconcileResult?>
  reconcilePersistedUriPermissions(Iterable<String> retainedUris) async {
    final uris = Set<String>.unmodifiable(retainedUris);
    recordedCalls.add(uris);
    _calls.add(uris);
    return PersistedUriPermissionReconcileResult(
      retainedCount: uris.length,
      releasedCount: 0,
      failedUris: const <String>[],
    );
  }

  Future<void> dispose() => _calls.close();
}
