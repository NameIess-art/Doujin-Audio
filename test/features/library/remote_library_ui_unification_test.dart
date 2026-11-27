import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/search_query_utils.dart';
import 'package:doujin_audio/core/network/remote_source_headers.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/duration_overlay.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/work_listen_status_badge.dart';
import 'package:doujin_audio/core/widgets/work_review_panel.dart';
import 'package:doujin_audio/features/data_support/application/cross_platform_sync_service.dart';
import 'package:doujin_audio/features/library/application/lan_discovery_service.dart';
import 'package:doujin_audio/features/library/application/lan_media_server_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/remote_library_controller.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/domain/remote_media_source.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_empty_scan.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_ui_helpers.dart';
import 'package:doujin_audio/features/library/presentation/library_tree_list.dart';
import 'package:doujin_audio/features/library/presentation/remote_library_work_detail.dart';
import 'package:doujin_audio/features/library/presentation/remote_source_sheets.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_content.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_cross_platform_sync_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/app_runtime_test_fixture.dart';

class _TestPlaybackLauncher implements PlaybackSessionLauncher {
  _TestPlaybackLauncher([this._playback]);

  final PlaybackFacade? _playback;
  int playCalls = 0;
  int queueCalls = 0;

  @override
  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    final resolved = await tracks;
    playCalls++;
    final playback = _playback;
    if (playback != null) {
      if (resolved.isEmpty) return false;
      final current = resolved[startIndex.clamp(0, resolved.length - 1)];
      final session = playback.createTrackSession(
        current,
        loopMode: loopMode,
        customQueueTracks: resolved,
      );
      playback.registerSession(session);
    }
    return true;
  }

  @override
  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  }) async {
    queueCalls++;
    return true;
  }

  @override
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) async {
    queueCalls++;
    return true;
  }
}

class _ProbeHttpHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _ProbeHttpResponse extends Fake implements HttpClientResponse {
  _ProbeHttpResponse(this.statusCode);

  @override
  final int statusCode;

  @override
  Future<E> drain<E>([E? futureValue]) => Future<E>.value(futureValue as E);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _ProbeHttpRequest extends Fake implements HttpClientRequest {
  _ProbeHttpRequest(this._statusCode);

  final int _statusCode;
  final HttpHeaders _headers = _ProbeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() =>
      Future<HttpClientResponse>.value(_ProbeHttpResponse(_statusCode));
}

class _ControllableProbeHttpClient extends Fake implements HttpClient {
  _ControllableProbeHttpClient({required this.isOnline});

  final bool Function() isOnline;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => isOnline()
      ? Future<HttpClientRequest>.value(_ProbeHttpRequest(HttpStatus.ok))
      : Future<HttpClientRequest>.error(
          const SocketException('remote_host_offline'),
        );

