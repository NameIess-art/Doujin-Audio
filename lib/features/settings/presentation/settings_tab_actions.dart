part of 'settings_tab.dart';

extension _SettingsTabActions on _SettingsTabState {
  Future<void> _clearApplicationCache(BuildContext context) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('clear_app_cache'),
      message: i18n.tr('clear_app_cache_confirm'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('clear_app_cache'),
      icon: Icons.cleaning_services_rounded,
      confirmColor: Theme.of(context).colorScheme.error,
    );
    if (!confirmed || !mounted) return;

    final deletedBytes = await _runSettingsOperation<int>(
      scope: UiOperationScope.settingsCache,
      labelKey: 'loading_dot',
      task: (_) =>
          ref.read(settingsCommandControllerProvider).clearApplicationCache(),
    );
    if (!context.mounted) return;
    if (deletedBytes > 0) {
      showAppSnackBar(
        context,
        i18n.tr('app_cache_cleaned', {
          'size': AppCacheService.formatBytes(deletedBytes),
        }),
        tone: AppFeedbackTone.success,
        icon: Icons.cleaning_services_rounded,
      );
      return;
    }

    showAppSnackBar(
      context,
      i18n.tr('app_cache_none'),
      icon: Icons.info_outline_rounded,
    );
  }

  Future<void> _checkForUpdates(BuildContext context) {
    return _updateFlow.checkAndPresent(
      context: context,
      operations: ref.read(uiOperationServiceProvider),
      onInfo: (info) {
        if (mounted) {
          _updateInfoNotifier.value = info;
        }
      },
    );
  }
}
