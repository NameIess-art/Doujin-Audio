part of 'asmr_download_manager.dart';

Map<String, Object?> _downloadTaskToJson(
  AsmrDownloadTaskSnapshot task, {
  required Set<String> createdOutputPaths,
  required Map<String, _CreatedJsonDocument> createdJsonDocuments,
}) => <String, Object?>{
  'work': task.work.toJson(),
  'destinationRoot': task.destinationRoot,
  'workFolderName': task.workFolderName,
  'conflictPolicy': task.conflictPolicy.name,
  'saveMetadata': task.saveMetadata,
  'saveCover': task.saveCover,
  'automaticFileRetryCount': task.automaticFileRetryCount,
  'totalFiles': task.totalFiles,
  'completedFiles': task.completedFiles,
  'skippedFiles': task.skippedFiles,
  'failedFiles': task.failedFiles,
  'totalBytes': task.totalBytes,
  'downloadedBytes': task.downloadedBytes,
  'startedAt': task.startedAt.toIso8601String(),
  'currentItemPath': task.currentItemPath,
  'coverOutputPath': task.coverOutputPath,
  'message': task.message,
  'error': task.error,
  'fileDownloadedBytes': task.fileDownloadedBytes,
  'fileTotalBytes': task.fileTotalBytes,
  'completedFilePaths': task.completedFilePaths.toList(growable: false),
  'selectedRoots': task.selectedRoots.map(_downloadTrackToJson).toList(),
  'createdOutputPaths': createdOutputPaths.toList(growable: false),
  'createdJsonDocuments': <String, Object?>{
    for (final entry in createdJsonDocuments.entries)
      entry.key: entry.value.toJson(),
  },
};

_PersistedDownloadTask _downloadTaskFromJson(Map<String, dynamic> json) {
  final workJson = json['work'];
  if (workJson is! Map<Object?, Object?>) {
    throw const FormatException('Missing download work.');
  }
  final work = AsmrWork.fromJson(Map<String, dynamic>.from(workJson));
  if (work.id <= 0) throw const FormatException('Invalid download work.');
  final selectedRoots = (json['selectedRoots'] as List? ?? const <Object>[])
      .whereType<Map<Object?, Object?>>()
      .map((value) => _downloadTrackFromJson(Map<String, dynamic>.from(value)))
      .toList(growable: false);
  if (selectedRoots.isEmpty) {
    throw const FormatException('Missing selected download files.');
  }
  return _PersistedDownloadTask(
    task: AsmrDownloadTaskSnapshot(
      work: work,
      destinationRoot: json['destinationRoot'] as String? ?? '',
      workFolderName: json['workFolderName'] as String? ?? '',
      conflictPolicy: _enumByName(
        AsmrDownloadConflictPolicy.values,
        json['conflictPolicy'],
        AsmrDownloadConflictPolicy.skip,
      ),
      saveMetadata: json['saveMetadata'] as bool? ?? true,
      saveCover: json['saveCover'] as bool? ?? false,
      automaticFileRetryCount: normalizeAsmrDownloadRetryCount(
        (json['automaticFileRetryCount'] as num?)?.toInt() ??
            kMaxAsmrDownloadRetryCount,
      ),
      status: AsmrDownloadTaskStatus.paused,
      totalFiles: _jsonInt(json['totalFiles']),
      completedFiles: _jsonInt(json['completedFiles']),
      skippedFiles: _jsonInt(json['skippedFiles']),
      failedFiles: _jsonInt(json['failedFiles']),
      totalBytes: _jsonInt(json['totalBytes']),
      downloadedBytes: _jsonInt(json['downloadedBytes']),
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      currentItemPath: json['currentItemPath'] as String?,
      coverOutputPath: json['coverOutputPath'] as String?,
      message: json['message'] as String?,
      error: json['error'] as String?,
      fileDownloadedBytes: _jsonIntMap(json['fileDownloadedBytes']),
      fileTotalBytes: _jsonIntMap(json['fileTotalBytes']),
      completedFilePaths:
          (json['completedFilePaths'] as List? ?? const <Object>[])
              .whereType<String>()
              .toSet(),
      selectedRoots: selectedRoots,
    ),
    createdOutputPaths: (json['createdOutputPaths'] as List? ?? const [])
        .whereType<String>()
        .toSet(),
    createdJsonDocuments: _createdJsonDocumentsFromJson(
      json['createdJsonDocuments'],
    ),
  );
}

Map<String, _CreatedJsonDocument> _createdJsonDocumentsFromJson(Object? value) {
  if (value is! Map<Object?, Object?>) {
    return const <String, _CreatedJsonDocument>{};
  }
  final result = <String, _CreatedJsonDocument>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! Map<Object?, Object?>) continue;
    final decoded = _CreatedJsonDocument.fromJson(
      Map<String, Object?>.from(entry.value as Map<Object?, Object?>),
    );
    if (decoded != null) result[entry.key as String] = decoded;
  }
  return result;
}

Map<String, Object?> _downloadTrackToJson(AsmrTrackFile track) =>
    <String, Object?>{
      'hash': track.hash,
      'title': track.title,
      'type': track.type,
      'streamUrl': track.streamUrl,
      'downloadUrl': track.downloadUrl,
      'lowQualityUrl': track.lowQualityUrl,
      'durationMs': track.duration.inMilliseconds,
      'size': track.size,
      'workId': track.workId,
      'workTitle': track.workTitle,
      'sourceId': track.sourceId,
      'relativePath': track.relativePath,
      'children': track.children.map(_downloadTrackToJson).toList(),
    };

AsmrTrackFile _downloadTrackFromJson(Map<String, dynamic> json) =>
    AsmrTrackFile(
      hash: json['hash'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: json['type'] as String? ?? '',
      streamUrl: json['streamUrl'] as String?,
      downloadUrl: json['downloadUrl'] as String?,
      lowQualityUrl: json['lowQualityUrl'] as String?,
      duration: Duration(milliseconds: _jsonInt(json['durationMs'])),
      size: _jsonInt(json['size']),
      children: (json['children'] as List? ?? const <Object>[])
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => _downloadTrackFromJson(Map<String, dynamic>.from(value)),
          )
          .toList(growable: false),
      workId: _jsonInt(json['workId']),
      workTitle: json['workTitle'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? '',
      relativePath: json['relativePath'] as String? ?? '',
    );

Map<String, int> _jsonIntMap(Object? value) {
  if (value is! Map<Object?, Object?>) return const <String, int>{};
  return <String, int>{
    for (final entry in value.entries)
      if (entry.key is String && entry.value is num)
        entry.key as String: (entry.value as num).toInt(),
  };
}

int _jsonInt(Object? value) => (value as num?)?.toInt() ?? 0;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
