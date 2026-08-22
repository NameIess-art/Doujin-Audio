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

  testWidgets('download details shows and clears a file retry attempt', (
    tester,
  ) async {
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
    expect(find.text('Retrying (1/10)'), findsOneWidget);

    await tester.pumpWidget(
      _downloadDetailsApp(
        languageProvider,
        retryingTask.copyWith(status: AsmrDownloadTaskStatus.completed),
      ),
    );
    await tester.pump();

    expect(find.text('Retrying (1/10)'), findsNothing);
    expect(find.text('128 B / 1.0 KB'), findsNWidgets(2));
  });
}

Widget _downloadDetailsApp(
  AppLanguageProvider languageProvider,
  AsmrDownloadTaskSnapshot task,
) {
  return ProviderScope(
    overrides: [
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
      asmrDownloadTaskProvider(1).overrideWithValue(task),
    ],
    child: const MaterialApp(home: AsmrDownloadDetailsPage(workId: 1)),
  );
}

AsmrDownloadTaskSnapshot _downloadTask({
  Map<String, int> fileRetryAttempts = const <String, int>{},
}) {
  final work = AsmrWork(
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
    status: AsmrDownloadTaskStatus.downloading,
    totalFiles: 1,
    completedFiles: 0,
    skippedFiles: 0,
    failedFiles: 0,
    totalBytes: 1024,
    downloadedBytes: 128,
    startedAt: DateTime(2026),
    fileDownloadedBytes: const <String, int>{'Track.mp3': 128},
    fileTotalBytes: const <String, int>{'Track.mp3': 1024},
    fileRetryAttempts: fileRetryAttempts,
    selectedRoots: <AsmrTrackFile>[track],
  );
}
