import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/models/asmr_models.dart';
import 'package:nameless_audio/services/asmr_download_manager.dart';

void main() {
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
}
