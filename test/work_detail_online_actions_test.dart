import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_coordinator.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
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

  testWidgets(
    'online audio/video menus add only one item and remove with undo',
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
      expect(session.customQueueTracks, hasLength(1));
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
  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int workId, {
    String? token,
  }) async => _nodes;
}
