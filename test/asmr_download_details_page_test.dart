import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_details_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_summary_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  testWidgets(
    'download details shows the actual M4A output while retaining folder labels',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.en);
      await tester.pumpWidget(
        _downloadDetailsApp(
          language,
          _downloadTree(1).copyWith(
            actualOutputPaths: const {
              'Folder/File000.mp3': 'Folder/File000.m4a',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Folder'), findsOneWidget);
      expect(find.text('File000.m4a'), findsOneWidget);
      expect(find.text('File000.mp3'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'HLS details update unknown-size bytes and chapter progress on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        final manager = _RecordingDownloadManager();
        addTearDown(language.dispose);
        addTearDown(manager.dispose);
        await language.setLanguage(AppLanguage.en);
        final initial = _downloadTask().copyWith(
          totalBytes: 0,
          downloadedBytes: 0,
          fileTotalBytes: const {'Track.mp3': 0},
          fileDownloadedBytes: const {'Track.mp3': 0},
          fileProgressFractions: const {'Track.mp3': 0},
        );
        manager.debugSetCurrentTaskForTesting(initial);
        await tester.pumpWidget(_downloadStreamApp(language, manager));
        await tester.pumpAndSettle();
        manager.debugSetCurrentTaskForTesting(
          initial.copyWith(
            downloadedBytes: 2048,
            fileDownloadedBytes: const {'Track.mp3': 2048},
            fileProgressFractions: const {'Track.mp3': 0.4},
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          0.4,
        );
        expect(find.textContaining('2.0 KB /'), findsNWidgets(2));
        expect(
          find.textContaining(language.tr('asmr_download_size_unknown')),
          findsNWidgets(2),
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('Japanese ASMR download summary explains M4A fallback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final language = AppLanguageProvider();
    addTearDown(language.dispose);
    await language.setLanguage(AppLanguage.en);
    final ordinaryWork = _downloadTask().work;
    for (final japanese in [false, true]) {
      final work = japanese
          ? ordinaryWork.mergeResources(const [
              AsmrWorkResource(
                source: AsmrCatalogSource.japaneseAsmr,
                id: 42,
                code: 'RJ123456',
                pageUrl: 'https://japaneseasmr.com/42',
              ),
            ])
          : ordinaryWork;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AsmrDownloadSummaryCard(
                work: work,
                selectedLeafCount: 1,
                selectedTotalSizeBytes: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('asmr_download_hls_notice')),
        japanese ? findsOneWidget : findsNothing,
      );
      if (japanese) expect(find.textContaining('M4A'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'download details delay tree rows during entrance and retain collapse on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final language = AppLanguageProvider();
        await language.setLanguage(AppLanguage.en);
        addTearDown(language.dispose);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              coreRuntimeReadyProvider.overrideWithValue(true),
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              asmrDownloadTaskProvider(
                'code:RJ123456',
              ).overrideWithValue(_downloadTree(500)),
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
              child: const AsmrDownloadDetailsPage(workId: 'code:RJ123456'),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.text('Download details', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.byType(CustomScrollView), findsNothing);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(CustomScrollView), findsNothing);
        expect(
          find.byType(FileTreeSkeleton, skipOffstage: false),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
        final list = tester.element(find.byType(CustomScrollView));
        expect(find.byType(FileTreeSkeleton), findsNothing);
        expect(find.text('File000.mp3'), findsOneWidget);
        expect(find.text('File499.mp3'), findsNothing);
        await tester.tap(find.text('Folder'));
        await tester.pumpAndSettle();
        expect(find.text('File000.mp3'), findsNothing);
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        expect(tester.element(find.byType(CustomScrollView)), same(list));
        expect(find.text('File000.mp3'), findsNothing);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.resetForTest();
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('download details follows the selected language', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coreRuntimeReadyProvider.overrideWithValue(true),
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadTaskProvider(
            'source:asmrOne:404',
          ).overrideWithValue(null),
        ],
        child: const MaterialApp(
          home: AsmrDownloadDetailsPage(workId: 'source:asmrOne:404'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Download details'), findsOneWidget);
    expect(find.text('Download not found'), findsOneWidget);

    await languageProvider.setLanguage(AppLanguage.ja);
    await tester.pump();

    expect(find.text('ダウンロード詳細'), findsOneWidget);
    expect(find.text('ダウンロードが見つかりません'), findsOneWidget);
    expect(find.text('Download not found'), findsNothing);
  });

  testWidgets('folder tile uses the shared file tree style', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    final folder = AsmrTrackFile(
      hash: 'folder_1',
      title: 'Folder',
      type: 'folder',
      streamUrl: null,
      downloadUrl: null,
      lowQualityUrl: null,
      duration: Duration.zero,
      size: 0,
      children: const <AsmrTrackFile>[],
      workId: 1,
      workTitle: 'Work',
      sourceId: 'RJ123456',
      relativePath: 'Folder',
    );
    final task = _downloadTask().copyWith(
      selectedRoots: <AsmrTrackFile>[folder],
    );
    await tester.pumpWidget(_downloadDetailsApp(languageProvider, task));
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(FileTreeRow),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.borderRadius, FileTreeRow.borderRadius);
    expect(material.clipBehavior, Clip.antiAlias);
    final emptyFolder = find.text(
      languageProvider.tr('asmr_download_empty_folder'),
    );
    expect(emptyFolder, findsOneWidget);
    await tester.tap(find.text('Folder'));
    await tester.pumpAndSettle();
    expect(emptyFolder, findsNothing);
    await tester.tap(find.text('Folder'));
    await tester.pumpAndSettle();
    expect(emptyFolder, findsOneWidget);
  });

  testWidgets(
    'download details keeps shared file icons and colors while folders toggle',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final languageProvider = AppLanguageProvider();
      addTearDown(languageProvider.dispose);
      final task = _downloadTask().copyWith(
        selectedRoots: [
          _downloadNode(
            'Folder',
            children: [
              _downloadNode('Folder/Track.mp3'),
              _downloadNode('Folder/Notes.txt'),
              _downloadNode('Folder/Cover.jpg'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(_downloadDetailsApp(languageProvider, task));
      await tester.pumpAndSettle();

      void expectEntryIcon(IconData data, Color color) {
        final icon = tester.widget<Icon>(find.byIcon(data));
        expect(icon.size, AppDesignTokens.fileEntryIconSize);
        expect(icon.color, color);
      }

      expectEntryIcon(
        AppDesignTokens.openFolderIcon,
        AppDesignTokens.folderIconColor,
      );
      expectEntryIcon(
        AppDesignTokens.audioFileIcon,
        AppDesignTokens.light.asmrAccent,
      );
      expectEntryIcon(
        AppDesignTokens.textFileIcon,
        AppDesignTokens.textFileIconColor,
      );
      expectEntryIcon(
        AppDesignTokens.imageFileIcon,
        AppDesignTokens.imageFileIconColor,
      );
      await tester.tap(find.text('Folder'));
      await tester.pumpAndSettle();
      expectEntryIcon(
        AppDesignTokens.folderIcon,
        AppDesignTokens.folderIconColor,
      );
      expect(find.text('Track.mp3'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('completed file restores its size after a retry', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    final retryingTask = _downloadTask(
      fileRetryAttempts: const <String, int>{'Track.mp3': 1},
    );

    await tester.pumpWidget(
      _downloadDetailsApp(languageProvider, retryingTask),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('asmr_download_retry_Track.mp3')),
      findsOneWidget,
    );
    expect(find.text('Retrying (1/7)'), findsOneWidget);

    await tester.pumpWidget(
      _downloadDetailsApp(
        languageProvider,
        retryingTask.copyWith(completedFilePaths: const <String>{'Track.mp3'}),
      ),
    );
    await tester.pump();

    expect(find.text('Retrying (1/7)'), findsNothing);
    expect(find.text('128 B / 1.0 KB'), findsNWidgets(2));
  });

  testWidgets(
    'only the retrying file shows retries and restores bytes when downloading resumes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final language = AppLanguageProvider();
      final manager = _RecordingDownloadManager();
      addTearDown(language.dispose);
      addTearDown(manager.dispose);
      await language.setLanguage(AppLanguage.en);
      final retrying = _downloadTree(
        2,
      ).copyWith(fileRetryAttempts: const {'Folder/File000.mp3': 2});
      manager.debugSetCurrentTaskForTesting(retrying);
      await tester.pumpWidget(_downloadStreamApp(language, manager));
      await tester.pumpAndSettle();

      Finder fileText(String path, String text) => find.descendant(
        of: find.byKey(ValueKey<String>('asmr_download_node_row_$path')),
        matching: find.text(text),
      );
      expect(fileText('Folder/File000.mp3', 'Retrying (2/7)'), findsOneWidget);
      expect(fileText('Folder/File001.mp3', '256 B / 1.0 KB'), findsOneWidget);
      expect(find.textContaining('Retrying'), findsOneWidget);

      final resumed = retrying.copyWith(
        fileRetryAttempts: const {},
        downloadedBytes: 768,
        fileDownloadedBytes: const {
          'Folder/File000.mp3': 512,
          'Folder/File001.mp3': 256,
        },
      );
      manager.debugSetCurrentTaskForTesting(resumed);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Retrying'), findsNothing);
      expect(fileText('Folder/File000.mp3', '512 B / 1.0 KB'), findsOneWidget);

      manager.debugSetCurrentTaskForTesting(
        resumed.copyWith(
          completedFiles: 1,
          completedFilePaths: const {'Folder/File000.mp3'},
          downloadedBytes: 1280,
          fileDownloadedBytes: const {
            'Folder/File000.mp3': 1024,
            'Folder/File001.mp3': 256,
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Retrying'), findsNothing);
      expect(fileText('Folder/File000.mp3', '1.0 KB / 1.0 KB'), findsOneWidget);
      expect(fileText('Folder/File001.mp3', '256 B / 1.0 KB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'paused failed and completed tasks show bytes instead of stale retry status',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.en);
      final task = _downloadTask(fileRetryAttempts: const {'Track.mp3': 1});
      for (final status in [
        AsmrDownloadTaskStatus.paused,
        AsmrDownloadTaskStatus.failed,
        AsmrDownloadTaskStatus.completed,
      ]) {
        await tester.pumpWidget(
          _downloadDetailsApp(language, task.copyWith(status: status)),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Retrying'), findsNothing);
        expect(find.text('128 B / 1.0 KB'), findsNWidgets(2));
      }
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'file rows keep one title line and one progress line at scale $textScale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final language = AppLanguageProvider();
        addTearDown(language.dispose);
        final name = '${'A long file name with many words ' * 8}.mp3';
        final task = _downloadTask().copyWith(
          selectedRoots: [_downloadNode(name)],
        );
        await tester.pumpWidget(
          _downloadDetailsApp(language, task, textScale: textScale),
        );
        await tester.pumpAndSettle();

        final row = find.byType(FileTreeRow);
        final title = find.text(name);
        final progress = find.byType(LinearProgressIndicator);
        final text = tester.widget<Text>(title);
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        final titleRect = tester.getRect(title);
        final progressRect = tester.getRect(progress);
        final rowRect = tester.getRect(row);
        expect(progressRect.top, greaterThanOrEqualTo(titleRect.bottom));
        expect(progressRect.left, titleRect.left);
        expect(titleRect.right, lessThanOrEqualTo(rowRect.right));
        expect(tester.widget<FileTreeRow>(row).trailing, isNull);
        expect(
          rowRect.height,
          FileTreeRow.layoutHeight(
            tester.element(row),
            minHeight: 52,
            reserveSubtitleSpace: true,
          ),
        );
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'file rows omit trailing status icons in every task state',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      final base = _downloadTask();
      final row = find.byType(FileTreeRow);
      for (final status in AsmrDownloadTaskStatus.values) {
        await tester.pumpWidget(
          _downloadDetailsApp(language, base.copyWith(status: status)),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<FileTreeRow>(row).trailing, isNull);
        expect(
          find.descendant(
            of: row,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        expect(
          find.descendant(of: row, matching: find.byType(IconButton)),
          findsNothing,
        );
      }

      await tester.pumpWidget(
        _downloadDetailsApp(
          language,
          base.copyWith(completedFilePaths: const {'Track.mp3'}),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FileTreeRow>(row).trailing, isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('download work title supports up to three lines', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    const title = 'A long work title that may span several lines';
    final task = _downloadTask(title: title);

    await tester.pumpWidget(_downloadDetailsApp(languageProvider, task));
    await tester.pump();

    final titleText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('asmr_download_work_title')),
        matching: find.text(title),
      ),
    );
    expect(titleText.maxLines, 3);
    expect(titleText.overflow, TextOverflow.ellipsis);
    expect(
      tester.getRect(find.text('Track.mp3')).top -
          tester
              .getRect(
                find.byKey(const ValueKey<String>('asmr_download_work_title')),
              )
              .bottom,
      greaterThanOrEqualTo(8),
    );
  });

  testWidgets('failed file disables its retry button while retrying', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    final manager = _RecordingDownloadManager();
    addTearDown(languageProvider.dispose);
    addTearDown(manager.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    final failedTask = _downloadTask(
      status: AsmrDownloadTaskStatus.failed,
      failedFilePaths: const <String>{'Track.mp3'},
      failedFiles: 1,
    );

    await tester.pumpWidget(
      _downloadDetailsApp(
        languageProvider,
        failedTask,
        manager: manager,
        coreReady: false,
      ),
    );
    await tester.pump();

    final retryButton = find.byKey(
      const ValueKey<String>('asmr_download_manual_retry_Track.mp3'),
    );
    expect(tester.widget<IconButton>(retryButton).onPressed, isNull);
    expect(manager.retriedPaths, isEmpty);
    await tester.pumpWidget(
      _downloadDetailsApp(languageProvider, failedTask, manager: manager),
    );
    await tester.pumpAndSettle();
    expect(retryButton, findsOneWidget);
    expect(tester.widget<IconButton>(retryButton).onPressed, isNotNull);
    expect(tester.getSize(retryButton), const Size.square(44));
    expect(find.byTooltip('Retry'), findsOneWidget);
    await tester.tap(retryButton);
    expect(manager.retriedPaths, <String>['Track.mp3']);

    await tester.pumpWidget(
      _downloadDetailsApp(
        languageProvider,
        failedTask.copyWith(
          status: AsmrDownloadTaskStatus.downloading,
          manuallyRetryingFilePaths: const <String>{'Track.mp3'},
        ),
        manager: manager,
      ),
    );
    await tester.pump();

    expect(retryButton, findsOneWidget);
    expect(tester.widget<IconButton>(retryButton).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(
      _downloadDetailsApp(
        languageProvider,
        failedTask.copyWith(
          status: AsmrDownloadTaskStatus.completed,
          failedFiles: 0,
          failedFilePaths: const <String>{},
          manuallyRetryingFilePaths: const <String>{},
          completedFilePaths: const <String>{'Track.mp3'},
        ),
        manager: manager,
      ),
    );
    await tester.pump();

    expect(retryButton, findsNothing);

    await tester.pumpWidget(
      _downloadDetailsApp(languageProvider, failedTask, manager: manager),
    );
    await tester.pump();

    expect(retryButton, findsOneWidget);
  });

  testWidgets('paused failed file keeps its manual retry action disabled', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    final manager = _RecordingDownloadManager();
    addTearDown(languageProvider.dispose);
    addTearDown(manager.dispose);
    final pausedTask = _downloadTask(
      status: AsmrDownloadTaskStatus.paused,
      failedFilePaths: const <String>{'Track.mp3'},
      failedFiles: 1,
    );

    await tester.pumpWidget(
      _downloadDetailsApp(languageProvider, pausedTask, manager: manager),
    );
    await tester.pump();

    final retryButton = find.byKey(
      const ValueKey<String>('asmr_download_manual_retry_Track.mp3'),
    );
    expect(retryButton, findsOneWidget);
    expect(tester.widget<IconButton>(retryButton).onPressed, isNull);
  });
  testWidgets('large expanded download trees mount only viewport rows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    await tester.pumpWidget(
      _downloadDetailsApp(languageProvider, _downloadTree(500)),
    );
    await tester.pumpAndSettle();

    expect(find.text('File000.mp3'), findsOneWidget);
    expect(find.text('File499.mp3', skipOffstage: false), findsNothing);
    expect(
      find.byType(LinearProgressIndicator).evaluate().length,
      lessThan(30),
    );

    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('File499.mp3'),
      500,
      scrollable: scrollable,
      maxScrolls: 100,
    );
    expect(find.text('File499.mp3'), findsOneWidget);
    expect(find.text('File000.mp3', skipOffstage: false), findsNothing);
    expect(
      find.byType(LinearProgressIndicator).evaluate().length,
      lessThan(30),
    );
  });

  testWidgets('task stream rebuilds only changed file progress and totals', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    final manager = _RecordingDownloadManager();
    addTearDown(languageProvider.dispose);
    addTearDown(manager.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    manager.debugSetCurrentTaskForTesting(_downloadTree(3));
    await tester.pumpWidget(_downloadStreamApp(languageProvider, manager));
    await tester.pumpAndSettle();

    Finder progressFor(String path) => find.descendant(
      of: find.byKey(ValueKey<String>('asmr_download_node_row_$path')),
      matching: find.byType(LinearProgressIndicator),
    );
    final changedBefore = tester.widget<LinearProgressIndicator>(
      progressFor('Folder/File000.mp3'),
    );
    final unchangedBefore = tester.widget<LinearProgressIndicator>(
      progressFor('Folder/File001.mp3'),
    );
    final titleBefore = tester.widget<Text>(find.text('Work'));
    final folderBefore = tester.widget<FileTreeExpansionArrow>(
      find.byType(FileTreeExpansionArrow),
    );
    final totalsFinder = find.byKey(
      const ValueKey<String>('asmr_download_total_bytes'),
    );
    final totalsBefore = tester.widget<Text>(totalsFinder);

    manager.debugRecordDownloadChunkForTesting(
      'code:RJ123456',
      'Folder/File000.mp3',
      128,
      256,
    );
    manager.debugFlushProgressNotificationsForTesting();
    await tester.pump();
    await tester.pump();

    final changed = tester.widget<LinearProgressIndicator>(
      progressFor('Folder/File000.mp3'),
    );
    expect(changed.value, 0.25);
    expect(changed, isNot(same(changedBefore)));
    expect(
      tester.widget<LinearProgressIndicator>(progressFor('Folder/File001.mp3')),
      same(unchangedBefore),
    );
    expect(tester.widget<Text>(find.text('Work')), same(titleBefore));
    expect(
      tester.widget<FileTreeExpansionArrow>(
        find.byType(FileTreeExpansionArrow),
      ),
      same(folderBefore),
    );
    expect(tester.widget<Text>(totalsFinder).data, isNot(totalsBefore.data));

    manager.debugRemoveTaskForTesting('code:RJ123456');
    await tester.pump();
    await tester.pump();
    expect(find.text('Download not found'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('collapsed directories retain state while rows are recycled', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    final manager = _RecordingDownloadManager();
    addTearDown(languageProvider.dispose);
    addTearDown(manager.dispose);
    await languageProvider.setLanguage(AppLanguage.en);
    final task = _downloadTask().copyWith(
      selectedRoots: [
        _downloadNode(
          'Root',
          children: [
            _downloadNode(
              'Root/Nested',
              children: [_downloadNode('Root/Nested/Inside.mp3')],
            ),
            _downloadNode('Root/Other.mp3'),
          ],
        ),
      ],
    );
    manager.debugSetCurrentTaskForTesting(task);
    await tester.pumpWidget(_downloadStreamApp(languageProvider, manager));
    await tester.pumpAndSettle();
    expect(find.text('Inside.mp3'), findsOneWidget);

    await tester.tap(find.text('Nested'));
    await tester.pumpAndSettle();
    expect(find.text('Inside.mp3', skipOffstage: false), findsNothing);
    expect(find.text('Other.mp3'), findsOneWidget);
    await tester.tap(find.text('Root'));
    await tester.pumpAndSettle();
    expect(find.text('Nested', skipOffstage: false), findsNothing);
    await tester.tap(find.text('Root'));
    await tester.pumpAndSettle();
    expect(find.text('Nested'), findsOneWidget);
    expect(find.text('Inside.mp3', skipOffstage: false), findsNothing);
    await tester.tap(find.text('Nested'));
    await tester.pumpAndSettle();
    expect(find.text('Inside.mp3'), findsOneWidget);
  });
}

Widget _downloadDetailsApp(
  AppLanguageProvider languageProvider,
  AsmrDownloadTaskSnapshot task, {
  AsmrDownloadManager? manager,
  bool coreReady = true,
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [
      coreRuntimeReadyProvider.overrideWithValue(coreReady),
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
      asmrDownloadTaskProvider('code:RJ123456').overrideWithValue(task),
      if (manager != null)
        asmrDownloadManagerProvider.overrideWithValue(manager),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const AsmrDownloadDetailsPage(workId: 'code:RJ123456'),
    ),
  );
}

Widget _downloadStreamApp(
  AppLanguageProvider languageProvider,
  AsmrDownloadManager manager,
) => ProviderScope(
  overrides: [
    coreRuntimeReadyProvider.overrideWithValue(true),
    appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
    asmrDownloadManagerProvider.overrideWithValue(manager),
  ],
  child: const MaterialApp(
    home: AsmrDownloadDetailsPage(workId: 'code:RJ123456'),
  ),
);

AsmrTrackFile _downloadNode(
  String relativePath, {
  List<AsmrTrackFile>? children,
}) => AsmrTrackFile(
  hash: relativePath,
  title: relativePath.split('/').last,
  type: children == null ? 'audio' : 'folder',
  streamUrl: null,
  downloadUrl: null,
  lowQualityUrl: null,
  duration: Duration.zero,
  size: children == null ? 1024 : 0,
  children: children ?? const [],
  workId: 1,
  workTitle: 'Work',
  sourceId: 'RJ123456',
  relativePath: relativePath,
);

AsmrDownloadTaskSnapshot _downloadTree(int count) => _downloadTask().copyWith(
  totalFiles: count,
  totalBytes: count * 1024,
  downloadedBytes: 384,
  fileDownloadedBytes: const {
    'Folder/File000.mp3': 128,
    'Folder/File001.mp3': 256,
  },
  selectedRoots: [
    _downloadNode(
      'Folder',
      children: [
        for (var index = 0; index < count; index++)
          _downloadNode('Folder/File${index.toString().padLeft(3, '0')}.mp3'),
      ],
    ),
  ],
);

AsmrDownloadTaskSnapshot _downloadTask({
  String title = 'Work',
  Map<String, int> fileRetryAttempts = const <String, int>{},
  AsmrDownloadTaskStatus status = AsmrDownloadTaskStatus.downloading,
  Set<String> failedFilePaths = const <String>{},
  int failedFiles = 0,
}) {
  final work = AsmrWork(
    id: 1,
    title: title,
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
  );
  final track = AsmrTrackFile(
    hash: 'track',
    title: 'Track.mp3',
    type: 'audio',
    streamUrl: null,
    downloadUrl: 'https://example.invalid/Track.mp3',
    lowQualityUrl: null,
    duration: Duration.zero,
    size: 1024,
    children: const <AsmrTrackFile>[],
    workId: 1,
    workTitle: 'Work',
    sourceId: 'RJ123456',
    relativePath: 'Track.mp3',
  );
  return AsmrDownloadTaskSnapshot(
    work: work,
    destinationRoot: r'C:\Downloads',
    workFolderName: 'Work',
    conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
    automaticFileRetryCount: 7,
    status: status,
    totalFiles: 1,
    completedFiles: 0,
    skippedFiles: 0,
    failedFiles: failedFiles,
    totalBytes: 1024,
    downloadedBytes: 128,
    startedAt: DateTime(2026),
    fileDownloadedBytes: const <String, int>{'Track.mp3': 128},
    fileTotalBytes: const <String, int>{'Track.mp3': 1024},
    fileRetryAttempts: fileRetryAttempts,
    failedFilePaths: failedFilePaths,
    selectedRoots: <AsmrTrackFile>[track],
  );
}

final class _RecordingDownloadManager extends AsmrDownloadManager {
  _RecordingDownloadManager() : super(persistTasks: false);

  final List<String> retriedPaths = <String>[];

  @override
  Future<bool> retryFailedFile(String workId, String relativePath) async {
    retriedPaths.add(relativePath);
    return true;
  }
}
