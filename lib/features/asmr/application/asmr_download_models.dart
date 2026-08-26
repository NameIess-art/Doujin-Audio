import 'package:path/path.dart' as path;

import '../../../core/immutable_collections.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../domain/asmr_download.dart';
import '../domain/asmr_models.dart';

enum AsmrDownloadTaskStatus {
  idle,
  preparing,
  downloading,
  paused,
  completed,
  failed,
}

class AsmrDownloadTaskSnapshot {
  AsmrDownloadTaskSnapshot({
    required this.work,
    required this.destinationRoot,
    required this.workFolderName,
    required this.conflictPolicy,
    this.saveMetadata = true,
    this.saveCover = false,
    this.automaticFileRetryCount = kMaxAsmrDownloadRetryCount,
    required this.status,
    required this.totalFiles,
    required this.completedFiles,
    required this.skippedFiles,
    required this.failedFiles,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.startedAt,
    this.currentItemPath,
    this.coverOutputPath,
    this.message,
    this.error,
    Map<String, int> fileDownloadedBytes = const {},
    Map<String, int> fileTotalBytes = const {},
    Map<String, int> fileRetryAttempts = const {},
    Set<String> completedFilePaths = const {},
    List<AsmrTrackFile> selectedRoots = const [],
  }) : fileDownloadedBytes = immutableMap(fileDownloadedBytes),
       fileTotalBytes = immutableMap(fileTotalBytes),
       fileRetryAttempts = immutableMap(fileRetryAttempts),
       completedFilePaths = immutableSet(completedFilePaths),
       selectedRoots = immutableList(selectedRoots);

  final AsmrWork work;
  final String destinationRoot;
  final String workFolderName;
  final AsmrDownloadConflictPolicy conflictPolicy;
  final bool saveMetadata;
  final bool saveCover;
  final int automaticFileRetryCount;
  final AsmrDownloadTaskStatus status;
  final int totalFiles;
  final int completedFiles;
  final int skippedFiles;
  final int failedFiles;
  final int totalBytes;
  final int downloadedBytes;
  final DateTime startedAt;
  final String? currentItemPath;
  final String? coverOutputPath;
  final String? message;
  final String? error;
  final Map<String, int> fileDownloadedBytes;
  final Map<String, int> fileTotalBytes;
  final Map<String, int> fileRetryAttempts;
  final Set<String> completedFilePaths;
  final List<AsmrTrackFile> selectedRoots;

  String get workRootPath {
    if (PathMatcher.isContentUri(destinationRoot)) {
      final normalizedRoot = destinationRoot.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );
      return '$normalizedRoot::$workFolderName';
    }
    return path.join(destinationRoot, workFolderName);
  }

  String get displayDestinationPath => PathDisplay.displayPathFor(workRootPath);

  bool get isActive =>
      status == AsmrDownloadTaskStatus.preparing ||
      status == AsmrDownloadTaskStatus.downloading;

  double? get progress {
    if (totalBytes > 0) {
      return (downloadedBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalFiles > 0) {
      return (completedFiles / totalFiles).clamp(0.0, 1.0);
    }
    return null;
  }

  AsmrDownloadTaskSnapshot copyWith({
    AsmrDownloadTaskStatus? status,
    AsmrDownloadConflictPolicy? conflictPolicy,
    int? totalFiles,
    int? completedFiles,
    int? skippedFiles,
    int? failedFiles,
    int? totalBytes,
    int? downloadedBytes,
    String? currentItemPath,
    String? coverOutputPath,
    String? message,
    String? error,
    Map<String, int>? fileDownloadedBytes,
    Map<String, int>? fileTotalBytes,
    Map<String, int>? fileRetryAttempts,
    Set<String>? completedFilePaths,
    List<AsmrTrackFile>? selectedRoots,
  }) {
    return AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: destinationRoot,
      workFolderName: workFolderName,
      conflictPolicy: conflictPolicy ?? this.conflictPolicy,
      saveMetadata: saveMetadata,
      saveCover: saveCover,
      automaticFileRetryCount: automaticFileRetryCount,
      status: status ?? this.status,
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      skippedFiles: skippedFiles ?? this.skippedFiles,
      failedFiles: failedFiles ?? this.failedFiles,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      startedAt: startedAt,
      currentItemPath: currentItemPath ?? this.currentItemPath,
      coverOutputPath: coverOutputPath ?? this.coverOutputPath,
      message: message ?? this.message,
      error: error ?? this.error,
      fileDownloadedBytes: fileDownloadedBytes ?? this.fileDownloadedBytes,
      fileTotalBytes: fileTotalBytes ?? this.fileTotalBytes,
      fileRetryAttempts: fileRetryAttempts ?? this.fileRetryAttempts,
      completedFilePaths: completedFilePaths ?? this.completedFilePaths,
      selectedRoots: selectedRoots ?? this.selectedRoots,
    );
  }
}

class AsmrDownloadButtonViewState {
  const AsmrDownloadButtonViewState({
    required this.visible,
    required this.progress,
  });

  final bool visible;
  final double? progress;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadButtonViewState &&
        visible == other.visible &&
        progress == other.progress;
  }

  @override
  int get hashCode => Object.hash(visible, progress);
}

class AsmrDownloadTaskShellViewState {
  const AsmrDownloadTaskShellViewState({
    required this.hasTask,
    required this.isActive,
  });

  final bool hasTask;
  final bool isActive;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadTaskShellViewState &&
        hasTask == other.hasTask &&
        isActive == other.isActive;
  }

  @override
  int get hashCode => Object.hash(hasTask, isActive);
}

class AsmrDownloadTaskProgressViewState {
  const AsmrDownloadTaskProgressViewState({
    required this.progress,
    required this.status,
    required this.completedFiles,
    required this.totalFiles,
    required this.skippedFiles,
    required this.failedFiles,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final double? progress;
  final AsmrDownloadTaskStatus status;
  final int completedFiles;
  final int totalFiles;
  final int skippedFiles;
  final int failedFiles;
  final int downloadedBytes;
  final int totalBytes;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadTaskProgressViewState &&
        progress == other.progress &&
        status == other.status &&
        completedFiles == other.completedFiles &&
        totalFiles == other.totalFiles &&
        skippedFiles == other.skippedFiles &&
        failedFiles == other.failedFiles &&
        downloadedBytes == other.downloadedBytes &&
        totalBytes == other.totalBytes;
  }

  @override
  int get hashCode => Object.hash(
    progress,
    status,
    completedFiles,
    totalFiles,
    skippedFiles,
    failedFiles,
    downloadedBytes,
    totalBytes,
  );
}

class AsmrDownloadTaskHeaderViewState {
  const AsmrDownloadTaskHeaderViewState({
    required this.title,
    required this.status,
    required this.currentItemPath,
    required this.error,
    required this.failedFiles,
    required this.completedFiles,
  });

  final String title;
  final AsmrDownloadTaskStatus status;
  final String? currentItemPath;
  final String? error;
  final int failedFiles;
  final int completedFiles;

  @override
  bool operator ==(Object other) {
    return other is AsmrDownloadTaskHeaderViewState &&
        title == other.title &&
        status == other.status &&
        currentItemPath == other.currentItemPath &&
        error == other.error &&
        failedFiles == other.failedFiles &&
        completedFiles == other.completedFiles;
  }

  @override
  int get hashCode => Object.hash(
    title,
    status,
    currentItemPath,
    error,
    failedFiles,
    completedFiles,
  );
}