  @override
  void close({bool force = false}) {}
}

class _DirectHttpOverrides extends HttpOverrides {}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('doujin_remote_ui_test_');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'app_language': 'zh',
    });
    await AppPreferences.init();
  });

  tearDown(() async {
    RemoteSourceHeaderRegistry.instance.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('LanDiscoveryClient.isUsableLanIpv4Bytes filters proxy TUN 198.18.0.0/15 and non-LAN ranges', () {
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [192, 168, 188, 144]), isTrue);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [10, 0, 0, 5]), isTrue);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [172, 16, 0, 2]), isTrue);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [198, 17, 255, 254]), isTrue);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [198, 20, 0, 1]), isTrue);

    // Proxy virtual TUN fake-IP range (RFC 2544 benchmark block used by Clash/Mihomo/sing-box).
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [198, 18, 0, 1]), isFalse);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [198, 19, 255, 254]), isFalse);

    // Loopback, unspecified, and link-local ranges.
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [127, 0, 0, 1]), isFalse);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [0, 0, 0, 0]), isFalse);
    expect(LanDiscoveryClient.isUsableLanIpv4Bytes(const [169, 254, 12, 34]), isFalse);
  });

  test('filterRemoteLibraryWorks and sortRemoteLibraryWorks match multi-term queries and SearchFilters', () {
    final workA = RemoteLibraryWork(
      sourceId: 's1',
      workId: 'w1',
      title: 'WHITEBOX Healing Ear Cleaning',
      folderName: '[CircleA] RJ280139 WHITEBOX',
      rjCode: 'RJ280139',
      circleName: 'テグラユウキ',
      voiceActors: const <String>['浅木式'],
      tags: const <String>['治愈', '耳かき'],
      durationMs: 3600000,
      trackCount: 5,
      releaseDateMs: 1584144000000,
      rating: 4.9,
      userRating: 5,
      listenStatus: 'listening',
      hasReviewNote: true,
      hasSubtitle: true,
      updatedAtMs: 200,
    );
    final workB = RemoteLibraryWork(
      sourceId: 's1',
      workId: 'w2',
      title: 'Whispering Sleep Aid',
      folderName: '[CircleB] RJ334397 Whispering',
      rjCode: 'RJ334397',
      circleName: '防錆潤滑剤',
      voiceActors: const <String>['こやまはる'],
      tags: const <String>['双声道', '助眠'],
      durationMs: 1200000,
      trackCount: 2,
      releaseDateMs: 1626220800000,
      rating: 4.2,
      userRating: 3,
      listenStatus: 'completed',
      updatedAtMs: 100,
    );

    final andFiltered = filterRemoteLibraryWorks(
      <RemoteLibraryWork>[workA, workB],
      elements: parseSearchElements('浅木式, 治愈')!,
      filters: emptySearchFilters,
    );
    expect(andFiltered.map((w) => w.rjCode), <String>['RJ280139']);

    final orFiltered = filterRemoteLibraryWorks(
      <RemoteLibraryWork>[workA, workB],
      elements: parseSearchElements('(RJ280139)(こやまはる)')!,
      filters: emptySearchFilters,
    );
    expect(orFiltered, hasLength(2));

    final subtitleAndStatusFiltered = filterRemoteLibraryWorks(
      <RemoteLibraryWork>[workA, workB],
      elements: emptySearchElements,
      filters: (
        hasSubtitle: true,
        minimumRating: 4.5,
        minimumUserRating: 5,
        listenStatus: WorkListenStatus.listening,
        minimumDuration: const Duration(minutes: 30),
        maximumDuration: null,
        firstReleaseDate: null,
        lastReleaseDate: null,
      ),
    );
    expect(subtitleAndStatusFiltered.map((w) => w.rjCode), <String>['RJ280139']);

    final byUserRatingAsc = sortRemoteLibraryWorks(
      <RemoteLibraryWork>[workA, workB],
      criterion: LibrarySortCriterion.userRating,
      ascending: true,
    );
    expect(byUserRatingAsc.map((w) => w.rjCode), <String>['RJ334397', 'RJ280139']);

    // Pinned remote works always sort above unpinned works regardless of criterion!
    final pinnedSorted = sortRemoteLibraryWorks(
      <RemoteLibraryWork>[workA, workB.copyWith(isPinned: true)],
      criterion: LibrarySortCriterion.userRating,
      ascending: false,
    );
    expect(pinnedSorted.first.rjCode, 'RJ334397');
  });

  testWidgets(
    'LAN discovery shows selectable results when adding a source only',
    (tester) async {
      final width = defaultTargetPlatform == TargetPlatform.android
          ? 320.0
          : 960.0;
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final i18n = AppLanguageProvider();
      final themeProvider = ThemeProvider();
      final isWindows = defaultTargetPlatform == TargetPlatform.windows;
      final sync = CrossPlatformSyncService();
      final controller = RemoteLibraryController(
        syncService: sync,
        localLanServerId: isWindows ? () => 'local-pc' : null,
      );
      addTearDown(sync.dispose);
      addTearDown(controller.dispose);
      addTearDown(i18n.dispose);
      addTearDown(themeProvider.dispose);

      const servers = [
        LanDiscoveredServer(
          serverId: 'first',
          name: 'PC 1',
          host: '192.168.0.2',
          port: 42871,
          authRequired: true,
          allowSync: true,
        ),
        LanDiscoveredServer(
          serverId: 'second',
          name: 'Media server with a long display name',
          host: '192.168.0.3',
          port: 42871,
          authRequired: true,
          allowSync: true,
        ),
      ];
      var scans = 0;
      RemoteMediaSource? existing;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            remoteLibraryControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            theme: themeProvider.darkTheme,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAddOrEditRemoteSourceDialog(
                    context,
                    existing: existing,
                    discoverLan: () async => ++scans == 1 ? [] : [
                      if (isWindows)
                        const LanDiscoveredServer(
                          serverId: 'local-pc',
                          name: 'This PC',
                          host: '192.168.0.1',
                          port: 42871,
                          authRequired: false,
                          allowSync: true,
                        ),
                      ...servers,
                    ],
                  ),
                  child: Text(i18n.tr('remote_source_add')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(i18n.tr('remote_source_add')));
      await tester.pumpAndSettle();

      final scan = find.widgetWithText(
        TextButton,
        i18n.tr('remote_source_discover'),
      );
      final fields = find.byType(TextField);
      final scanLeft = tester.getTopLeft(scan).dx;
      expect(scanLeft, tester.getTopLeft(fields.first).dx);
      expect(scans, 1);
      expect(find.text('自动扫描同一局域网下已开启共享的电脑'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);

      await tester.tap(scan);
      await tester.pumpAndSettle();

      final results = find.byType(ActionChip);
      expect(results, findsNWidgets(2));
      expect(find.text('This PC'), findsNothing);
      final firstResult = tester.getRect(results.first);
      final secondResult = tester.getRect(results.last);
      final scanRect = tester.getRect(scan);
      expect(scanRect.left, scanLeft);
      expect(firstResult.left, greaterThan(scanRect.right));
      expect(firstResult.left, secondResult.left);
      expect(secondResult.top, greaterThan(firstResult.bottom));
      expect(
        secondResult.right,
        lessThanOrEqualTo(tester.getRect(fields.first).right),
      );
      expect(
        find.descendant(
          of: results.last,
          matching: find.text(servers.last.host),
        ),
        findsOneWidget,
      );

      await tester.tap(results.last);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(fields.at(0)).controller!.text,
        servers.last.name,
      );
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        servers.last.baseUrl,
      );

      await tester.tap(find.text(i18n.tr('cancel')));
      await tester.pumpAndSettle();
      existing = RemoteMediaSource(
        id: 'existing-pc',
        type: RemoteMediaSourceType.windowsLan,
        name: servers.last.name,
        baseUrl: servers.last.baseUrl,
        createdAtMs: 1,
      );
      await tester.tap(find.text(i18n.tr('remote_source_add')));
      await tester.pumpAndSettle();
      expect(find.text(i18n.tr('remote_source_edit_title')), findsOneWidget);
      expect(scan, findsNothing);
      expect(results, findsNothing);
      expect(scans, 2);
      expect(
        tester.widget<TextField>(fields.at(1)).controller!.text,
        servers.last.baseUrl,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'remote source removal uses title-bar undo before deleting credentials',
    (tester) async {
      final i18n = AppLanguageProvider();
      final sync = CrossPlatformSyncService();
      final removalService = UndoableRemovalService();
      final registry = RemoteSourceHeaderRegistry();
      final source = RemoteMediaSource(
        id: 'media-pc',
        type: RemoteMediaSourceType.windowsLan,
        name: 'Media PC',
        baseUrl: 'http://192.168.1.50:42871',
        secretConfigured: true,
        pinnedWorkIds: ['work-1'],
        createdAtMs: 1,
      );
      const sourcesKey = 'remote_media_sources_v1';
      final storedSources = jsonEncode([source.toJson()]);
      String? secret = 'test-access-code';
      var failCredentialDeletion = false;
      final controller = RemoteLibraryController(
        syncService: sync,
        supportDirectoryProvider: () async => tempDir,
        httpClientFactory: () =>
            _ControllableProbeHttpClient(isOnline: () => true),
        readSecret: (_) async => secret,
        writeSecret: (_, value) async {
          if (value == null && failCredentialDeletion) {
            throw StateError('Credential storage unavailable');
          }
          secret = value;
        },
        headerRegistry: registry,
      );
      addTearDown(controller.dispose);
      addTearDown(sync.dispose);
      addTearDown(i18n.dispose);
      addTearDown(removalService.dispose);
      await tester.runAsync(() async {
        await AppPreferences.setString(sourcesKey, storedSources);
        await controller.initialize();
      });
      controller.selectSource(source.id);
      final sourceUri = Uri.parse(source.baseUrl);
      final openLabel = i18n.tr('remote_source_manage');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            remoteLibraryControllerProvider.overrideWith((_) => controller),
            undoableRemovalServiceProvider.overrideWithValue(removalService),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Builder(
                  key: const ValueKey<String>('main_page_canvas'),
                  builder: (context) => TopPageHeader(
                    title: i18n.tr('music_library'),
                    trailing: TextButton(
                      onPressed: () => showManageRemoteSourcesDialog(context),
                      child: Text(openLabel),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(openLabel));
      await tester.pumpAndSettle();
      final sourceRow = find.widgetWithText(ListTile, source.name);
      final delete = find.descendant(
        of: sourceRow,
        matching: find.byTooltip(i18n.tr('delete')),
      );
      await tester.tap(delete);
      await tester.pumpAndSettle();

      expect(sourceRow, findsNothing);
      expect(find.byKey(const ValueKey('app_dialog_surface')), findsOneWidget);
      expect(find.text(i18n.tr('remote_source_empty')), findsOneWidget);
      expect(controller.selectedSource, isNull);
      expect(AppPreferences.getStringSync(sourcesKey), storedSources);
      expect(
        registry.headersForUri(sourceUri)[HttpHeaders.authorizationHeader],
        'Bearer test-access-code',
      );
      final undo = find.text('${i18n.tr('undo')} (5s)');
      expect(undo.hitTestable(), findsOneWidget);
      final banner = find.byType(AppFeedbackSurface);
      expect(
        tester.getTopLeft(banner).dy,
        closeTo(
          24 +
              AppPageHeaderMetrics.mainTabPadding.top +
              AppPageHeaderMetrics.secondRowOffset,
          0.5,
        ),
      );

      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(sourceRow, findsOneWidget);
      expect(controller.selectedSource?.toJson(), source.toJson());
      expect(secret, 'test-access-code');

      Future<void> removeAndWaitForCommit() async {
        await tester.tap(delete);
        await tester.pumpAndSettle();
        await tester.pump(kUndoableRemovalFeedbackDuration);
        await tester.pumpAndSettle();
        expect(removalService.state.pendingCount, 0);
        for (
          var attempts = 0;
          attempts < 20 && removalService.state.committingCount > 0;
          attempts++
        ) {
          await pumpAndSettleWithAsync(tester);
        }
        expect(removalService.state.committingCount, 0);
      }

      failCredentialDeletion = true;
      await removeAndWaitForCommit();
      expect(find.textContaining(i18n.tr('removal_failed')), findsOneWidget);
      expect(sourceRow, findsOneWidget);
      expect(AppPreferences.getStringSync(sourcesKey), storedSources);
      expect(secret, 'test-access-code');

      failCredentialDeletion = false;
      await removeAndWaitForCommit();
      expect(banner, findsNothing);
      expect(sourceRow, findsNothing);
      expect(controller.sources, isEmpty);
      expect(AppPreferences.getStringSync(sourcesKey), '[]');
      expect(registry.headersForUri(sourceUri), isEmpty);
      expect(secret, isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'TopPageHeader top-right source menu, RemoteWorkCardTile, and edit dialog render cleanly under full app theme',
    (tester) async {
      Database? rawDb;
      LibraryFacade? libraryFacade;
      CrossPlatformSyncService? syncService;
      RemoteLibraryController? remoteController;
      late final RemoteMediaSource source;
      late final RemoteLibraryWork remoteWork;
      late final ValueChanged<bool> setProbeOnline;
      final launcher = _TestPlaybackLauncher();

      final i18n = AppLanguageProvider();
      final themeProvider = ThemeProvider();
      addTearDown(() async {
        i18n.dispose();
        themeProvider.dispose();
        remoteController?.dispose();
        syncService?.dispose();
        await tester.runAsync(() async {
          await libraryFacade?.dispose();
          await rawDb?.close();
        });
      });

      await tester.runAsync(() async {
        final previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        try {
          final openedDb = await databaseFactoryFfi.openDatabase(
            p.join(tempDir.path, 'ui_test.db'),
          );
          rawDb = openedDb;
          await AppDatabase.createSchemaForTest(openedDb);
          final db = AppDatabase.test(openedDb);

          final workDir = await Directory(
            p.join(tempDir.path, 'VoiceLib', '[Snow] RJ999888 Sweet Whisper'),
          ).create(recursive: true);
          final trackFile = File(p.join(workDir.path, '01.mp3'));
          await trackFile.writeAsBytes(const <int>[1, 2, 3, 4]);

          final libraryService = LibraryService();
          libraryService.watchedLibraries.add(p.dirname(workDir.path));
          final track = MusicTrack(
            path: trackFile.path,
            displayName: '01.mp3',
            groupKey: workDir.path,
            groupTitle: '[Snow] RJ999888 Sweet Whisper',
            groupSubtitle: workDir.path,
            isSingle: false,
            duration: const Duration(minutes: 42),
          );
          libraryService.library.add(track);
          libraryService.groupOrder.add(workDir.path);
          libraryService.rebuildLibraryIndexes();

          final libraryRepo = SqliteLibraryRepository(database: db);
          await libraryRepo.saveAllTracks(<MusicTrack>[track]);
          final facade = LibraryFacade.create(
            databaseRepository: libraryRepo,
            jsonDocumentStore: DefaultJsonDocumentStore(),
            service: libraryService,
          );
          libraryFacade = facade;

          await facade.saveAudioDetail(
            AudioDetail(
              target: AudioDetailTarget.libraryRootFolder(workDir.path),
              rjCode: 'RJ999888',
              workTitle: 'Sweet Whisper',
              circleName: 'SnowStudio',
              voiceActors: const <String>['CV-Test'],
              tags: const <String>['助眠'],
              rating: 4.8,
            ),
          );

          final secrets = <String, String>{};
          final sync = CrossPlatformSyncService(
            repository: SqliteCrossPlatformSyncRepository(database: db),
            platformName: 'windows',
            deviceName: 'PC',
          );
          syncService = sync;
          final lanServer = LanMediaServerService(
            library: facade,
            syncService: sync,
            bindAddress: InternetAddress.loopbackIPv4,
            enableDiscovery: false,
            allowNonWindowsForTest: true,
            serverName: 'pc',
            readSecret: (k) async => secrets[k],
            writeSecret: (k, v) async {
              if (v == null) {
                secrets.remove(k);
              } else {
                secrets[k] = v;
              }
            },
          );
          await lanServer.initialize();
          await lanServer.updateSettings(
            const LanServerSettings(
              enabled: true,
              port: 0,
              requireAccessCode: false,
            ),
          );

          var useFakeProbe = false;
          var probeOnline = true;
          var probeTime = DateTime(2026);
          final ctrl = RemoteLibraryController(
            syncService: sync,
            playbackLauncher: launcher,
            clock: () => probeTime,
            supportDirectoryProvider: () async => tempDir,
            httpClientFactory: () => useFakeProbe
                ? _ControllableProbeHttpClient(isOnline: () => probeOnline)
                : HttpClient(),
            readSecret: (k) async => secrets[k],
            writeSecret: (k, v) async {
              if (v == null) {
                secrets.remove(k);
              } else {
                secrets[k] = v;
              }
            },
          );
          remoteController = ctrl;
          source = await ctrl.addOrUpdateSource(
            name: 'pc',
            type: RemoteMediaSourceType.windowsLan,
            baseUrl: 'http://127.0.0.1:${lanServer.boundPort}',
          );
          await ctrl.refreshSource(source.id);
          remoteWork = ctrl.worksFor(source.id).single;
          await lanServer.stopForShutdown(fastShutdown: true);
          lanServer.dispose();
          useFakeProbe = true;
          // Expose probeOnline mutator via closure below.
          setProbeOnline = (value) {
            probeOnline = value;
            probeTime = probeTime.add(const Duration(seconds: 6));
          };
        } finally {
          HttpOverrides.global = previousHttpOverrides;
        }
      });
      expect(remoteWork.trackCount, 1);
      expect(remoteWork.folderName, '[Snow] RJ999888 Sweet Whisper');

      final facade = libraryFacade!;
      final controller = remoteController!;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(facade),
            remoteLibraryControllerProvider.overrideWith((ref) => controller),
            settingsStateProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            theme: themeProvider.darkTheme,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final active = ref
                      .watch(remoteLibraryControllerProvider)
                      .selectedSource;
                  return Column(
                    children: [
                      TopPageHeader(
                        topCapsuleLeading: Icon(
                          active == null
                              ? Icons.library_music_rounded
                              : Icons.desktop_windows_rounded,
                        ),
                        topCapsuleTitle: active?.name ?? i18n.tr('library'),
                        topCapsuleData: active == null ? '1个作品' : '1个作品 1首音频',
                        topRowTrailing: const HeaderFloatingButton(
                          child: LibrarySourceMenuButton(),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                            horizontal:
                                LibraryLikeCardMetrics.listHorizontalPadding,
                          ),
                          children: [
                            RemoteWorkCardTile(
                              work: RemoteLibraryWork(
                                sourceId: remoteWork.sourceId,
                                workId: remoteWork.workId,
                                title: remoteWork.title,
                                folderName: remoteWork.folderName,
                                rjCode: remoteWork.rjCode,
                                circleName: remoteWork.circleName,
                                voiceActors: remoteWork.voiceActors,
                                tags: remoteWork.tags,
                                durationMs: remoteWork.durationMs,
                                trackCount: remoteWork.trackCount,
                                rating: remoteWork.rating,
                                userRating: 5,
                                listenStatus: 'listening',
                                hasReviewNote: true,
                                hasSubtitle: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Verify unified card widgets match Local Library RootFolderCardContent.
      expect(find.byType(CoverArtworkFrame), findsOneWidget);
      expect(find.byType(DurationOverlay), findsOneWidget);
      expect(find.byType(WorkListenStatusBadge), findsOneWidget);
      expect(find.byType(LibraryLikeCardActions), findsOneWidget);
      expect(find.byIcon(Icons.add_circle_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      // 1. Online check: tapping top-right source menu probes 'pc', keeps it enabled, and enters it.
      expect(controller.selectedSource, isNull);
      await tester.tap(
        find.byKey(const ValueKey<String>('library_source_menu_button')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.canEnterSource(source.id), isTrue);
      expect(find.text('pc'), findsOneWidget);

      await tester.tap(find.text('pc'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.selectedSource?.id, source.id);
      expect(find.text('1个作品 1首音频'), findsOneWidget);

      // Open the source menu while 'pc' is selected: verify there is NO standalone
      // "同步进度" item, and verify the edit dialog opens cleanly without layout errors.
      await tester.tap(
        find.byKey(const ValueKey<String>('library_source_menu_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text(i18n.tr('remote_lan_sync_now')), findsNothing);
      await tester.tap(find.text(i18n.tr('remote_source_edit_title')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsWidgets);
      final testButton = find.widgetWithIcon(
        IconButton,
        Icons.network_check_rounded,
      );
      final confirm = find.text(i18n.tr('confirm'));
      expect(find.text(i18n.tr('network_test')), findsNothing);
      final testCenter = tester.getCenter(testButton);
      final confirmCenter = tester.getCenter(confirm);
      expect(testCenter.dx, lessThan(confirmCenter.dx));
      expect(testCenter.dy, closeTo(confirmCenter.dy, 1));
      await tester.tap(testButton);
      await pumpUntilFound(
        tester,
        find.text(i18n.tr('remote_source_test_success')),
      );
      await tester.tap(find.text(i18n.tr('cancel')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('library_source_menu_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(i18n.tr('remote_source_manage')));
      await tester.pumpAndSettle();
      final sourceRow = find.widgetWithText(ListTile, source.name);
      await tester.tap(
        find.descendant(of: sourceRow, matching: find.text(source.name)),
      );
      await tester.pumpAndSettle();
      expect(find.text(i18n.tr('remote_source_edit_title')), findsOneWidget);
      expect(find.text(i18n.tr('remote_source_manage')), findsNothing);
      await tester.tap(find.text(i18n.tr('cancel')));
      await tester.pumpAndSettle();

      // 2. Offline check: return to Local Library, take 'pc' offline, and open source menu.
      // It must probe first, grey out 'pc' (cloud_off + disabled InkWell), and prevent entering!
      controller.selectSource(null);
      setProbeOnline(false);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('library_source_menu_button')),
      );
      await tester.pumpAndSettle();
      expect(controller.isSourceOffline(source.id), isTrue);
      expect(controller.canEnterSource(source.id), isFalse);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

      final pcMenuInkWell = tester.widget<AppEntryInkWell>(
        find.ancestor(
          of: find.text('pc'),
          matching: find.byType(AppEntryInkWell),
        ),
      );
      expect(pcMenuInkWell.onTap, isNull);

      await tester.tap(find.text('pc'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(controller.selectedSource, isNull);

      // Dismiss popup menu and verify RemoteWorkCardTile is also greyed out (Opacity 0.45) and disabled!
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.45),
        findsOneWidget,
      );
      final cardInkWell = tester.widget<AppEntryInkWell>(
        find.ancestor(
          of: find.text('Sweet Whisper'),
          matching: find.byType(AppEntryInkWell),
        ),
      );
      expect(cardInkWell.onTap, isNull);
    },
  );

  testWidgets(
    'RemoteWorkCardTile long-press enters multi-select and RemoteLibraryWorkDetail renders Edit Info instead of DL',
    (tester) async {
      Database? rawDb;
      LibraryFacade? libraryFacade;
      CrossPlatformSyncService? syncService;
      RemoteLibraryController? remoteController;
      final i18n = AppLanguageProvider();
      final themeProvider = ThemeProvider();

      addTearDown(() async {
        i18n.dispose();
        themeProvider.dispose();
        remoteController?.dispose();
        syncService?.dispose();
        await tester.runAsync(() async {
          await libraryFacade?.dispose();
          await rawDb?.close();
        });
      });

      late final RemoteLibraryWork sampleWork;
      await tester.runAsync(() async {
        final openedDb = await databaseFactoryFfi.openDatabase(
          p.join(tempDir.path, 'detail_ui_test.db'),
        );
        rawDb = openedDb;
        await AppDatabase.createSchemaForTest(openedDb);
        final db = AppDatabase.test(openedDb);
        final libraryRepo = SqliteLibraryRepository(database: db);
        final facade = LibraryFacade.create(
          databaseRepository: libraryRepo,
          jsonDocumentStore: DefaultJsonDocumentStore(),
          service: LibraryService(),
        );
        libraryFacade = facade;
        final sync = CrossPlatformSyncService(
          repository: SqliteCrossPlatformSyncRepository(database: db),
          platformName: 'android',
          deviceName: 'Phone',
        );
        syncService = sync;
        final ctrl = RemoteLibraryController(
          syncService: sync,
          playbackLauncher: _TestPlaybackLauncher(),
          supportDirectoryProvider: () async => tempDir,
          readSecret: (_) async => null,
          writeSecret: (_, _) async {},
        );
        remoteController = ctrl;
        await ctrl.initialize();
        sampleWork = RemoteLibraryWork(
          sourceId: 'src-1',
          workId: 'w-1',
          title: 'Remote Detail Edit Test',
          folderName: '[Circle] RJ777888 Remote Detail Edit Test',
          rjCode: 'RJ777888',
          circleName: 'Circle',
          voiceActors: const <String>['CV-1'],
          tags: const <String>['治愈'],
          durationMs: 1800000,
          trackCount: 2,
          listenStatus: 'listening',
          userRating: 4,
          reviewText: 'Synced review note',
          hasReviewNote: true,
        );
      });

      // 1. Long-pressing RemoteWorkCardTile enters multi-select mode with LibraryBatchSelectionHeader!
      var isSelectionMode = false;
      final selectedIds = <String>{};
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(libraryFacade!),
            remoteLibraryControllerProvider.overrideWith(
              (ref) => remoteController!,
            ),
            settingsStateProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            theme: themeProvider.darkTheme,
            home: StatefulBuilder(
              builder: (context, setLocalState) => Scaffold(
                body: Column(
                  children: [
                    if (isSelectionMode)
                      LibraryBatchSelectionHeader(
                        keyPrefix: 'library',
                        i18n: i18n,
                        selectedCount: selectedIds.length,
                        allSelected: selectedIds.length == 1,
                        onToggleSelectAll: () {},
                        onEditInfo: () {},
                        onAddToPlaylist: () {},
                        onCompleteMetadata: () {},
                        onTogglePin: () {},
                        onRemove: () {},
                        onExit: () => setLocalState(() {
                          isSelectionMode = false;
                          selectedIds.clear();
                        }),
                      ),
                    Expanded(
                      child: ListView(
                        children: [
                          RemoteWorkCardTile(
                            work: sampleWork,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedIds.contains(sampleWork.workId),
                            onLongPress: () => setLocalState(() {
                              isSelectionMode = true;
                              selectedIds.add(sampleWork.workId);
                            }),
                            onToggleSelect: () => setLocalState(() {
                              if (!selectedIds.remove(sampleWork.workId)) {
                                selectedIds.add(sampleWork.workId);
                              }
                            }),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryBatchSelectionHeader), findsNothing);

      await tester.longPress(find.text('Remote Detail Edit Test'));
      await tester.pumpAndSettle();
      expect(isSelectionMode, isTrue);
      expect(find.byType(LibraryBatchSelectionHeader), findsOneWidget);

      // 2. WorkDetailPage.forRemote(work: RemoteLibraryWorkDetail(...)) shows
      // top-right Edit Info button ('work_detail_edit') instead of 'DL' ('work_detail_dlsite'),
      // and renders WorkUserReviewSection!
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(libraryFacade!),
            remoteLibraryControllerProvider.overrideWith(
              (ref) => remoteController!,
            ),
            settingsStateProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            theme: themeProvider.darkTheme,
            home: WorkDetailPage.forRemote(
              work: RemoteLibraryWorkDetail(sampleWork),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('work_detail_edit')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('work_detail_dlsite')), findsNothing);
      expect(find.byType(WorkUserReviewSection), findsOneWidget);
      expect(find.text('Synced review note'), findsOneWidget);
    },
  );

  testWidgets(
    'RemoteLibraryBrowseView shows transient SnackBar without persistent top OperationStatusBanner when refresh fails',
    (tester) async {
      Database? rawDb;
      LibraryFacade? libraryFacade;
      CrossPlatformSyncService? syncService;
      RemoteLibraryController? remoteController;
      late final RemoteMediaSource unreachableSource;
      final i18n = AppLanguageProvider();
      final themeProvider = ThemeProvider();
      final scrollController = ScrollController();

      addTearDown(() async {
        scrollController.dispose();
        i18n.dispose();
        themeProvider.dispose();
        remoteController?.dispose();
        syncService?.dispose();
        await tester.runAsync(() async {
          await libraryFacade?.dispose();
          await rawDb?.close();
        });
      });

      await tester.runAsync(() async {
        final openedDb = await databaseFactoryFfi.openDatabase(
          p.join(tempDir.path, 'err_banner_test.db'),
        );
        rawDb = openedDb;
        await AppDatabase.createSchemaForTest(openedDb);
        final db = AppDatabase.test(openedDb);
        final facade = LibraryFacade.create(
          databaseRepository: SqliteLibraryRepository(database: db),
          jsonDocumentStore: DefaultJsonDocumentStore(),
          service: LibraryService(),
        );
        libraryFacade = facade;
        final sync = CrossPlatformSyncService(
          repository: SqliteCrossPlatformSyncRepository(database: db),
          platformName: 'android',
          deviceName: 'Phone',
        );
        syncService = sync;
        final ctrl = RemoteLibraryController(
          syncService: sync,
          playbackLauncher: _TestPlaybackLauncher(),
          supportDirectoryProvider: () async => tempDir,
          readSecret: (_) async => null,
          writeSecret: (_, _) async {},
        );
        remoteController = ctrl;
        unreachableSource = await ctrl.addOrUpdateSource(
          id: 'dead-lan',
          name: 'pc',
          type: RemoteMediaSourceType.windowsLan,
          baseUrl: 'http://127.0.0.1:1',
        );
        // Seed a cached work file on disk and reload controller so works.isNotEmpty while error != null.
        final cacheFile = File(
          p.join(tempDir.path, 'remote_source_catalogs', 'dead-lan.json'),
        );
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsString(
          '[{"sourceId":"dead-lan","workId":"w1","title":"Cached Work","rjCode":"RJ111222"}]',
        );
      });

      // Create a fresh controller reading the cached work from disk whose HTTP client fails deterministically.
      late final RemoteLibraryController freshController;
      await tester.runAsync(() async {
        freshController = RemoteLibraryController(
          syncService: syncService!,
          playbackLauncher: _TestPlaybackLauncher(),
          supportDirectoryProvider: () async => tempDir,
          httpClientFactory: () => throw const SocketException('unreachable'),
          readSecret: (_) async => null,
          writeSecret: (_, _) async {},
        );
        await freshController.initialize();
      });
      addTearDown(freshController.dispose);
      expect(freshController.worksFor(unreachableSource.id), hasLength(1));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(libraryFacade!),
            remoteLibraryControllerProvider.overrideWith(
              (ref) => freshController,
            ),
            settingsStateProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            theme: themeProvider.darkTheme,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    TextButton(
                      onPressed: () => refreshRemoteSourceWithFeedback(
                        context,
                        ref,
                        unreachableSource.id,
                        syncProgress: false,
                      ),
                      child: const Text('Trigger Refresh'),
                    ),
                    Expanded(
                      child: RemoteLibraryBrowseView(
                        source: unreachableSource,
                        scrollController: scrollController,
                        topPadding: 0,
                        bottomPadding: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trigger Refresh'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Transient feedback toast appears, and NO persistent OperationStatusBanner is shown!
      expect(
        find.textContaining(i18n.tr('remote_source_load_failed')),
        findsOneWidget,
      );
      expect(find.byType(OperationStatusBanner), findsNothing);

      // After toast duration elapses, nothing remains stuck on screen!
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.textContaining(i18n.tr('remote_source_load_failed')),
        findsNothing,
      );
      expect(find.byType(OperationStatusBanner), findsNothing);
    },
  );

  testWidgets(
    'refreshRemoteSourceWithFeedback shows feedback for no changes, additions, and metadata updates',
    (tester) async {
      Database? rawDb;
      LibraryFacade? libraryFacade;
      CrossPlatformSyncService? syncService;
      RemoteLibraryController? remoteController;
      final i18n = AppLanguageProvider();
      final themeProvider = ThemeProvider();
      final scrollController = ScrollController();

      addTearDown(() async {
        scrollController.dispose();
        i18n.dispose();
        themeProvider.dispose();
        remoteController?.dispose();
        syncService?.dispose();
        await tester.runAsync(() async {
          await libraryFacade?.dispose();
          await rawDb?.close();
        });
      });

      var serverWorks = <Map<String, Object?>>[
        <String, Object?>{
          'workId': 'w1',
          'rjCode': 'RJ111222',
          'title': 'Initial Title',
          'folderName': 'RJ111222 Initial Title',
          'circleName': 'Circle',
          'voiceActors': <String>[],
          'tags': <String>[],
          'durationMs': 60000,
          'trackCount': 1,
          'hasSubtitle': false,
          'updatedAtMs': 100,
        },
      ];
      late final HttpServer server;
      late final RemoteMediaSource source;

      await tester.runAsync(() async {
        final previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        try {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            if (request.uri.path == '/api/v1/info') {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                '{"serverId":"srv","name":"PC","port":${server.port},"authRequired":false,"allowSync":false,"allowEdit":true,"protocolVersion":1}',
              );
              await request.response.close();
              return;
            }
            if (request.uri.path == '/api/v1/works') {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode(<String, Object?>{'works': serverWorks}),
              );
              await request.response.close();
              return;
            }
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
          });

          final openedDb = await databaseFactoryFfi.openDatabase(
            p.join(tempDir.path, 'refresh_feedback_test.db'),
          );
          rawDb = openedDb;
          await AppDatabase.createSchemaForTest(openedDb);
          final db = AppDatabase.test(openedDb);
          final facade = LibraryFacade.create(
            databaseRepository: SqliteLibraryRepository(database: db),
            jsonDocumentStore: DefaultJsonDocumentStore(),
            service: LibraryService(),
          );
          libraryFacade = facade;
          final sync = CrossPlatformSyncService(
            repository: SqliteCrossPlatformSyncRepository(database: db),
            platformName: 'android',
            deviceName: 'Phone',
          );
          syncService = sync;
          final ctrl = RemoteLibraryController(
            syncService: sync,
            playbackLauncher: _TestPlaybackLauncher(),
            supportDirectoryProvider: () async => tempDir,
            httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
              HttpClient.new,
              _DirectHttpOverrides(),
            ),
            readSecret: (_) async => null,
            writeSecret: (_, _) async {},
          );
          remoteController = ctrl;
          source = await ctrl.addOrUpdateSource(
            id: 'lan-feedback',
            name: 'pc',
            type: RemoteMediaSourceType.windowsLan,
            baseUrl: 'http://127.0.0.1:${server.port}',
          );
          await ctrl.refreshSource(source.id);
        } finally {
          HttpOverrides.global = previousHttpOverrides;
        }
      });
      addTearDown(() => server.close(force: true));

      Future<void>? pendingRefresh;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(i18n),
            libraryFacadeProvider.overrideWithValue(libraryFacade!),
            remoteLibraryControllerProvider.overrideWith(
              (ref) => remoteController!,
            ),
            settingsStateProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            theme: themeProvider.darkTheme,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    TextButton(
                      onPressed: () {
                        pendingRefresh = refreshRemoteSourceWithFeedback(
                          context,
                          ref,
                          source.id,
                          syncProgress: true,
                        );
                      },
                      child: const Text('Refresh Now'),
                    ),
                    Expanded(
                      child: RemoteLibraryBrowseView(
                        source: source,
                        scrollController: scrollController,
                        topPadding: 0,
                        bottomPadding: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> triggerRefreshAndWaitForText(String expected) async {
        // Expire any previous 2-second feedback banner and its dismiss motion.
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(milliseconds: 400));
        pendingRefresh = null;
        await tester.tap(find.text('Refresh Now'));
        await tester.pump();
        final activeRefresh = pendingRefresh;
        expect(activeRefresh, isNotNull);
        var done = false;
        unawaited(activeRefresh!.whenComplete(() => done = true));
        for (var i = 0; i < 100 && !done; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(done, isTrue);
        await tester.pump();
        expect(find.textContaining(expected), findsOneWidget);
      }

      // 1. Refresh with no data changes still shows feedback.
      await triggerRefreshAndWaitForText(
        i18n.tr('remote_source_refresh_no_changes'),
      );

      // 2. Refresh after a new work is added shows added count.
      serverWorks = <Map<String, Object?>>[
        ...serverWorks,
        <String, Object?>{
          'workId': 'w2',
          'rjCode': 'RJ333444',
          'title': 'Added Work',
          'folderName': 'RJ333444 Added Work',
          'circleName': 'Circle',
          'voiceActors': <String>[],
          'tags': <String>[],
          'durationMs': 60000,
          'trackCount': 1,
          'hasSubtitle': false,
          'updatedAtMs': 200,
        },
      ];
      await triggerRefreshAndWaitForText(
        i18n.tr('remote_source_refresh_added', {'count': 1}),
      );

      // 3. Refresh after existing work metadata changes shows updated feedback.
      serverWorks = <Map<String, Object?>>[
        <String, Object?>{
          ...serverWorks.first,
          'title': 'Updated Title',
          'updatedAtMs': 300,
        },
        serverWorks[1],
      ];
      await triggerRefreshAndWaitForText(
        i18n.tr('remote_source_refresh_updated'),
      );

      // 4. Refreshing an empty remote source with no changes also shows no-changes feedback.
      serverWorks = <Map<String, Object?>>[];
      await triggerRefreshAndWaitForText(
        i18n.tr('remote_source_refresh_updated'),
      );
      await triggerRefreshAndWaitForText(
        i18n.tr('remote_source_refresh_no_changes'),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'SessionDetailContent opens remote WorkDetailPage without local error for active remote-source track',
    (tester) async {
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _DirectHttpOverrides();
      addTearDown(() => HttpOverrides.global = previousHttpOverrides);

      Database? rawDb;
      CrossPlatformSyncService? syncService;
      RemoteLibraryController? remoteController;
      AppRuntimeWidgetTestFixture? fixture;
      HttpServer? server;

      addTearDown(() async {
        await server?.close(force: true);
        remoteController?.dispose();
        syncService?.dispose();
        fixture?.dispose();
        await tester.runAsync(() async {
          await rawDb?.close();
        });
      });

      late final RemoteMediaSource source;
      late final RemoteLibraryWork work;

      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final srv = server!;
        srv.listen((request) async {
          if (request.uri.path == '/api/v1/info') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              '{"serverId":"srv-nav","name":"PC","port":${srv.port},"authRequired":false,"allowSync":false,"allowEdit":true,"protocolVersion":1}',
            );
            await request.response.close();
            return;
          }
          if (request.uri.path == '/api/v1/works') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object?>{
                'works': <Map<String, Object?>>[
                  <String, Object?>{
                    'workId': 'w_session_nav',
                    'rjCode': 'RJ999888',
                    'title': 'Session Nav Remote Work',
                    'folderName': '[Circle] RJ999888 Session Nav Remote Work',
                    'circleName': 'Circle',
                    'voiceActors': <String>[],
                    'tags': <String>[],
                    'durationMs': 60000,
                    'trackCount': 1,
                    'hasSubtitle': false,
                    'updatedAtMs': 100,
                  },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          if (request.uri.path == '/api/v1/works/w_session_nav/tree') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object?>{
                'workId': 'w_session_nav',
                'tree': <Map<String, Object?>>[
                  <String, Object?>{
                    'hash': 'f1',
                    'title': '01_remote_track.mp3',
                    'type': 'audio',
                    'size': 1234,
                    'duration': 60,
                    'mediaStreamUrl': '/api/v1/stream/f1/01_remote_track.mp3',
                  },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });

        final openedDb = await databaseFactoryFfi.openDatabase(
          p.join(tempDir.path, 'session_detail_remote_work_nav.db'),
        );
        rawDb = openedDb;
        await AppDatabase.createSchemaForTest(openedDb);
        final db = AppDatabase.test(openedDb);
        fixture = AppRuntimeWidgetTestFixture();
        syncService = CrossPlatformSyncService(
          repository: SqliteCrossPlatformSyncRepository(database: db),
          platformName: 'android',
          deviceName: 'Phone',
        );
        remoteController = RemoteLibraryController(
          syncService: syncService!,
          playbackLauncher: _TestPlaybackLauncher(fixture!.playback),
          supportDirectoryProvider: () async => tempDir,
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
            HttpClient.new,
            _DirectHttpOverrides(),
          ),
          readSecret: (_) async => null,
          writeSecret: (_, _) async {},
        );
        await remoteController!.initialize();
        source = await remoteController!.addOrUpdateSource(
          id: 'lan-nav',
          name: 'pc',
          type: RemoteMediaSourceType.windowsLan,
          baseUrl: 'http://127.0.0.1:${srv.port}',
        );
        await remoteController!.refreshSource(source.id);
        work = remoteController!.worksFor(source.id).single;
        final played = await remoteController!.playWork(work);
        expect(played, isTrue);
      });

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final runtimeSession = fixture!.playback.sessions.values.single;
      final session = PlaybackSessionSnapshot.fromRuntime(runtimeSession);

      await tester.pumpWidget(
        fixture!.build(
          Scaffold(
            body: SessionDetailContent(
              session: session,
              artworkWidget: const SizedBox.shrink(),
              isLandscape: true,
            ),
          ),
          overrides: [
            remoteLibraryControllerProvider.overrideWith(
              (ref) => remoteController!,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final workDetailButton = find.byKey(
        const ValueKey('session_work_detail_button'),
      );
      expect(workDetailButton, findsOneWidget);
      await tester.tap(workDetailButton);

      final workDetailFinder = find.byType(WorkDetailPage);
      final workDetailTrackFinder = find.descendant(
        of: workDetailFinder,
        matching: find.text('01_remote_track'),
      );
      for (var i = 0;
          i < 100 && workDetailTrackFinder.evaluate().isEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(workDetailFinder, findsOneWidget);
      final workDetailPage = tester.widget<WorkDetailPage>(workDetailFinder);
      expect(
        workDetailPage.remoteWork,
        isA<RemoteLibraryWorkDetail>().having(
          (detail) => detail.work.workId,
          'workId',
          'w_session_nav',
        ),
      );
      expect(workDetailTrackFinder, findsOneWidget);
      expect(
        find.byKey(const ValueKey('work_detail_directory_error')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'LibraryTab retains local & remote panes without empty-card or remount flicker across source switches',
    (tester) async {
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _DirectHttpOverrides();
      addTearDown(() => HttpOverrides.global = previousHttpOverrides);

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      Database? rawDb;
      CrossPlatformSyncService? syncService;
      RemoteLibraryController? remoteController;
      AppRuntimeWidgetTestFixture? fixture;
      HttpServer? server;

      addTearDown(() async {
        await tester.runAsync(() async {
          await server?.close(force: true);
          await rawDb?.close();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        remoteController?.dispose();
        syncService?.dispose();
        fixture?.dispose();
      });

      var holdSourceA = false;
      final gateA = Completer<void>();

      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final srv = server!;
        srv.listen((request) async {
          final path = request.uri.path;
          if (path == '/a/api/v1/works') {
            if (holdSourceA && !gateA.isCompleted) {
              await gateA.future;
            }
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object?>{
                'works': <Map<String, Object?>>[
                  for (var i = 1; i <= 36; i++)
                    <String, Object?>{
                      'workId': 'wa-$i',
                      'rjCode': 'RJ1000${i.toString().padLeft(2, '0')}',
                      'title': 'Remote Work A$i',
                      'folderName': 'Remote Work A$i',
                      'circleName': 'Circle A',
                      'voiceActors': <String>[],
                      'tags': <String>[],
                      'durationMs': 60000,
                      'trackCount': 1,
                      'hasSubtitle': false,
                      'updatedAtMs': 100 + i,
                    },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          if (path == '/b/api/v1/works') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object?>{
                'works': <Map<String, Object?>>[
                  <String, Object?>{
                    'workId': 'wb-1',
                    'rjCode': 'RJ200001',
                    'title': 'Remote Work B1',
                    'folderName': 'Remote Work B1',
                    'circleName': 'Circle B',
                    'voiceActors': <String>[],
                    'tags': <String>[],
                    'durationMs': 60000,
                    'trackCount': 1,
                    'hasSubtitle': false,
                    'updatedAtMs': 200,
                  },
                ],
              }),
            );
            await request.response.close();
            return;
          }
          if (path == '/a/api/v1/info' || path == '/b/api/v1/info') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              '{"serverId":"srv-sw","name":"PC","port":${srv.port},"authRequired":false,"allowSync":false,"allowEdit":true,"protocolVersion":1}',
            );
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        });

        await AppPreferences.setString(
          'remote_media_sources_v1',
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'src-a',
              'type': 'windowsLan',
              'name': 'Remote A',
              'baseUrl': 'http://127.0.0.1:${srv.port}/a',
              'allowSync': false,
              'allowEdit': true,
            },
            <String, Object?>{
              'id': 'src-b',
              'type': 'windowsLan',
              'name': 'Remote B',
              'baseUrl': 'http://127.0.0.1:${srv.port}/b',
              'allowSync': false,
              'allowEdit': true,
            },
          ]),
        );

        final openedDb = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
        );
        rawDb = openedDb;
        await AppDatabase.createSchemaForTest(openedDb);
        final db = AppDatabase.test(openedDb);
        fixture = AppRuntimeWidgetTestFixture();
        fixture!.library.addTracks([
          for (var i = 1; i <= 25; i++)
            MusicTrack(
              path: '/local/Local Work ${i.toString().padLeft(2, '0')}/01.mp3',
              displayName: 'Track $i',
              groupKey: '/local/Local Work ${i.toString().padLeft(2, '0')}',
              groupTitle: 'Local Work ${i.toString().padLeft(2, '0')}',
              groupSubtitle: 'Circle Local',
              isSingle: false,
            ),
        ], persist: false);
        await fixture!.library.ensureCardSnapshot();
        fixture!.library.syncPresentationState(isInitialized: true);

        syncService = CrossPlatformSyncService(
          repository: SqliteCrossPlatformSyncRepository(database: db),
          platformName: 'windows',
          deviceName: 'PC',
        );
        remoteController = RemoteLibraryController(
          syncService: syncService!,
          playbackLauncher: _TestPlaybackLauncher(),
          supportDirectoryProvider: () async => tempDir,
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
            HttpClient.new,
            _DirectHttpOverrides(),
          ),
          readSecret: (_) async => null,
          writeSecret: (_, _) async {},
        );
        await remoteController!.initialize();
        await remoteController!.probeAllSourcesConnection();
      });

      await tester.pumpWidget(
        fixture!.build(
          const LibraryTab(),
          overrides: [
            remoteLibraryControllerProvider.overrideWith(
              (ref) => remoteController!,
            ),
          ],
        ),
      );
      await pumpUntilFound(tester, find.text('Local Work 01'));
      await tester.pumpAndSettle();

      final initialTreeListState = tester.state(find.byType(LibraryTreeList));
      final scrollableFinder = find.descendant(
        of: find.byType(LibraryTreeList),
        matching: find.byType(Scrollable),
      );
      final localScrollable = tester.state<ScrollableState>(
        scrollableFinder.first,
      );
      localScrollable.position.jumpTo(180);
      await tester.pump();
      expect(localScrollable.position.pixels, 180);

      // 1. Switch Local -> unloaded Remote A: skeleton shows immediately without flashing empty card.
      holdSourceA = true;
      remoteController!.selectSource('src-a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(LibraryLoadingSkeleton), findsOneWidget);
      expect(
        find.text(fixture!.languageProvider.tr('remote_source_empty')),
        findsNothing,
      );

      // Release Remote A response and verify its catalog renders.
      gateA.complete();
      final remoteAItem = find.text('Remote Work A1');
      for (var i = 0;
          i < 100 &&
              (remoteController!.isLoading('src-a') ||
                  remoteAItem.evaluate().isEmpty);
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(remoteAItem, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));

      // Scroll Remote A independently.
      final remoteAViewFinder = find.byKey(
        const ValueKey<String>('remote_view_src-a'),
      );
      final remoteACustomScroll = tester.widget<CustomScrollView>(
        find.descendant(
          of: remoteAViewFinder,
          matching: find.byType(CustomScrollView),
        ),
      );
      final remoteAScrollController = remoteACustomScroll.controller!;
      remoteAScrollController.jumpTo(120);
      await tester.pump();
      expect(remoteAScrollController.offset, 120);

      // 2. Switch Remote A -> Remote B -> Local: retained states and scroll offsets stay intact.
      remoteController!.selectSource('src-b');
      final remoteBItem = find.text('Remote Work B1');
      for (var i = 0;
          i < 100 &&
              (remoteController!.isLoading('src-b') ||
                  remoteBItem.evaluate().isEmpty);
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(remoteBItem, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));

      remoteController!.selectSource(null);
      await tester.pump();
      // Returning to retained Local Library never flashes a loading skeleton.
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        identical(tester.state(find.byType(LibraryTreeList)), initialTreeListState),
        isTrue,
      );
      expect(localScrollable.position.pixels, 180);

      // Returning to Remote A preserves its independent scroll offset as well.
      remoteController!.selectSource('src-a');
      await tester.pump(const Duration(milliseconds: 300));
      expect(remoteAScrollController.offset, 120);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
