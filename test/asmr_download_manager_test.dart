import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/audio_detail.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/services/asmr_download_manager.dart';

void main() {
  test('destinationExists checks local download folders', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_destination_',
    );
    final manager = AsmrDownloadManager();
    try {
      expect(await manager.destinationExists(tempDir.path), isTrue);
      await tempDir.delete(recursive: true);
      expect(await manager.destinationExists(tempDir.path), isFalse);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('task snapshot exposes a decoded destination path for SAF folders', () {
    const destinationRoot =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload';
    const workFolderName = 'RJ123456 - 羊娘';
    final task = AsmrDownloadTaskSnapshot(
      work: const AsmrWork(
        id: 1,
        title: '羊娘',
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
        voiceActors: <String>[],
        tags: <String>[],
      ),
      destinationRoot: destinationRoot,
      workFolderName: workFolderName,
      conflictPolicy: AsmrDownloadConflictPolicy.skip,
      status: AsmrDownloadTaskStatus.downloading,
      totalFiles: 1,
      completedFiles: 0,
      skippedFiles: 0,
      failedFiles: 0,
      totalBytes: 0,
      downloadedBytes: 0,
      startedAt: DateTime(2026),
    );

    expect(task.workRootPath, '$destinationRoot::$workFolderName');
    expect(task.displayDestinationPath, 'Download/$workFolderName');
  });

  test(
    'download progress notifications are throttled but completion is immediate',
    () async {
      final manager = AsmrDownloadManager();
      final notifications = <AsmrDownloadTaskSnapshot?>[];
      manager.addListener(() {
        notifications.add(manager.getTask(1));
      });

      final startedAt = DateTime(2026);
      final work = _work();
      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.downloading,
          totalFiles: 2,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024,
          downloadedBytes: 0,
          startedAt: startedAt,
        ),
      );

      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.downloading,
          totalFiles: 2,
          completedFiles: 0,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024,
          downloadedBytes: 1,
          startedAt: startedAt,
        ),
        progressOnly: true,
      );

      expect(notifications, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(notifications, hasLength(2));
      expect(notifications.last?.downloadedBytes, 1);

      manager.debugSetCurrentTaskForTesting(
        AsmrDownloadTaskSnapshot(
          work: work,
          destinationRoot: 'C:\\Downloads',
          workFolderName: 'RJ123456 - Work',
          conflictPolicy: AsmrDownloadConflictPolicy.skip,
          status: AsmrDownloadTaskStatus.completed,
          totalFiles: 2,
          completedFiles: 2,
          skippedFiles: 0,
          failedFiles: 0,
          totalBytes: 1024,
          downloadedBytes: 1024,
          startedAt: startedAt,
        ),
      );

      expect(notifications, hasLength(3));
      expect(notifications.last?.status, AsmrDownloadTaskStatus.completed);
      manager.dispose();
    },
  );

  test('download backup includes ASMR.ONE extended metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'asmr_download_backup_',
    );
    final manager = AsmrDownloadManager();
    final work = _work(
      releaseDate: DateTime(2024, 5, 6),
      dlCount: 1234,
      rating: 4.5,
    );
    try {
      await manager.startDownload(
        work: work,
        selectedRoots: const <AsmrTrackFile>[
          AsmrTrackFile(
            hash: 'folder',
            title: 'Folder',
            type: 'folder',
            streamUrl: null,
            downloadUrl: null,
            lowQualityUrl: null,
            duration: Duration.zero,
            size: 0,
            children: <AsmrTrackFile>[],
            workId: 1,
            workTitle: 'Work',
            sourceId: 'RJ123456',
            relativePath: 'Folder',
          ),
        ],
        destinationRoot: tempDir.path,
        conflictPolicy: AsmrDownloadConflictPolicy.skip,
      );

      final backupPath =
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work'
          '${Platform.pathSeparator}nameless-audio.json';
      final backup = await File(backupPath).readAsString();
      final detail = AudioDetail.fromBackupJson(
        AudioDetailTarget.libraryRootFolder(
          '${tempDir.path}${Platform.pathSeparator}RJ123456 - Work',
        ),
        Map<String, dynamic>.from(jsonDecode(backup) as Map),
      );
      expect(detail.releaseDate, DateTime(2024, 5, 6));
      expect(detail.salesCount, 1234);
      expect(detail.rating, 4.5);
    } finally {
      manager.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });
}

AsmrWork _work({DateTime? releaseDate, int dlCount = 0, double rating = 0}) {
  return AsmrWork(
    id: 1,
    title: 'Work',
    circleName: 'Circle',
    sourceId: 'RJ123456',
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: releaseDate,
    createDate: null,
    duration: Duration.zero,
    dlCount: dlCount,
    reviewCount: 0,
    rating: rating,
    voiceActors: const <String>[],
    tags: const <String>[],
  );
}
