import '../../../app/application/persisted_state_reloader.dart';
import '../../library/application/library_scan_models.dart';
import 'app_backup_service.dart';
import 'data_support_file_service.dart';

typedef LibraryBackupSourceReader = LocalLibraryImportSources Function();
typedef LibraryBackupSourcePreparer =
    Future<LocalLibraryImportSources?> Function(
      LocalLibraryImportSources sources,
      LibraryScanLabels labels,
    );
typedef LibraryBackupSourceRestorer =
    Future<void> Function(
      LocalLibraryImportSources sources,
      LibraryScanLabels labels,
    );

final class BackupRestoreCoordinator {
  BackupRestoreCoordinator({
    required DataSupportFileService fileService,
    required List<PersistedStateReloader> reloaders,
    required LibraryBackupSourceReader readLibrarySources,
    required LibraryBackupSourcePreparer prepareLibrarySources,
    required LibraryBackupSourceRestorer restoreLibrarySources,
  }) : _fileService = fileService,
       _reloaders = List<PersistedStateReloader>.unmodifiable(reloaders),
       _readLibrarySources = readLibrarySources,
       _prepareLibrarySources = prepareLibrarySources,
       _restoreLibrarySources = restoreLibrarySources;

  final DataSupportFileService _fileService;
  final List<PersistedStateReloader> _reloaders;
  final LibraryBackupSourceReader _readLibrarySources;
  final LibraryBackupSourcePreparer _prepareLibrarySources;
  final LibraryBackupSourceRestorer _restoreLibrarySources;

  Future<String?> exportBackup({required String dialogTitle}) async {
    for (final reloader in _reloaders) {
      if (reloader case final PersistedStateExportPreparer preparer) {
        await preparer.prepareForPersistedStateExport();
      }
    }
    return _fileService.exportBackup(
      dialogTitle: dialogTitle,
      librarySources: _readLibrarySources(),
    );
  }

  Future<BackupValidationResult?> pickAndRestoreBackup({
    required LibraryScanLabels labels,
  }) async {
    var prepared = false;
    final result = await _fileService.pickAndRestoreBackup(
      beforeRestore: (sources) async {
        final preparedSources = await _prepareLibrarySources(sources, labels);
        if (preparedSources == null) return null;
        prepared = true;
        for (final reloader in _reloaders) {
          if (reloader case final PersistedStateReplacementPreparer preparer) {
            await preparer.prepareForPersistedStateReplacement();
          }
        }
        return preparedSources;
      },
    );
    if (result == null) return null;
    if (!result.isValid) {
      if (prepared) {
        for (final reloader in _reloaders) {
          await reloader.reloadPersistedState();
        }
      }
      return result;
    }
    for (final reloader in _reloaders) {
      await reloader.reloadPersistedState();
    }
    await _restoreLibrarySources(result.librarySources, labels);
    return result;
  }
}
