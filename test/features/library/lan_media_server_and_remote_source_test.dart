import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/media/media_file_support.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/network/remote_source_headers.dart';
import 'package:doujin_audio/core/network/webdav_client.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/persistence/persistence_records.dart';
import 'package:doujin_audio/features/data_support/application/cross_platform_sync_service.dart';
import 'package:doujin_audio/features/library/application/lan_media_server_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/remote_library_controller.dart';
import 'package:doujin_audio/features/library/application/webdav_media_source_adapter.dart';
import 'package:doujin_audio/features/library/domain/remote_media_source.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_cross_platform_sync_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingPlaybackLauncher implements PlaybackSessionLauncher {
  List<MusicTrack> lastTracks = const <MusicTrack>[];
  MusicTrack? addedTrack;

  @override
  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    lastTracks = await tracks;
    return true;
  }

  @override
  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  }) async {
    addedTrack = track;
    return true;
  }

  @override
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) async {
    lastTracks = tracks;
    return true;
  }
}

Map<String, int> _daysMap(List<Map<String, Object?>> rows) => <String, int>{
  for (final row in rows)
    row['date']! as String: (row['milliseconds']! as num).toInt(),
};

class _CatalogWebDav extends WebDavClient {
  _CatalogWebDav()
    : super(baseUri: Uri.parse('https://dav.example.test/audio/'));

  int count = 120;
  int writes = 0;
  int moves = 0;
  bool failSidecarRead = false;
  String sidecar =
      '{"schemaVersion":1,"type":"audio-detail",'
      '"workTitle":"Saved title","tags":["Saved tag"]}';

  @override
  Future<List<WebDavEntry>> listDirectory(
    Uri directoryUri, {
    int depth = 1,
    bool includeSelf = false,
    int maxResponseBytes = 16 * 1024 * 1024,
  }) async => [
    for (var i = 100000; i < 100000 + count; i++)
      WebDavEntry(
        uri: directoryUri.resolve('RJ$i/'),
        name: 'RJ$i',
        isDirectory: true,
      ),
  ];

  @override
  Future<Uint8List?> getBytesOrNull(
    Uri fileUri, {
    int maxBytes = 4 * 1024 * 1024,
  }) async {
    if (failSidecarRead) {
      throw WebDavException('Temporary failure', statusCode: 503, uri: fileUri);
    }
    return Uint8List.fromList(utf8.encode(sidecar));
  }

  @override
  Future<void> putBytesAtomic(Uri fileUri, Uint8List bytes) async {
    writes++;
  }

  @override
  Future<void> moveUri({
    required Uri sourceUri,
    required Uri destinationUri,
    bool overwrite = false,
  }) async {
    moves++;
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('doujin_lan_server_test_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppPreferences.init();
  });

  tearDown(() async {
    RemoteSourceHeaderRegistry.instance.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('one WebDAV account cannot be added twice or edited onto another source', () async {
    final sync = CrossPlatformSyncService();
    addTearDown(sync.dispose);
    final secrets = <String, String>{};
    final controller = RemoteLibraryController(
      syncService: sync,
      supportDirectoryProvider: () async => tempDir,
      readSecret: (key) async => secrets[key],
      writeSecret: (key, value) async {
        if (value == null) {
          secrets.remove(key);
        } else {
          secrets[key] = value;
        }
      },
      webDavClientFactory: ({required baseUri, username, password}) =>
          _CatalogWebDav()..count = 0,
    );
    addTearDown(controller.dispose);
    Future<RemoteMediaSource> save(String url, String username, {String? id}) =>
        controller.addOrUpdateSource(
          id: id,
          type: RemoteMediaSourceType.webDav,
          name: 'NAS',
          baseUrl: url,
          username: username,
          secret: url.contains('DAV.EXAMPLE') ? 'original' : 'new',
        );

    final results = await Future.wait([
      save('HTTPS://DAV.EXAMPLE:443/Audio', 'alice'),
      save('https://dav.example/Audio/', ' alice ').then<Object>(
        (source) => source,
        onError: (Object error) => error,
      ),
    ]);
    final alice = results.first as RemoteMediaSource;
    expect(results.last, RemoteMediaSourceConflict.duplicate);
    expect(secrets.values, ['original']);

    final bob = await save('https://dav.example/Audio/', 'bob');
    await expectLater(
      save('https://dav.example/Audio/', 'alice', id: bob.id),
      throwsA(RemoteMediaSourceConflict.duplicate),
    );
    final edited = await save('https://dav.example/Audio/', 'alice', id: alice.id);
    expect(edited.id, alice.id);
    expect(controller.sources.map((source) => source.username), ['alice', 'bob']);
    await Future.wait([controller.refreshSource(alice.id), controller.refreshSource(bob.id)]);
  });

  test('LAN sources reject the same server through another address and reject this PC', () async {
    Future<HttpServer> serve(String id) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path.endsWith('/info')) {
          response.write(jsonEncode({'serverId': id, 'allowSync': true}));
        } else if (request.method == 'HEAD') {
          response.statusCode = HttpStatus.noContent;
        } else {
          response.write('{"works":[]}');
        }
        await response.close();
      });
      return server;
    }

