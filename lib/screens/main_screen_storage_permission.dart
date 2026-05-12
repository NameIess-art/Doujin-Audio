part of 'main_screen.dart';

extension _MainScreenStoragePermission on _MainScreenState {
  Future<bool> _canManageAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _MainScreenState._powerChannel.invokeMethod<bool>(
            PowerMethod.canManageAllFilesAccess,
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> _openManageAllFilesAccessSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _MainScreenState._powerChannel.invokeMethod<bool>(
            PowerMethod.openManageAllFilesAccessSettings,
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureManageFilesPermission() async {
    if (!mounted || !Platform.isAndroid || _manageFilesPermissionCheckDone) {
      return;
    }
    _manageFilesPermissionCheckDone = true;
    final i18n = context.read<AppLanguageProvider>();
    await _permissionActionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('manage_files_permission_title'),
      message: i18n.tr('manage_files_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('later'),
      isGranted: _canManageAllFilesAccess,
      openSettings: _openManageAllFilesAccessSettings,
      onGranted: _handleManageFilesPermissionGranted,
    );
  }

  Future<void> _handleManageFilesPermissionGranted() async {
    return;
  }
}
