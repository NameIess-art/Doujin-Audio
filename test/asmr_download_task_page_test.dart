import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:nameless_audio/features/asmr/domain/asmr_download.dart';
import 'package:nameless_audio/features/asmr/domain/asmr_models.dart';
import 'package:nameless_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
          asmrDownloadManagerProvider.overrideWithValue(manager),
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
    await tester.pumpAndSettle();

    expect(manager.getTask(1), isNull);
  });
}

AsmrDownloadTaskSnapshot _failedTask() {
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
    status: AsmrDownloadTaskStatus.failed,
    totalFiles: 1,
    completedFiles: 0,
    skippedFiles: 0,
    failedFiles: 1,
    totalBytes: 1024,
    downloadedBytes: 0,
    startedAt: DateTime(2026),
  );
}
