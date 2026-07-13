import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/app/state/audio_provider_riverpod.dart';
import 'package:nameless_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:nameless_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_command_runner.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:nameless_audio/core/widgets/operation_feedback.dart';
import 'package:provider/provider.dart' as legacy_provider;

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
      const DlsiteMetadata(
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
  return ProviderScope(
    overrides: createAudioProviderOverrides(
      audioProvider: services.audioProvider,
      audioDatabaseRepository: services.audioDatabaseRepository,
      nativePlaybackRepository: services.nativePlaybackRepository,
      playbackCommandRunner: services.playbackCommandRunner,
      libraryService: services.libraryService,
      playbackService: services.playbackService,
      timerService: services.timerService,
      notificationCoordinatorService: services.notificationCoordinatorService,
      settingsRepository: services.settingsRepository,
    ),
    child: legacy_provider.MultiProvider(
      providers: [
        legacy_provider.ChangeNotifierProvider.value(value: languageProvider),
        legacy_provider.ChangeNotifierProvider.value(
          value: services.audioProvider,
        ),
        legacy_provider.ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(),
        ),
      ],
      child: MaterialApp(home: child),
    ),
  );
}

class _TestServices {
  _TestServices({
    DlsiteMetadataService? dlsiteMetadataService,
    AsmrMetadataService? asmrMetadataService,
  }) {
    audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
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
  final audioDatabaseRepository = AudioDatabaseRepository();
  final nativePlaybackRepository = NativePlaybackRepository();
  final playbackCommandRunner = const PlaybackCommandRunner();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  late final AudioProvider audioProvider;

  void dispose() {
    audioProvider.dispose();
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
