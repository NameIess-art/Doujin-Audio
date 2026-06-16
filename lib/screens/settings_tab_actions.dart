part of 'settings_tab.dart';

extension _SettingsTabActions on _SettingsTabState {
  Future<bool> _ensureInstallPermissionThenRun(
    BuildContext context,
    Future<void> Function() onGranted,
  ) {
    final i18n = context.read<AppLanguageProvider>();
    return _permissionActionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('install_permission_title'),
      message: i18n.tr('install_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('cancel'),
      isGranted: AppUpdateService.canInstallUnknownApps,
      openSettings: AppUpdateService.openInstallPermissionSettings,
      onGranted: onGranted,
    );
  }

  Future<void> _installDownloadedUpdate(
    BuildContext context,
    File updateFile,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    try {
      final result = await AppUpdateService.installUpdate(updateFile);
      if (!context.mounted) return;
      if (result.needsPermission) {
        await _ensureInstallPermissionThenRun(
          context,
          () => _installDownloadedUpdate(context, updateFile),
        );
        return;
      }
      if (!result.ok) {
        showAppSnackBar(
          context,
          result.message ?? i18n.tr('update_install_failed'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      showAppSnackBar(
        context,
        i18n.tr('update_ready_install'),
        tone: AppFeedbackTone.success,
        icon: Icons.install_mobile_rounded,
      );
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_install_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<void> _clearApplicationCache(BuildContext context) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('clear_app_cache'),
      message: i18n.tr('clear_app_cache_confirm'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('clear'),
      icon: Icons.cleaning_services_rounded,
      confirmColor: Theme.of(context).colorScheme.error,
    );
    if (!confirmed) return;

    final deletedBytes = await AppCacheService.clearAllCaches();
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

  Future<void> _checkForUpdates(BuildContext context) async {
    if (_checkingUpdate || _downloadingUpdate) return;
    final i18n = context.read<AppLanguageProvider>();
    _setLocalState(() {
      _checkingUpdate = true;
      _downloadProgress = null;
    });

    AppUpdateInfo info;
    try {
      info = await AppUpdateService.checkLatest();
      if (!mounted) return;
      _setLocalState(() => _lastUpdateInfo = info);
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_check_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.cloud_off_rounded,
      );
      return;
    } finally {
      if (mounted) {
        _setLocalState(() => _checkingUpdate = false);
      }
    }

    if (!info.isUpdateAvailable) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('no_updates_available'),
        tone: AppFeedbackTone.success,
        icon: Icons.verified_rounded,
      );
      return;
    }

    if (!context.mounted) return;
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(i18n.tr('latest_version_available')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                i18n.tr('current_version_label', {
                  'version': info.currentVersion.versionName,
                }),
              ),
              const SizedBox(height: 6),
              Text(
                i18n.tr('latest_version_label', {
                  'version': info.latestVersionName,
                }),
              ),
              const SizedBox(height: 10),
              Text(
                info.assetName,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(i18n.tr('later')),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.download_rounded),
              label: Text(i18n.tr('download_update')),
            ),
          ],
        );
      },
    );
    if (shouldDownload == true && context.mounted) {
      if (Platform.isAndroid) {
        await _ensureInstallPermissionThenRun(
          context,
          () => _downloadAndInstallUpdate(context, info),
        );
      } else {
        await _downloadAndInstallUpdate(context, info);
      }
    }
  }

  Future<void> _downloadAndInstallUpdate(
    BuildContext context,
    AppUpdateInfo info,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    _setLocalState(() {
      _downloadingUpdate = true;
      _downloadProgress = 0;
    });

    File updateFile;
    try {
      updateFile = await AppUpdateService.downloadUpdate(
        info,
        onProgress: (progress) {
          if (!mounted) return;
          _setLocalState(() => _downloadProgress = progress);
        },
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'manual_update_download_or_verification_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(i18n.tr('update_download_failed')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(i18n.tr('close')),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(AppUpdateService.openReleasePage(info.releaseUrl));
              },
              child: Text(i18n.tr('open_release_page')),
            ),
          ],
        ),
      );
      return;
    } finally {
      if (mounted) {
        _setLocalState(() => _downloadingUpdate = false);
      }
    }

    if (!context.mounted) return;
    await _installDownloadedUpdate(context, updateFile);
  }
}
