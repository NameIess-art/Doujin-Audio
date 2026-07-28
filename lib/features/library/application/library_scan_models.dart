import '../../../core/immutable_collections.dart';

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
  authorizationRequired,
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

enum LibrarySourceKind { library, folder, singleFile }

class LibrarySourceAccessIssue {
  const LibrarySourceAccessIssue({required this.source, required this.kind});

  final String source;
  final LibrarySourceKind kind;

  @override
  bool operator ==(Object other) =>
      other is LibrarySourceAccessIssue &&
      other.source == source &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(source, kind);
}

class LibrarySourceRebindResult {
  const LibrarySourceRebindResult({
    required this.oldSource,
    required this.newSource,
    required this.kind,
  });

  final String oldSource;
  final String newSource;
  final LibrarySourceKind kind;
}

class LibraryScanOutcome {
  LibraryScanOutcome({
    required this.code,
    required this.source,
    Map<String, Object?> details = const <String, Object?>{},
  }) : details = immutableJsonMap(details)!;

  final LibraryScanOutcomeCode code;
  final String source;
  final Map<String, Object?> details;

  int get addedCount => (details['count'] as int?) ?? 0;
  int get folderCount => (details['folderCount'] as int?) ?? 0;
}