    final remote = await serve('other-pc');
    final alias = await serve('other-pc');
    final local = await serve('this-pc');
    String url(HttpServer server) => 'http://127.0.0.1:${server.port}';
    final sync = CrossPlatformSyncService();
    addTearDown(sync.dispose);
    final controller = RemoteLibraryController(
      syncService: sync,
      supportDirectoryProvider: () async => tempDir,
      localLanServerId: () => 'this-pc',
    );
    addTearDown(controller.dispose);

    Future<RemoteMediaSource> add(HttpServer server, {String? id}) =>
        controller.addOrUpdateSource(
          id: id,
          type: RemoteMediaSourceType.windowsLan,
          name: 'Media PC',
          baseUrl: url(server),
        );

    final saved = await add(remote);
    expect(saved.lanServerId, 'other-pc');
    await expectLater(add(alias), throwsA(RemoteMediaSourceConflict.duplicate));
    await expectLater(add(local), throwsA(RemoteMediaSourceConflict.localServer));
    final edited = await add(alias, id: saved.id);
    expect(edited.baseUrl, url(alias));
    expect(controller.sources.single.id, saved.id);
    expect(RemoteMediaSource.fromJson(edited.toJson()).lanServerId, 'other-pc');
    await controller.refreshSource(saved.id);
  });

  test(
    'WebDAV keeps metadata beyond 120 entries and across temporary errors',
    () async {
      final client = _CatalogWebDav();
      addTearDown(client.close);
      final source = RemoteMediaSource(
        id: 'dav',
        type: RemoteMediaSourceType.webDav,
        name: 'NAS',
        baseUrl: client.baseUri.toString(),
        createdAtMs: 0,
      );
      const adapter = WebDavMediaSourceAdapter();
      final before = await adapter.fetchWorks(source: source, client: client);
      expect(before, hasLength(120));
      client.count++;
      final after = await adapter.fetchWorks(
        source: source,
        client: client,
        cachedWorks: before,
      );
      expect(after, hasLength(121));
      expect(
        after.every(
          (work) =>
              work.title == 'Saved title' && work.tags.contains('Saved tag'),
        ),
        isTrue,
      );
      client.failSidecarRead = true;
      final stale = await adapter.fetchWorks(
        source: source,
        client: client,
        cachedWorks: after,
      );
      expect(stale.map((work) => work.title), everyElement('Saved title'));
    },
  );

  test(
    'WebDAV rejects incompatible sidecar before modifying metadata or moving a folder',
    () async {
      final client = _CatalogWebDav()
        ..sidecar =
            '[{"targetPath":"01.flac","timeSegmentLabels":[{"label":"keep"}]}]';
      addTearDown(client.close);
      final work = RemoteLibraryWork(
        sourceId: 'dav',
        workId: 'one',
        rjCode: 'RJ100000',
        title: 'Work',
        folderName: 'RJ100000',
        circleName: '',
        directoryUri: client.baseUri.resolve('RJ100000/').toString(),
      );
      const adapter = WebDavMediaSourceAdapter();
      await expectLater(
        adapter.saveWorkReview(
          work: work,
          client: client,
          listenStatus: null,
          userRating: 4,
          reviewText: 'review',
        ),
        throwsFormatException,
      );
      await expectLater(
        adapter.saveWorkDetail(
          work: work,
          client: client,
          metadata: DlsiteMetadata(
            rjCode: work.rjCode,
            workTitle: work.title,
            circleName: '',
            voiceActors: [],
            tags: [],
          ),
          newFolderName: 'Renamed',
        ),
        throwsFormatException,
      );
      expect(client.writes, 0);
      expect(client.moves, 0);
    },
  );

  test('LanMediaServerService enforces PIN auth, Range slicing, path sandbox, and 1-click LAN sync', () async {
    // 1. Prepare Windows server library root, work folder, excluded folder, and outside file.
    final libraryRoot = await Directory(p.join(tempDir.path, 'VoiceLib')).create();
    final workDir = await Directory(
      p.join(libraryRoot.path, '[SnowCircle] RJ654321 Bedtime Ear Cleaning'),
    ).create();
    final excludedSubDir = await Directory(p.join(workDir.path, 'ExcludedBonus')).create();
    final outsideFile = File(p.join(tempDir.path, 'outside_secret.txt'));
    await outsideFile.writeAsString('TOP_SECRET');

    final audioBytes = Uint8List.fromList(
      List<int>.generate(64, (index) => index + 10),
    );
    final trackFile = File(p.join(workDir.path, '01_ear_cleaning.mp3'));
    await trackFile.writeAsBytes(audioBytes);
    final videoFile = File(p.join(workDir.path, '02_preview.mp4'));
    await videoFile.writeAsBytes(<int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
    await File(p.join(workDir.path, '01_ear_cleaning.lrc')).writeAsString(
      '[00:01.00] Good evening',
    );
    await File(p.join(workDir.path, 'tracklist.txt')).writeAsString('Track 01');
    await File(p.join(workDir.path, 'cover.jpg')).writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
    final excludedFile = File(p.join(excludedSubDir.path, 'secret_bonus.mp3'));
    await excludedFile.writeAsBytes(<int>[1, 2, 3]);

    final serverRawDb = await databaseFactoryFfi.openDatabase(
      p.join(tempDir.path, 'server.db'),
    );
    final clientRawDb = await databaseFactoryFfi.openDatabase(
      p.join(tempDir.path, 'client.db'),
    );
    addTearDown(() async {
      await serverRawDb.close();
      await clientRawDb.close();
    });
    await AppDatabase.createSchemaForTest(serverRawDb);
    await AppDatabase.createSchemaForTest(clientRawDb);
    final serverDb = AppDatabase.test(serverRawDb);
    final clientDb = AppDatabase.test(clientRawDb);

    final serverTrack = MusicTrack(
      path: trackFile.path,
      displayName: '01_ear_cleaning.mp3',
      groupKey: workDir.path,
      groupTitle: '[SnowCircle] RJ654321 Bedtime Ear Cleaning',
      groupSubtitle: workDir.path,
      isSingle: false,
      duration: const Duration(minutes: 25),
      lyricsPath: p.join(workDir.path, '01_ear_cleaning.lrc'),
    );
    final libraryService = LibraryService();
    libraryService.watchedLibraries.add(libraryRoot.path);
    libraryService.excludedLibraryFolders[libraryRoot.path] =
        LibraryService.createPathSet(<String>[excludedSubDir.path]);
    libraryService.library.add(serverTrack);
    libraryService.groupOrder.add(workDir.path);
    libraryService.rebuildLibraryIndexes();

    final libraryRepo = SqliteLibraryRepository(database: serverDb);
    await libraryRepo.saveAllTracks(<MusicTrack>[serverTrack]);

    final libraryFacade = LibraryFacade.create(
      databaseRepository: libraryRepo,
      jsonDocumentStore: DefaultJsonDocumentStore(),
      service: libraryService,
    );
    libraryFacade.configureCoverArtworkRuntime(
      isActiveCoverKey: (_) => false,
      onActiveCoverChanged: () {},
    );
    addTearDown(libraryFacade.dispose);

    await libraryFacade.saveAudioDetail(
      AudioDetail(
        target: AudioDetailTarget.libraryRootFolder(workDir.path),
        rjCode: 'RJ654321',
        workTitle: 'Bedtime Ear Cleaning',
        circleName: 'SnowCircle',
        voiceActors: const <String>['CV-A'],
        tags: const <String>['耳かき'],
      ),
    );

    // Server has 20 min of listening time; Android client has 15 min + 9 min playback position.
    await serverDb.importListeningBatch('srv-1', const <ListeningDayRecord>[
      ListeningDayRecord(date: '2026-11-24', totalMs: 1200000, works: []),
    ]);
    await clientDb.importListeningBatch('cli-1', const <ListeningDayRecord>[
      ListeningDayRecord(date: '2026-11-24', totalMs: 900000, works: []),
    ]);
    await clientDb.applyCrossPlatformSyncData(
      generateDeviceId: () => 'client-dev-1',
      incomingTracks: const <PersistedSyncTrackRow>[
        PersistedSyncTrackRow(
          syncKey: 'rj:RJ654321::01_ear_cleaning.mp3',
          workKey: 'rj:RJ654321',
          relativePath: '01_ear_cleaning.mp3',
          stemKey: 'rj:RJ654321::01_ear_cleaning',
          isFavorite: true,
          favoriteUpdatedAtMs: 500000,
          positionMs: 540000,
          lastPlayedAtMs: 500000,
          updatedAtMs: 500000,
        ),
      ],
      incomingDeviceDayLedger: const {},
      incomingDeviceWorkDayLedger: const {},
      incomingHistory: const [],
      incomingTimeSegments: const [],
      incomingDeletedTimeSegments: const {},
      mergedInterestSettings: const {},
    );

    final serverSecrets = <String, String>{};
    final serverSync = CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: serverDb),
      platformName: 'windows',
      deviceName: 'Windows-PC',
    );
    final pinnedPaths = <String>{};
    final lanServer = LanMediaServerService(
      library: libraryFacade,
      syncService: serverSync,
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
      allowNonWindowsForTest: true,
      serverName: 'Study-PC',
      readPinnedPaths: () => pinnedPaths,
      togglePinnedPaths: (paths) async {
        for (final path in paths) {
          if (!pinnedPaths.remove(path)) pinnedPaths.add(path);
        }
      },
      readSecret: (k) async => serverSecrets[k],
      writeSecret: (k, v) async {
        if (v == null) {
          serverSecrets.remove(k);
        } else {
          serverSecrets[k] = v;
        }
      },
    );
    addTearDown(() async {
      await lanServer.stopForShutdown(fastShutdown: true);
      lanServer.dispose();
      serverSync.dispose();
    });

    await lanServer.initialize();
    await lanServer.updateSettings(
      const LanServerSettings(
        enabled: true,
        port: 0,
      ),
    );
    expect(lanServer.isRunning, isTrue);
    final port = lanServer.boundPort!;
    final pin = lanServer.accessCode;
    expect(pin.length, 6);

    // 2. Verify unauthenticated /api/v1/works is rejected with 401 while /api/v1/info is public.
    final rawClient = HttpClient();
    addTearDown(() => rawClient.close(force: true));

    final infoReq = await rawClient.getUrl(
      Uri.parse('http://127.0.0.1:$port/api/v1/info'),
    );
    final infoResp = await infoReq.close();
    final infoJson = jsonDecode(await infoResp.transform(utf8.decoder).join()) as Map;
    expect(infoResp.statusCode, HttpStatus.ok);
    expect(infoJson['authRequired'], isTrue);
    expect(infoJson['allowSync'], isTrue);

    final unauthReq = await rawClient.getUrl(
      Uri.parse('http://127.0.0.1:$port/api/v1/works'),
    );
    final unauthResp = await unauthReq.close();
    await unauthResp.drain<void>();
    expect(unauthResp.statusCode, HttpStatus.unauthorized);

    final worksUri = Uri.parse('http://127.0.0.1:$port/api/v1/works');
    final rejectedProbe = await (await rawClient.headUrl(worksUri)).close();
    await rejectedProbe.drain<void>();
    expect(rejectedProbe.statusCode, HttpStatus.unauthorized);
    final probe = await rawClient.headUrl(worksUri);
    probe.headers.set(HttpHeaders.authorizationHeader, 'Bearer $pin');
    final acceptedProbe = await probe.close();
    expect(acceptedProbe.statusCode, HttpStatus.noContent);
    expect(await acceptedProbe.transform(utf8.decoder).join(), isEmpty);

    // Verify sandbox blocks paths outside watched library roots and excluded folders.
    expect(libraryFacade.isActiveAllowedFileSystemPath(trackFile.path), isTrue);
    expect(libraryFacade.isActiveAllowedFileSystemPath(excludedFile.path), isFalse);
    expect(libraryFacade.isActiveAllowedFileSystemPath(outsideFile.path), isFalse);

    // 3. Connect RemoteLibraryController from simulated Android client!
    final clientSecrets = <String, String>{};
    final clientSync = CrossPlatformSyncService(
      repository: SqliteCrossPlatformSyncRepository(database: clientDb),
      platformName: 'android',
      deviceName: 'Phone',
    );
    final launcher = _RecordingPlaybackLauncher();
    final headerRegistry = RemoteSourceHeaderRegistry();
    final remoteController = RemoteLibraryController(
      syncService: clientSync,
      playbackLauncher: launcher,
      headerRegistry: headerRegistry,
      supportDirectoryProvider: () async => tempDir,
      readSecret: (k) async => clientSecrets[k],
      writeSecret: (k, v) async {
        if (v == null) {
          clientSecrets.remove(k);
        } else {
          clientSecrets[k] = v;
        }
      },
    );
    addTearDown(() {
      remoteController.dispose();
      clientSync.dispose();
    });

    final addedSource = await remoteController.addOrUpdateSource(
      name: 'Bedroom Windows LAN',
      type: RemoteMediaSourceType.windowsLan,
      baseUrl: '127.0.0.1:$port',
      secret: pin,
    );
    await remoteController.refreshSource(addedSource.id);
    final works = remoteController.worksFor(addedSource.id);
    expect(works, hasLength(1));
    final remoteWork = works.single;
    expect(remoteWork.rjCode, 'RJ654321');
    expect(remoteWork.title, 'Bedtime Ear Cleaning');
    expect(remoteWork.hasSubtitle, isTrue);
    expect(remoteWork.coverUrl, isNotNull);

    // Verify cover endpoint streams cover.jpg bytes with Bearer PIN.
    final coverReq = await rawClient.getUrl(Uri.parse(remoteWork.coverUrl!));
    coverReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $pin');
    final coverResp = await coverReq.close();
    final coverBytes = BytesBuilder();
    await for (final chunk in coverResp) {
      coverBytes.add(chunk);
    }
    expect(coverResp.statusCode, HttpStatus.ok);
    expect(coverBytes.takeBytes(), <int>[0xFF, 0xD8, 0xFF, 0xD9]);

    // Tree excludes ExcludedBonus folder and exposes audio + subtitle + text + cover!
    final tree = await remoteController.ensureWorkTree(remoteWork);
    final names = tree.map((n) => n.title).toList();
    expect(
      names,
      containsAll(<String>[
        '01_ear_cleaning.mp3',
        '01_ear_cleaning.lrc',
        'tracklist.txt',
        'cover.jpg',
      ]),
    );
    expect(names, isNot(contains('ExcludedBonus')));

    // Verify HTTP 206 Partial Content Range streaming on the track URL!
    final audioNode = tree.firstWhere((n) => n.title == '01_ear_cleaning.mp3');
    expect(audioNode.streamUrl, endsWith('/01_ear_cleaning.mp3'));
    final videoNode = tree.firstWhere((n) => n.title == '02_preview.mp4');
    expect(videoNode.streamUrl, endsWith('/02_preview.mp4'));
    expect(isVideoMediaFile(videoNode.streamUrl!), isTrue);
    expect(videoNode.isVideo, isTrue);

    final rangeReq = await rawClient.getUrl(Uri.parse(audioNode.streamUrl!));
    rangeReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $pin');
    rangeReq.headers.set(HttpHeaders.rangeHeader, 'bytes=4-9');
    final rangeResp = await rangeReq.close();
    final sliced = BytesBuilder();
    await for (final chunk in rangeResp) {
      sliced.add(chunk);
    }
    expect(rangeResp.statusCode, HttpStatus.partialContent);
    expect(rangeResp.headers.value(HttpHeaders.contentRangeHeader), 'bytes 4-9/64');
    expect(sliced.takeBytes(), audioBytes.sublist(4, 10));

    // Legacy 4-segment /api/v1/stream/<fileId> remains supported.
    final legacyStreamUri = Uri.parse(audioNode.streamUrl!).replace(
      pathSegments: Uri.parse(audioNode.streamUrl!).pathSegments.take(4).toList(),
    );
    final legacyReq = await rawClient.getUrl(legacyStreamUri);
    legacyReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $pin');
    final legacyResp = await legacyReq.close();
    await legacyResp.drain<void>();
    expect(legacyResp.statusCode, HttpStatus.ok);

    // Fresh LAN server instance without prior /tree request still resolves file IDs on stream!
    await AppPreferences.remove('windows_lan_server_settings_v1');
    final restartedServer = LanMediaServerService(
      library: libraryFacade,
      syncService: serverSync,
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
      allowNonWindowsForTest: true,
      serverName: 'Study-PC-Restarted',
      readSecret: (k) async => serverSecrets[k],
      writeSecret: (k, v) async {
        if (v == null) {
          serverSecrets.remove(k);
        } else {
          serverSecrets[k] = v;
        }
      },
    );
    addTearDown(() async {
      await restartedServer.stopForShutdown(fastShutdown: true);
      restartedServer.dispose();
    });
    await restartedServer.initialize();
    await restartedServer.updateSettings(
      const LanServerSettings(enabled: true, port: 0),
    );
    final restartedStreamUri = Uri.parse(audioNode.streamUrl!).replace(
      port: restartedServer.boundPort!,
    );
    final restartedReq = await rawClient.getUrl(restartedStreamUri);
    restartedReq.headers.set(HttpHeaders.authorizationHeader, 'Bearer $pin');
    final restartedResp = await restartedReq.close();
    final restartedBytes = await restartedResp.expand((c) => c).toList();
    expect(restartedResp.statusCode, HttpStatus.ok);
    expect(restartedBytes, audioBytes);

    // Verify playing the remote track auto-resumes from synced 9-minute cross-platform position
    // and auto-attaches sibling .lrc subtitle URL in remoteMetadata!
    final launched = await remoteController.playTrack(remoteWork, audioNode);
    expect(launched, isTrue);
    expect(launcher.lastTracks.first.lastPlayedPosition, const Duration(minutes: 9));
    expect(launcher.lastTracks.first.remoteMetadata?['subtitleUrl'], isNotNull);
    expect(launcher.lastTracks.first.isRemoteSource, isTrue);

    const phonePosition = Duration(minutes: 10, seconds: 30);
    await clientSync.saveRemoteTrackProgress(
      launcher.lastTracks.first,
      position: phonePosition,
      playedAt: DateTime.now(),
    );

    final launchedVideo = await remoteController.playTrack(remoteWork, videoNode);
    expect(launchedVideo, isTrue);
    expect(launcher.lastTracks.first.isVideo, isTrue);

    // 4. Verify 1-click bidirectional LAN sync exchanges client & server ledgers in 1 round-trip!
    final syncSummary = await remoteController.syncWithLanSource(addedSource.id);
    expect(syncSummary.listeningDaysUpdated, greaterThanOrEqualTo(0));
    expect(_daysMap(await serverDb.loadListeningDays())['2026-11-24'], 2100000);
    expect(_daysMap(await clientDb.loadListeningDays())['2026-11-24'], 2100000);

    final syncedTrack = (await serverDb.loadAllTracks()).firstWhere(
      (track) => track.path == trackFile.path,
    );
    expect(syncedTrack.lastPlayedPosition, phonePosition);

    // 5. Verify remote metadata edit + work folder rename updates disk, JSON, and workId!
    final renamedWork = await remoteController.saveWorkDetail(
      remoteWork,
      metadata: DlsiteMetadata(
        rjCode: 'RJ654321',
        workTitle: 'Bedtime Ear Cleaning Remastered',
        circleName: 'SnowCircle',
        voiceActors: const <String>['CV-A', 'CV-B'],
        tags: const <String>['耳かき', 'バイノーラル'],
        rating: 4.95,
      ),
      newFolderName: '[SnowCircle] RJ654321 Remastered',
      preserveDuration: true,
    );
    final expectedNewDirPath = p.join(
      libraryRoot.path,
      '[SnowCircle] RJ654321 Remastered',
    );
    expect(await Directory(expectedNewDirPath).exists(), isTrue);
    expect(await Directory(workDir.path).exists(), isFalse);
    expect(renamedWork.folderName, '[SnowCircle] RJ654321 Remastered');
    expect(renamedWork.title, 'Bedtime Ear Cleaning Remastered');
    expect(renamedWork.voiceActors, <String>['CV-A', 'CV-B']);
    expect(renamedWork.workId, isNot(remoteWork.workId));

    // 6. Verify remote review edit syncs back to Windows LibraryFacade & client sync ledger!
    final reviewedWork = await remoteController.saveWorkReview(
      renamedWork,
      listenStatus: WorkListenStatus.listened,
      userRating: 5,
      reviewText: 'Edited from Android detail page',
    );
    expect(reviewedWork.listenStatus, 'listened');
    expect(reviewedWork.userRating, 5);
    expect(reviewedWork.reviewText, 'Edited from Android detail page');
    final serverSavedDetail = await libraryFacade.loadAudioDetail(
      AudioDetailTarget.libraryRootFolder(expectedNewDirPath),
    );
    expect(serverSavedDetail.detail.listenStatus, WorkListenStatus.listened);
    expect(serverSavedDetail.detail.userRating, 5);
    expect(serverSavedDetail.detail.reviewText, 'Edited from Android detail page');

    // 7. Verify child entry rename renames the audio file on disk and refreshes tree!
    await remoteController.renameWorkEntry(
      reviewedWork,
      relativePath: '01_ear_cleaning.mp3',
      newName: '01_ear_cleaning_fixed',
      isDirectory: false,
      isMedia: true,
    );
    final renamedTrackPath = p.join(
      expectedNewDirPath,
      '01_ear_cleaning_fixed.mp3',
    );
    expect(await File(renamedTrackPath).exists(), isTrue);
    final refreshedTree = await remoteController.ensureWorkTree(reviewedWork);
    expect(
      refreshedTree.map((n) => n.title),
      contains('01_ear_cleaning_fixed.mp3'),
    );

    // 8. Verify pin toggle + pullRefreshAndSync!
    await remoteController.toggleWorksPinned(
      addedSource.id,
      <String>[reviewedWork.workId],
    );
    expect(
      remoteController.worksFor(addedSource.id).single.isPinned,
      isTrue,
    );
    expect(pinnedPaths, isNotEmpty);

    await clientDb.importListeningBatch('cli-2', const <ListeningDayRecord>[
      ListeningDayRecord(date: '2026-11-25', totalMs: 300000, works: []),
    ]);
    final pulledWorks = await remoteController.pullRefreshAndSync(addedSource.id);
    expect(pulledWorks, hasLength(1));
    expect(_daysMap(await serverDb.loadListeningDays())['2026-11-25'], 300000);

    // 9. Verify allowRemoteEdit = false rejects mutations with 403!
    await lanServer.updateSettings(
      lanServer.settings.copyWith(allowRemoteEdit: false),
    );
    await expectLater(
      remoteController.saveWorkReview(
        reviewedWork,
        listenStatus: WorkListenStatus.replay,
        userRating: 4,
        reviewText: 'Blocked',
      ),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('remote_source_edit_disabled'),
        ),
      ),
    );
    await lanServer.updateSettings(
      lanServer.settings.copyWith(allowRemoteEdit: true),
    );

    // 10. Verify non-destructive removal excludes the work from catalog while keeping files on disk!
    await remoteController.commitRemoveWorks(
      addedSource.id,
      <String>[reviewedWork.workId],
    );
    expect(remoteController.worksFor(addedSource.id), isEmpty);
    await remoteController.refreshSource(addedSource.id);
    expect(remoteController.worksFor(addedSource.id), isEmpty);
    expect(await File(renamedTrackPath).exists(), isTrue);
  });
}
