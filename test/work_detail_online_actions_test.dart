import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_coordinator.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  for (final closeDuringTransition in [false, true]) {
    testWidgets(
      closeDuringTransition
          ? 'closing online details during opening skips file-tree requests'
          : 'online details reuse card metadata and defer the tree until open',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final api = _TrackApi();
        final services = createTestAsmrServices(
          persistenceRepository: fixture.persistenceRepository,
          apiService: api,
        );
        await tester.runAsync(services.preferencesStore.clearForTest);
        final controller = AsmrLibraryController(
          preferencesStore: services.preferencesStore,
          remoteCatalogService: services.remoteCatalogService,
          accountSyncService: services.accountSyncService,
        );
        addTearDown(controller.dispose);
        await tester.runAsync(() => controller.initializeForVisiblePage());
        final work = AsmrWork.fromJson({
          ..._work.toJson(),
          'sourceId': 'RJ008001',
          'circleName': 'Card circle',
          'voiceActors': const ['Card voice'],
          'tags': const ['Card tag'],
        });
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showAsmrWorkDetailSheet(context, work),
                child: const Text('Open detail'),
              ),
            ),
            navigatorObservers: [UiInteractionNavigatorObserver()],
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.tap(find.text('Open detail'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(interaction.isInteracting, isTrue);
        for (final text in [
          work.title,
          'RJ008001',
          'Card circle',
          'Card voice',
          '#Card tag',
        ]) {
          expect(find.text(text), findsOneWidget);
        }
        expect(api.treeRequests, 0);
        expect(api.detailRequests, 0);
        expect(find.text('audio'), findsNothing);

        if (closeDuringTransition) {
          Navigator.of(tester.element(find.byType(WorkDetailPage))).pop();
        }
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        await settleIo(tester);
        expect(api.detailRequests, 0);
        expect(api.treeRequests, closeDuringTransition ? 0 : 1);
        expect(
          find.text('audio'),
          closeDuringTransition ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'online audio/video menus add one work session and remove with undo',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final services = createTestAsmrServices(
        persistenceRepository: fixture.persistenceRepository,
        apiService: _TrackApi(),
      );
      await tester.runAsync(services.preferencesStore.clearForTest);
      final controller = AsmrLibraryController(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.initializeForVisiblePage());
      final coordinator = AsmrPlaybackCoordinator(
        source: controller,
        launcher: PlaybackFacadeSessionLauncher(fixture.playback),
      );
      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forAsmr(work: _work),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
            asmrPlaybackCoordinatorProvider.overrideWithValue(coordinator),
          ],
        ),
      );
      await settleIo(tester);
      expect(find.text('audio'), findsOneWidget);
      expect(find.text('video'), findsOneWidget);
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      final audioMore = find.byKey(const ValueKey('work_entry_more_audio.mp3'));
      await tester.tap(audioMore);
      await tester.pumpAndSettle();
      expect(find.text(fixture.languageProvider.tr('play')), findsOneWidget);
      expect(find.text(fixture.languageProvider.tr('remove')), findsOneWidget);
      await tester.tap(
        find.text(fixture.languageProvider.tr('detail_add_to_queue')),
      );
      await settleIo(tester);
      expect(fixture.playback.sessions, hasLength(1));
      final session = fixture.playback.sessions.values.single;
      expect(session.customQueueTracks, hasLength(2));
      expect(
        session.customQueueTracks!.map((track) => track.displayName),
        <String>['audio', 'video'],
      );
      expect(session.effectivePlaying, isFalse);
      expect(session.isTemporary, isFalse);

      if (defaultTargetPlatform == TargetPlatform.windows) {
        await tester.tap(find.text('video'), buttons: kSecondaryMouseButton);
      } else {
        await tester.tap(
          find.byKey(const ValueKey('work_entry_more_video.mp4')),
        );
      }
      await tester.pumpAndSettle();
      expect(
        find.text(fixture.languageProvider.tr('detail_add_to_queue')),
        findsOneWidget,
      );
      await tester.tap(find.text(fixture.languageProvider.tr('remove')));
      await settleIo(tester);
      expect(find.text('video'), findsNothing);
      expect(find.text('audio'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('cover.png'), findsOneWidget);
      await tester.runAsync(fixture.undoableRemovalService.undoPending);
      await settleIo(tester);
      expect(find.text('video'), findsOneWidget);
      expect(fixture.playback.sessions, hasLength(1));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'reopening details loads a fresh tree instead of restoring a cached page',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final api = _TrackApi();
      final services = createTestAsmrServices(
        persistenceRepository: fixture.persistenceRepository,
        apiService: api,
      );
      await tester.runAsync(services.preferencesStore.clearForTest);
      final controller = AsmrLibraryController(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        await controller.initializeForVisiblePage();
        await controller.ensureTrackTree(_work);
      });
      expect(api.treeRequests, 1);
      Widget page() => fixture.build(
        WorkDetailPage.forAsmr(work: _work),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      await tester.pumpWidget(page());
      expect(find.text('audio'), findsNothing);
      await settleIo(tester);
      expect(find.text('audio'), findsOneWidget);
      expect(api.treeRequests, 2);
      await tester.pump(const Duration(seconds: 60));
      expect(api.treeRequests, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      expect(find.text('audio'), findsNothing);
      await settleIo(tester);
      expect(api.treeRequests, 3);
      expect(find.text('audio'), findsOneWidget);
    },
  );

  testWidgets(
    'reopened online details respect persisted hidden tracks and retain other files',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      AsmrLibraryController controller() {
        final services = createTestAsmrServices(
          persistenceRepository: fixture.persistenceRepository,
          apiService: _TrackApi(),
        );
        final result = AsmrLibraryController(
          preferencesStore: services.preferencesStore,
          remoteCatalogService: services.remoteCatalogService,
          accountSyncService: services.accountSyncService,
        );
        addTearDown(result.dispose);
        return result;
      }

      await tester.runAsync(
        () => fixture.persistenceRepository.saveSetting(
          'asmr_hidden_tracks_v1',
          null,
        ),
      );
      final original = controller();
      await tester.runAsync(
        () => original.setTrackHidden(_work.id, _nodes.first, true),
      );
      final reopened = controller();
      expect(reopened.initialized, isFalse);
      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forAsmr(work: _work),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(reopened),
          ],
        ),
      );
      expect(find.text('audio'), findsNothing);
      // Initialization starts in the widget's fake zone. Pump between real IO
      // turns so each SQLite continuation can run before awaiting its tail.
      var loaded = false;
      final loading = reopened.initializeForVisiblePage().then((_) async {
        await reopened.ensureTrackTree(_work);
        loaded = true;
      });
      for (var i = 0; i < 100 && !loaded; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(loaded, isTrue);
      await loading;
      await settleIo(tester);
      expect(find.text('audio'), findsNothing);
      expect(find.text('video'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('cover.png'), findsOneWidget);
    },
  );
}

final _work = AsmrWork.fromJson(const {'id': 8001, 'title': 'Online actions'});
final _nodes = [
  for (final (name, type) in [
    ('audio.mp3', 'audio'),
    ('video.mp4', 'video'),
    ('notes.txt', 'text'),
    ('cover.png', 'image'),
  ])
    AsmrTrackFile.fromJson({
      'title': name,
      'type': type,
      'hash': name,
      'mediaStreamUrl': 'https://example.test/$name',
    }),
];

class _TrackApi extends AsmrApiService {
  int treeRequests = 0;
  int detailRequests = 0;
  @override
  Future<AsmrWorkDetail> fetchWorkDetail(
    int workId, {
    String? token,
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) async {
    detailRequests++;
    return AsmrWorkDetail(
      work: _work,
      description: '',
      ageCategory: '',
      languageEditionLabels: const [],
      userRating: null,
    );
  }

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
  }) async {
    treeRequests++;
    return _nodes;
  }
}
