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
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'support/app_runtime_test_fixture.dart';

void main() {
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
    expect(find.byType(OperationSkeletonList), findsOneWidget);

    metadataCompleter.complete(
      DlsiteMetadata(
        rjCode: 'RJ123456',
        workTitle: 'Loaded title',
        circleName: 'Circle',
        voiceActors: <String>['Voice'],
        tags: <String>['ASMR'],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OperationSkeletonList), findsNothing);
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
