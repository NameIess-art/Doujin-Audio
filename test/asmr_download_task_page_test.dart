import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_task_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'download tasks defer subscriptions during entrance and retain cards on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        final manager = AsmrDownloadManager(persistTasks: false)
          ..debugSetCurrentTaskForTesting(_failedTask());
        final removals = UndoableRemovalService();
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        addTearDown(removals.dispose);
        final navigator = GlobalKey<NavigatorState>();
        var taskReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadManagerProvider.overrideWithValue(manager),
              undoableRemovalServiceProvider.overrideWithValue(removals),
              asmrDownloadTaskIdsProvider.overrideWith((ref) {
                taskReads++;
                return Stream.value([1]);
              }),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              navigatorObservers: [UiInteractionNavigatorObserver()],
              home: const Scaffold(),
            ),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            buildAppPageRoute<void>(
              context: navigator.currentContext!,
              child: const AsmrDownloadTaskPage(),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.text('Download tasks', skipOffstage: false),
          findsOneWidget,
        );
        expect(taskReads, 0);
        await tester.pump(const Duration(milliseconds: 100));
        expect(taskReads, 0);
        await tester.pumpAndSettle();
        expect(taskReads, 1);
        final card = tester.element(find.byType(AsmrDownloadTaskCard));
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        expect(tester.element(find.byType(AsmrDownloadTaskCard)), same(card));
        await tester.pumpAndSettle();
        expect(taskReads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.resetForTest();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('remove task button shows both removal choices', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    final manager = AsmrDownloadManager(
      temporaryDirectoryProvider: () async => Directory.systemTemp,
      automaticFileRetryDelay: Duration.zero,
      persistTasks: false,
    );
    addTearDown(manager.dispose);
    final removalService = UndoableRemovalService();
    addTearDown(removalService.dispose);
    manager.debugSetCurrentTaskForTesting(_failedTask());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadManagerProvider.overrideWithValue(manager),
          undoableRemovalServiceProvider.overrideWithValue(removalService),
        ],
        child: const MaterialApp(home: AsmrDownloadTaskPage()),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('asmr_download_remove_task_1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove task entry'), findsOneWidget);
    expect(find.text('Also delete downloaded content'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('asmr_download_remove_entry_option')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(manager.getTask(1), isNotNull);
    expect(find.text('Work'), findsNothing);
    expect(find.textContaining('Undo'), findsOneWidget);

    await tester.tap(find.textContaining('Undo'));
    await tester.pumpAndSettle();

    expect(manager.getTask(1), isNotNull);
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('task uses its retry maximum and clears terminal retry status', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    final manager = AsmrDownloadManager(
      temporaryDirectoryProvider: () async => Directory.systemTemp,
      automaticFileRetryDelay: Duration.zero,
      persistTasks: false,
    );
    addTearDown(manager.dispose);
    final removalService = UndoableRemovalService();
    addTearDown(removalService.dispose);
    manager.debugSetCurrentTaskForTesting(
      _failedTask(
        status: AsmrDownloadTaskStatus.downloading,
        fileRetryAttempts: const <String, int>{'Track.mp3': 1},
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadManagerProvider.overrideWithValue(manager),
          undoableRemovalServiceProvider.overrideWithValue(removalService),
        ],
        child: const MaterialApp(home: AsmrDownloadTaskPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retrying (1/7)'), findsOneWidget);

    manager.debugSetCurrentTaskForTesting(
      _failedTask(fileRetryAttempts: const <String, int>{'Track.mp3': 1}),
    );
    await tester.pump();

    expect(find.text('Retrying (1/7)'), findsNothing);
    expect(find.text('Failed'), findsOneWidget);
  });
}

AsmrDownloadTaskSnapshot _failedTask({
  AsmrDownloadTaskStatus status = AsmrDownloadTaskStatus.failed,
  Map<String, int> fileRetryAttempts = const <String, int>{},
}) {
  return AsmrDownloadTaskSnapshot(
    work: AsmrWork(
      id: 1,
      title: 'Work',
      circleName: 'Circle',
      sourceId: 'RJ123456',
      sourceType: 'asmr',
      sourceUrl: '',
      coverUrl: '',
      thumbnailUrl: '',
      mainCoverUrl: '',
      releaseDate: null,
      createDate: null,
      duration: Duration.zero,
      dlCount: 0,
      reviewCount: 0,
      rating: 0,
      voiceActors: const <String>[],
      tags: const <String>[],
    ),
    destinationRoot: r'C:\Downloads',
    workFolderName: 'Work',
    conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
    automaticFileRetryCount: 7,
    status: status,
    totalFiles: 1,
    completedFiles: 0,
    skippedFiles: 0,
    failedFiles: 1,
    totalBytes: 1024,
    downloadedBytes: 0,
    startedAt: DateTime(2026),
    fileRetryAttempts: fileRetryAttempts,
  );
}
