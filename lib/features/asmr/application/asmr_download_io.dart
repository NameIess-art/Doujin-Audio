part of 'asmr_download_manager.dart';

const String _asmrMediaAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

@visibleForTesting
Map<String, String> asmrMediaRequestHeadersForUrl(String url) {
  return AsmrApiService.isOfficialMediaUrl(url)
      ? const <String, String>{
          HttpHeaders.acceptLanguageHeader: _asmrMediaAcceptLanguage,
        }
      : const <String, String>{};
}

@visibleForTesting
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
      (responseLength <= 0 || responseLength == rangeLength) &&
      (expectedTotal <= 0 || total == null || total == expectedTotal);
}

typedef LocalFileRename =
    Future<File> Function(File source, String destination);

@visibleForTesting
Future<bool> commitLocalDownloadedFile({
  required File staging,
  required File target,
  LocalFileRename? rename,
}) async {
  final renameFile =
      rename ?? (source, destination) => source.rename(destination);
  final backup = File('${target.path}.doujin.bak');

  if (!await target.exists() && await backup.exists()) {
    await renameFile(backup, target.path);
  }
  if (await target.exists()) {
    if (await backup.exists()) {
      throw FileSystemException(
        'Cannot replace file while a previous backup is still present.',
        backup.path,
      );
    }
    await renameFile(target, backup.path);
  }

  try {
    await renameFile(staging, target.path);
  } catch (error, stackTrace) {
    try {
      if (await backup.exists()) {
        if (await target.exists()) await target.delete();
        await renameFile(backup, target.path);
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
