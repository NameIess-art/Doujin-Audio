import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_command_runner.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets('metadata review skeleton fills tall screens without scrolling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final metadataCompleter = Completer<DlsiteMetadata>();
    final services = _TestServices(
      dlsiteMetadataService: _DelayedDlsiteMetadataService(metadataCompleter),
      asmrMetadataService: _DelayedAsmrMetadataService(metadataCompleter),
    );
    addTearDown(services.dispose);

    await tester.pumpWidget(
      _buildTestApp(
        services: services,
        languageProvider: AppLanguageProvider(),
        child: DlsiteMetadataReviewPage(
          detail: AudioDetail.empty(
            const AudioDetailTarget(
              targetType: AudioDetailTargetType.singleAudioFile,
              targetPath: '/library/Work/audio.mp3',
            ),
          ),
          rjCode: 'RJ123456',
        ),
      ),
    );
    await tester.pump();

    final firstField = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_field_0'),
    );
    expect(firstField, findsOneWidget);
    expect(find.byType(Scrollable), findsNothing);
    final lastField = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'dlsite_review_skeleton_field_',
          ),
    ).last;
    expect(tester.getRect(lastField).bottom, greaterThanOrEqualTo(1200));

    final firstFieldTop = tester.getRect(firstField).top;
    await tester.drag(firstField, const Offset(0, -300));
    await tester.pump();
    expect(tester.getRect(firstField).top, firstFieldTop);
  });

  testWidgets('metadata review page shows shell while metadata loads', (
    tester,
  ) async {
    final metadataCompleter = Completer<DlsiteMetadata>();
    final services = _TestServices(
      dlsiteMetadataService: _DelayedDlsiteMetadataService(metadataCompleter),
      asmrMetadataService: _DelayedAsmrMetadataService(metadataCompleter),
    );
    addTearDown(services.dispose);

    final languageProvider = AppLanguageProvider();
    await tester.pumpWidget(
      _buildTestApp(
        services: services,
        languageProvider: languageProvider,
        child: DlsiteMetadataReviewPage(
          detail: AudioDetail.empty(
            const AudioDetailTarget(
              targetType: AudioDetailTargetType.libraryRootFolder,
              targetPath: '/library/Work',
            ),
          ),
          rjCode: 'RJ123456',
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text(languageProvider.tr('dlsite_review_title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dlsite_review_skeleton_field_0')),
      findsOneWidget,
    );
    expect(find.byType(Scrollable), findsNothing);

    final skeletonCover = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_cover'),
    );
    final skeletonSaveCover = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_save_cover'),
    );
    final skeletonSaveCoverLabel = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_save_cover_label'),
    );
    expect(tester.getSize(skeletonSaveCover), const Size(52, 32));
    final skeletonOffset =
        tester.getCenter(skeletonSaveCover).dy -
        tester.getRect(skeletonCover).bottom;
    final skeletonCenterX = tester.getCenter(skeletonSaveCover).dx;
    final skeletonLabelOffset =
        tester.getCenter(skeletonSaveCoverLabel).dy -
        tester.getRect(skeletonCover).bottom;
    final skeletonLabelLeft = tester.getRect(skeletonSaveCoverLabel).left;

    metadataCompleter.complete(
      DlsiteMetadata(
        rjCode: 'RJ123456',
        workTitle: 'Loaded title',
        circleName: 'Circle',
        voiceActors: <String>['Voice'],
        tags: <String>['ASMR'],
        coverUrl: 'https://example.com/cover.jpg',
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byType(SwitchListTile), 300);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(tester.getSize(find.byType(SwitchListTile)).height, 56);
    final actualSaveCover = find.descendant(
      of: find.byType(SwitchListTile),
      matching: find.byType(Switch),
    );
    expect(actualSaveCover, findsOneWidget);
    expect(
      skeletonOffset,
      closeTo(
        tester.getCenter(actualSaveCover).dy -
            tester.getRect(find.byType(SwitchListTile)).top,
        1,
      ),
    );
    expect(skeletonCenterX, closeTo(tester.getCenter(actualSaveCover).dx, 1));
    final actualLabel = find.text(languageProvider.tr('dlsite_save_cover'));
    expect(
      skeletonLabelOffset,
      closeTo(
        tester.getCenter(actualLabel).dy -
            tester.getRect(find.byType(SwitchListTile)).top,
        1,
      ),
    );
    expect(skeletonLabelLeft, closeTo(tester.getRect(actualLabel).left, 1));

    expect(
      find.byKey(const ValueKey<String>('dlsite_review_skeleton_field_0')),
      findsNothing,
    );
    expect(
      find.text(languageProvider.tr('audio_detail_work_title')),
      findsOneWidget,
    );
  });
}

Widget _buildTestApp({
  required _TestServices services,
  required AppLanguageProvider languageProvider,
  required Widget child,
}) {
  final themeProvider = ThemeProvider();
  return ProviderScope(
    overrides: [
      ...createAppRuntimeOverrides(
        persistence: services.runtimeGraph.persistence,
        runtime: services.runtimeGraph.runtime,
        warmup: services.runtimeGraph.warmup,
        playbackCommands: services.runtimeGraph.playbackCommands,
        keepAlive: services.runtimeGraph.keepAlive,
        library: services.runtimeGraph.library,
        playback: services.runtimeGraph.playback,
        subtitles: services.runtimeGraph.subtitles,
        timer: services.runtimeGraph.timer,
        notifications: services.runtimeGraph.notifications,
        settings: services.runtimeGraph.settings,
      ),
      themeProviderInstanceProvider.overrideWith((ref) => themeProvider),
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
    ],
    child: MaterialApp(home: child),
  );
}

class _TestServices {
  _TestServices({
    DlsiteMetadataService? dlsiteMetadataService,
    AsmrMetadataService? asmrMetadataService,
  }) {
    runtimeGraph = createTestRuntimeGraph(
      notificationService: notificationService,
      persistenceRepository: persistenceRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
      dlsiteMetadataService: dlsiteMetadataService,
      asmrMetadataService: asmrMetadataService,
    );
  }

  final notificationService = PlaybackNotificationService();
  final persistenceRepository = TestPersistenceRepository();
  final nativePlaybackRepository = NativePlaybackRepository();
  final playbackCommandRunner = const PlaybackCommandRunner();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  late final AppRuntimeGraph runtimeGraph;

  void dispose() {
    unawaited(runtimeGraph.runtime.dispose());
  }
}

class _DelayedDlsiteMetadataService extends DlsiteMetadataService {
  _DelayedDlsiteMetadataService(this.completer);

  final Completer<DlsiteMetadata> completer;

  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.ja,
  }) {
    return completer.future;
  }
}

class _DelayedAsmrMetadataService extends AsmrMetadataService {
  _DelayedAsmrMetadataService(this.completer);

  final Completer<DlsiteMetadata> completer;

  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) {
    return completer.future;
  }
}
