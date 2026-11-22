import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../core/media/playback_media_reference.dart';
import '../../../core/logging/app_log_service.dart';
import 'asmr_api_service.dart';

const String _asmrMediaAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';
const int _kWindowsExtendedPathThreshold = 220;
final RegExp _strongEntityTag = RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$');

/// Applies the Windows extended-length prefix (`\\?\`) when a normalized local
/// path approaches legacy Win32 `MAX_PATH` limits, leaving short logical paths
/// unchanged.
String windowsExtendedLocalPath(
  String localPath, {
  bool? forceWindows,
}) {
  final isWindows = forceWindows ?? Platform.isWindows;
  if (!isWindows || localPath.isEmpty) return localPath;
  if (localPath.startsWith(r'\\?\') || localPath.startsWith(r'\\.\')) {
    return localPath;
  }
  final normalized = path.windows.normalize(localPath.replaceAll('/', r'\'));
  if (normalized.length < _kWindowsExtendedPathThreshold) {
    return localPath;
  }
  if (normalized.startsWith(r'\\')) {
    return r'\\?\UNC\' + normalized.substring(2);
  }
  final hasDrivePrefix =
      normalized.length >= 2 &&
      normalized[1] == ':' &&
      ((normalized.codeUnitAt(0) >= 65 && normalized.codeUnitAt(0) <= 90) ||
          (normalized.codeUnitAt(0) >= 97 && normalized.codeUnitAt(0) <= 122));
  if (!hasDrivePrefix) return localPath;
  final trimmed =
      normalized.length > 3 && normalized.endsWith(r'\')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  return r'\\?\' + trimmed;
}

String stripWindowsExtendedLocalPath(String localPath) {
  if (localPath.startsWith(r'\\?\UNC\')) {
    return r'\\' + localPath.substring(8);
  }
  if (localPath.startsWith(r'\\?\')) {
    return localPath.substring(4);
  }
  return localPath;
}

File localDownloadFile(String localPath) =>
    File(windowsExtendedLocalPath(localPath));

Directory localDownloadDirectory(String localPath) =>
    Directory(windowsExtendedLocalPath(localPath));

String? strongDownloadEntityTag(Object? value) {
  if (value is! String) return null;
  final tag = value.trim();
  return _strongEntityTag.hasMatch(tag) ? tag : null;
}

Map<String, String> asmrMediaRequestHeadersForUrl(String url) {
  final uri = Uri.tryParse(url);
  return <String, String>{
    if (AsmrApiService.isOfficialMediaUrl(url))
      HttpHeaders.acceptLanguageHeader: _asmrMediaAcceptLanguage,
    if (uri != null) ...PlaybackMediaReference.requestHeadersForUri(uri),
  };
}

bool isValidDownloadContentRange(
  String? value, {
  required int expectedStart,
  required int responseLength,
  required int expectedTotal,
}) {
  final match = value == null
      ? null
      : RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
  final start = int.tryParse(match?.group(1) ?? '');
  final end = int.tryParse(match?.group(2) ?? '');
  final total = int.tryParse(match?.group(3) ?? '');
  final rangeLength = start == null || end == null ? -1 : end - start + 1;
  return start == expectedStart &&
      rangeLength > 0 &&
      total != null &&
      end == total - 1 &&
      (responseLength < 0 || responseLength == rangeLength) &&
      (expectedTotal <= 0 || total == expectedTotal);
}

typedef LocalFileRename =
    Future<File> Function(File source, String destination);

Future<bool> commitLocalDownloadedFile({
  required File staging,
  required File target,
  LocalFileRename? rename,
}) async {
  final useExtended = rename == null;
  final stagingFile = useExtended ? localDownloadFile(staging.path) : staging;
  final targetFile = useExtended ? localDownloadFile(target.path) : target;
  final renameFile =
      rename ?? (source, destination) => source.rename(destination);
  final backup = useExtended
      ? localDownloadFile('${stripWindowsExtendedLocalPath(target.path)}.doujin.bak')
      : File('${target.path}.doujin.bak');

  if (!await targetFile.exists() && await backup.exists()) {
    await renameFile(backup, targetFile.path);
  }
  if (await targetFile.exists()) {
    if (await backup.exists()) {
      throw FileSystemException(
        'Cannot replace file while a previous backup is still present.',
        backup.path,
      );
    }
    await renameFile(targetFile, backup.path);
  }

  try {
    await renameFile(stagingFile, targetFile.path);
  } catch (error, stackTrace) {
    try {
      if (await backup.exists()) {
        if (await targetFile.exists()) await targetFile.delete();
        await renameFile(backup, targetFile.path);
      }
    } catch (rollbackError, rollbackStackTrace) {
      AppLogService.error(
        'commitLocalDownloadedFile rollback failed',
        error: rollbackError,
        stackTrace: rollbackStackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }

  try {
    if (await backup.exists()) await backup.delete();
  } catch (error, stackTrace) {
    AppLogService.warning(
      'commitLocalDownloadedFile backup cleanup failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return true;
}
