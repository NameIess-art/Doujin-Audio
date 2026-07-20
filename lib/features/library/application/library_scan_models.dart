export '../../../core/platform/library_scan_wire_models.dart';
export '../../../core/media/local_library_import_sources.dart';

class LibraryScanLabels {
  const LibraryScanLabels({
    required this.chooseMusicFolder,
    required this.chooseLibraryFolder,
    required this.chooseAudioFiles,
    required this.importedFiles,
    required this.manuallySelectedFiles,
  });

  final String chooseMusicFolder;
  final String chooseLibraryFolder;
  final String chooseAudioFiles;
  final String importedFiles;
  final String manuallySelectedFiles;
}

enum LibraryScanOutcomeCode {
  noSources,
  permissionDenied,
  alreadyRunning,
  folderExists,
  libraryExists,
  fileExists,
  cancelled,
  failed,
  noAudio,
  refreshAdded,
  refreshNoChanges,
  importAdded,
  libraryImported,
}

class LibraryScanOutcome {
  const LibraryScanOutcome({
    required this.code,
    required this.source,
    this.details = const <String, Object?>{},
  });

  final LibraryScanOutcomeCode code;
  final String source;
  final Map<String, Object?> details;

  int get addedCount => (details['count'] as int?) ?? 0;
  int get folderCount => (details['folderCount'] as int?) ?? 0;
}
