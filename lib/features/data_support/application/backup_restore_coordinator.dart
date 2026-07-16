import '../../../app/application/persisted_state_reloader.dart';
import 'app_backup_service.dart';
import 'data_support_file_service.dart';

final class BackupRestoreCoordinator {
  BackupRestoreCoordinator({
    required DataSupportFileService fileService,
    required List<PersistedStateReloader> reloaders,
  }) : _fileService = fileService,
       _reloaders = List<PersistedStateReloader>.unmodifiable(reloaders);

  final DataSupportFileService _fileService;
  final List<PersistedStateReloader> _reloaders;

  Future<BackupValidationResult?> pickAndRestoreBackup() async {
    final result = await _fileService.pickAndRestoreBackup();
    if (result == null || !result.isValid) return result;
    for (final reloader in _reloaders) {
      await reloader.reloadPersistedState();
    }
    return result;
  }
}
