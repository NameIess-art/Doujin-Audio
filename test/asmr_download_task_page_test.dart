import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_task_card.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_details_page.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  for (final scenario in ['success', 'retry', 'covered']) {
    testWidgets(
      'empty downloads return after recovery: $scenario',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        final restored = Completer<String?>();
        var reads = 0;
        final manager = AsmrDownloadManager(
          persistenceReader: () =>
              ++reads == 1 ? restored.future : Future<String?>.value(),
          persistenceWriter: (_) async {},
        );
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreRuntimeReadyProvider.overrideWithValue(true),
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadManagerProvider.overrideWithValue(manager),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Previous page')),
            ),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const AsmrDownloadTaskPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AsmrDownloadTaskPage), findsOneWidget);
        if (scenario == 'covered') {
          unawaited(
            navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Covering page')),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }
        if (scenario == 'retry') {
          restored.completeError(StateError('restore failed'));
          await tester.pumpAndSettle();
          expect(find.byType(OperationStatusBanner), findsOneWidget);
          await tester.tap(find.byTooltip('Retry'));
        } else {
          restored.complete();
        }
        await tester.pumpAndSettle();
        if (scenario == 'covered') {
          expect(find.text('Covering page'), findsOneWidget);
          expect(
            find.byType(AsmrDownloadTaskPage, skipOffstage: false),
            findsOneWidget,
          );
          navigator.currentState!.pop();
        }
        await tester.pumpAndSettle();
        expect(reads, scenario == 'retry' ? 2 : 1);
        expect(find.byType(AsmrDownloadTaskPage), findsNothing);
        expect(find.text('Previous page'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final option in ['remove_entry', 'delete_downloaded']) {
    testWidgets(
      'removing last download commits and returns immediately: $option',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        final manager = AsmrDownloadManager(persistTasks: false)
          ..debugSetCurrentTaskForTesting(_failedTask());
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreRuntimeReadyProvider.overrideWithValue(true),
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadManagerProvider.overrideWithValue(manager),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Previous page')),
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
        final container = ProviderScope.containerOf(navigator.currentContext!);
        final subscription = container.listen(
          asmrDownloadButtonViewStateProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);
        await tester.pumpAndSettle();
        expect(subscription.read().value?.visible, isTrue);
        expect(find.byType(AsmrDownloadTaskCard), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('asmr_download_remove_task_code:RJ123456')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('asmr_download_${option}_option')),
        );
        await tester.pump();
        // Let filesystem cleanup progress alongside the simulated route frames.
        for (var frame = 0; frame < 10; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(AsmrDownloadTaskPage), findsNothing);
        expect(find.text('Previous page'), findsOneWidget);
        expect(manager.getTask('code:RJ123456'), isNull);
        expect(manager.taskIds, isEmpty);
        expect(manager.buttonViewState.visible, isFalse);
        expect(subscription.read().value?.visible, isFalse);
        expect(find.textContaining('Undo'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final option in ['remove_entry', 'delete_downloaded']) {
    testWidgets(
      'failed removal keeps the task visible without undo: $option',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        final manager = _FailingRemovalDownloadManager()
          ..debugSetCurrentTaskForTesting(_failedTask());
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreRuntimeReadyProvider.overrideWithValue(true),
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadManagerProvider.overrideWithValue(manager),
            ],
            child: const MaterialApp(home: AsmrDownloadTaskPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('asmr_download_remove_task_code:RJ123456')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('asmr_download_${option}_option')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AsmrDownloadTaskCard), findsOneWidget);
        expect(manager.getTask('code:RJ123456'), isNotNull);
        expect(manager.buttonViewState.visible, isTrue);
        expect(
          find.textContaining(language.tr('removal_failed')),
          findsOneWidget,
        );
        expect(find.textContaining('Undo'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('task recovery directly shows actual data without skeleton', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final language = AppLanguageProvider();
    await language.setLanguage(AppLanguage.en);
    final restored = Completer<String?>();
    final manager = AsmrDownloadManager(
      persistenceReader: () => restored.future,
      persistenceWriter: (_) async {},
    );
    addTearDown(language.dispose);
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreRuntimeReadyProvider.overrideWithValue(true),
          appLanguageProviderInstanceProvider.overrideWithValue(language),
          asmrDownloadManagerProvider.overrideWithValue(manager),
        ],
        child: const MaterialApp(home: AsmrDownloadTaskPage()),
      ),
    );
    await tester.pump();
    expect(find.byType(OperationSkeletonList), findsNothing);
    expect(find.text('No downloads'), findsOneWidget);
    restored.complete();
    await tester.pumpAndSettle();
    expect(find.byType(OperationSkeletonList), findsNothing);
    expect(find.text('No downloads'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'download task restoration stays scoped and can retry on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        final read = Completer<String?>();
        var reads = 0;
        final manager = AsmrDownloadManager(
          persistenceReader: () {
            reads++;
            return reads == 1 ? read.future : Future<String?>.value();
          },
          persistenceWriter: (_) async {},
        );
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        var taskReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreRuntimeReadyProvider.overrideWithValue(true),
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadManagerProvider.overrideWithValue(manager),
              asmrDownloadTaskIdsProvider.overrideWith((ref) {
                taskReads++;
                return Stream.value(const <String>[]);
              }),
            ],
            child: const MaterialApp(home: AsmrDownloadTaskPage()),
          ),
        );
        await tester.pump();
        expect(find.byType(OperationSkeletonList), findsNothing);
        expect(find.text('No downloads'), findsOneWidget);
        expect(taskReads, 1);

        read.completeError(StateError('read_failed'));
        await tester.pumpAndSettle();
        expect(find.byType(OperationStatusBanner), findsOneWidget);
        await tester.tap(find.byTooltip('Retry'));
        await tester.pumpAndSettle();
        expect(reads, 2);
        expect(taskReads, 1);
        expect(find.text('No downloads'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        final shutdown = manager.shutdown();
        await tester.pump();
        await shutdown;
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'download tasks retain cards and clear pressed feedback on return on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        final manager = AsmrDownloadManager(persistTasks: false)
          ..debugSetCurrentTaskForTesting(_failedTask());
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        final navigator = GlobalKey<NavigatorState>();
        final surface = GlobalKey();
        var taskReads = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreRuntimeReadyProvider.overrideWithValue(false),
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadManagerProvider.overrideWithValue(manager),
              asmrDownloadTaskIdsProvider.overrideWith((ref) {
                taskReads++;
                return Stream.value(['code:RJ123456']);
              }),
            ],
            child: RepaintBoundary(
              key: surface,
              child: MaterialApp(
                navigatorKey: navigator,
                theme: ThemeData(splashFactory: InkRipple.splashFactory),
                navigatorObservers: [UiInteractionNavigatorObserver()],
                home: const Scaffold(),
              ),
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
        expect(find.text('Downloads', skipOffstage: false), findsOneWidget);
        expect(taskReads, 1);
        await tester.pumpAndSettle();
        expect(find.byType(OperationSkeletonList), findsNothing);
        final taskCard = tester.widget<AsmrDownloadTaskCard>(
          find.byType(AsmrDownloadTaskCard),
        );
        expect(taskCard.onTogglePause, isNull);
        expect(taskCard.onRemove, isNull);
        expect(taskCard.onOpen, isNotNull);
        final card = tester.element(find.byType(AsmrDownloadTaskCard));
        final point =
            tester.getTopLeft(find.byType(AsmrDownloadTaskCard)) +
            const Offset(8, 60);
        Future<Color> sample() async => (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(surface),
          );
          final image = await boundary.toImage();
          final bytes = (await image.toByteData())!;
          final index = (point.dy.floor() * image.width + point.dx.floor()) * 4;
          final color = Color.fromARGB(
            bytes.getUint8(index + 3),
            bytes.getUint8(index),
            bytes.getUint8(index + 1),
            bytes.getUint8(index + 2),
          );
          image.dispose();
          return color;
        }))!;
        final before = await sample();
        final gesture = await tester.startGesture(point);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(await sample(), isNot(before));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(AsmrDownloadDetailsPage), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pump();
        expect(tester.element(find.byType(AsmrDownloadTaskCard)), same(card));
        await tester.pump(const Duration(milliseconds: 150));
        expect(await sample(), before);
        await tester.pumpAndSettle();
        if (platform == TargetPlatform.windows) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(point);
          await tester.pumpAndSettle();
          expect(await sample(), isNot(before));
          await mouse.removePointer();
          await tester.pumpAndSettle();
          expect(await sample(), before);
        }
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
    manager.debugSetCurrentTaskForTesting(_failedTask());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreRuntimeReadyProvider.overrideWithValue(true),
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadManagerProvider.overrideWithValue(manager),
        ],
        child: const MaterialApp(home: AsmrDownloadTaskPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey<String>('asmr_download_remove_task_code:RJ123456'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove entry'), findsOneWidget);
    expect(find.text('Also delete downloaded content'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('asmr_download_remove_entry_option')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(manager.getTask('code:RJ123456'), isNull);
    expect(find.text('Work'), findsNothing);
    expect(find.textContaining('Undo'), findsNothing);
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
    manager.debugSetCurrentTaskForTesting(
      _failedTask(
        status: AsmrDownloadTaskStatus.downloading,
        fileRetryAttempts: const <String, int>{'Track.mp3': 1},
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreRuntimeReadyProvider.overrideWithValue(true),
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadManagerProvider.overrideWithValue(manager),
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

  testWidgets(
    'failed tasks expose retry through the existing resume command',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      final manager = _RecordingResumeDownloadManager()
        ..debugSetCurrentTaskForTesting(_failedTask());
      addTearDown(language.dispose);
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreRuntimeReadyProvider.overrideWithValue(true),
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            asmrDownloadManagerProvider.overrideWithValue(manager),
          ],
          child: const MaterialApp(home: AsmrDownloadTaskPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(language.tr('retry')));
      expect(manager.resumedWorkIds, ['code:RJ123456']);
      expect(manager.pauseCalls, 0);

      manager.debugSetCurrentTaskForTesting(
        _failedTask(status: AsmrDownloadTaskStatus.completed),
      );
      await tester.pump();
      expect(find.byTooltip(language.tr('retry')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

class _FailingRemovalDownloadManager extends AsmrDownloadManager {
  _FailingRemovalDownloadManager() : super(persistTasks: false);

  @override
  Future<void> cancelTask(String workId, {bool deleteDownloaded = true}) async {
    throw StateError('removal failed');
  }

  @override
  Future<void> deleteTask(String workId) async {
    throw StateError('removal failed');
  }
}

class _RecordingResumeDownloadManager extends AsmrDownloadManager {
  _RecordingResumeDownloadManager() : super(persistTasks: false);

  final resumedWorkIds = <String>[];
  var pauseCalls = 0;

  @override
  Future<void> resumeTask(String workId) async => resumedWorkIds.add(workId);

  @override
  Future<void> pauseTask(String workId) async {
    pauseCalls++;
  }
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
