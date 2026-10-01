part of 'main_screen.dart';

extension _MainScreenPermissions on _MainScreenState {
  PermissionStatusService get _permissionStatusService =>
      ref.read(permissionStatusServiceProvider);

  Future<bool> _isIgnoringBatteryOptimizations() async {
    return _permissionStatusService.isGranted(
      PermissionCapability.backgroundRun,
    );
  }

  Future<void> _openBatteryOptimizationSettings() async {
    await _permissionStatusService.openBatteryOptimizationSettings();
  }

  Future<void> _maybePromptForBackgroundPlaybackReliability() async {
    try {
      if (!mounted ||
          !Platform.isAndroid ||
          _backgroundPlaybackPromptShownThisLaunch) {
        return;
      }
      final diagnostics = await _permissionStatusService
          .loadBackgroundRunDiagnostics();
      if (!mounted) return;
      final ignoringBatteryOptimizations =
          diagnostics?.batteryOptimizationExempt ??
          await _isIgnoringBatteryOptimizations();
      if (!mounted || ignoringBatteryOptimizations) {
        _backgroundPlaybackPromptShownThisLaunch = true;
        return;
      }
      _backgroundPlaybackPromptShownThisLaunch = true;
      await _promptOpenBatteryOptimizationSettings();
    } finally {
      _backgroundPlaybackPromptQueued = false;
    }
  }

  Future<void> _promptOpenBatteryOptimizationSettings() async {
    if (!mounted) return;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final openSettings = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('background_play_permission_title'),
      message: i18n.tr('background_play_permission_message'),
      cancelLabel: i18n.tr('later'),
      confirmLabel: i18n.tr('go_settings'),
      icon: Icons.battery_saver_rounded,
      confirmIcon: Icons.settings_rounded,
      isDestructive: false,
    );
    if (!mounted || openSettings != true) return;
    await _openBatteryOptimizationSettings();
  }
}
