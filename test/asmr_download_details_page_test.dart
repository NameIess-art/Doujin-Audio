import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_download.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_details_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('download details follows the selected language', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final languageProvider = AppLanguageProvider();
    addTearDown(languageProvider.dispose);
    await languageProvider.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadTaskProvider(404).overrideWithValue(null),
        ],
        child: const MaterialApp(home: AsmrDownloadDetailsPage(workId: 404)),
      ),
    );
    await tester.pump();

    expect(find.text('Download details'), findsOneWidget);
    expect(find.text('Download task not found'), findsOneWidget);

    await languageProvider.setLanguage(AppLanguage.ja);
    await tester.pump();

    expect(find.text('ダウンロード詳細'), findsOneWidget);
    expect(find.text('ダウンロードタスクが見つかりません'), findsOneWidget);
    expect(find.text('Download task not found'), findsNothing);
  });

  testWidgets('folder tile uses rounded rectangle shape', (tester) async {
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
    final task = _downloadTask().copyWith(selectedRoots: <AsmrTrackFile>[folder]);
    await tester.pumpWidget(_downloadDetailsApp(languageProvider, task));
    await tester.pump();

    final expansionTile = tester.widget<ExpansionTile>(find.byType(ExpansionTile));
    expect(expansionTile.shape, isA<RoundedRectangleBorder>());
    expect(expansionTile.collapsedShape, isA<RoundedRectangleBorder>());
    final shape = expansionTile.shape as RoundedRectangleBorder;
    expect(shape.borderRadius, isA<BorderRadius>());
    expect((shape.borderRadius as BorderRadius).topLeft.x, greaterThan(0));
  });

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

  testWidgets('failed file exposes a manual retry action and progress state', (
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
      _downloadDetailsApp(languageProvider, failedTask, manager: manager),
    );
    await tester.pump();

    final retryButton = find.byKey(
      const ValueKey<String>('asmr_download_manual_retry_Track.mp3'),
    );
    expect(retryButton, findsOneWidget);
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

    expect(retryButton, findsNothing);
    expect(
      find.byKey(
        const ValueKey<String>('asmr_download_manual_retry_progress_Track.mp3'),
      ),
      findsOneWidget,
    );

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
}

Widget _downloadDetailsApp(
  AppLanguageProvider languageProvider,
  AsmrDownloadTaskSnapshot task, {
  AsmrDownloadManager? manager,
}) {
  return ProviderScope(
    overrides: [
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
      asmrDownloadTaskProvider(1).overrideWithValue(task),
      if (manager != null)
        asmrDownloadManagerProvider.overrideWithValue(manager),
    ],
    child: const MaterialApp(home: AsmrDownloadDetailsPage(workId: 1)),
  );
}

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
  Future<bool> retryFailedFile(int workId, String relativePath) async {
    retriedPaths.add(relativePath);
    return true;
  }
}
