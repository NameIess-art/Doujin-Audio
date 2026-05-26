part of 'main_screen.dart';

extension _MainScreenStoragePermission on _MainScreenState {
  Future<bool> _canManageAllFilesAccess() async {
    return _powerPlatformService.canManageAllFilesAccess();
  }

  Future<bool> _openManageAllFilesAccessSettings() async {
    return _powerPlatformService.openManageAllFilesAccessSettings();
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
