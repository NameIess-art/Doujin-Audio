part of 'settings_tab.dart';

extension _SettingsTabActions on _SettingsTabState {
  Future<void> _clearTempCache(BuildContext context) async {
    final i18n = context.read<AppLanguageProvider>();
    final cacheDir = Directory(
      path.join(Directory.systemTemp.path, 'nameless_audio_imports'),
    );
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('temp_cache_cleaned'),
          tone: AppFeedbackTone.success,
          icon: Icons.cleaning_services_rounded,
        );
      }
      return;
    }

    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('temp_cache_none'),
        icon: Icons.info_outline_rounded,
      );
    }
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _SettingsTabState._powerChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openBackgroundRunSettings(BuildContext context) async {
    if (!Platform.isAndroid) return;
    try {
      final opened =
          await _SettingsTabState._powerChannel.invokeMethod<bool>(
            'openBackgroundRunSettings',
          ) ??
          false;
      if (!opened && context.mounted) {
        showAppSnackBar(
          context,
          context.read<AppLanguageProvider>().tr(
            'allow_background_run_open_failed',
          ),
          tone: AppFeedbackTone.warning,
          icon: Icons.settings_applications_rounded,
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr(
          'allow_background_run_open_failed',
        ),
        tone: AppFeedbackTone.warning,
        icon: Icons.settings_applications_rounded,
      );
    } finally {
      Future<void>.delayed(
        const Duration(milliseconds: 600),
        _refreshBackgroundRunStatus,
      );
    }
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
      final canInstallUnknownApps =
          await AppUpdateService.canInstallUnknownApps();
      if (!context.mounted) return;
      if (!canInstallUnknownApps) {
        await AppUpdateService.openInstallPermissionSettings();
        if (!context.mounted) return;
        showAppSnackBar(
          context,
          i18n.tr('install_permission_needed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.admin_panel_settings_rounded,
        );
        return;
      }
      await _downloadAndInstallUpdate(context, info);
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

    File apkFile;
    try {
      apkFile = await AppUpdateService.downloadUpdate(
        info,
        onProgress: (progress) {
          if (!mounted) return;
          _setLocalState(() => _downloadProgress = progress);
        },
      );
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_download_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
      return;
    } finally {
      if (mounted) {
        _setLocalState(() => _downloadingUpdate = false);
      }
    }

    try {
      final result = await AppUpdateService.installApk(apkFile);
      if (!context.mounted) return;
      if (result.needsPermission) {
        showAppSnackBar(
          context,
          i18n.tr('install_permission_needed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.admin_panel_settings_rounded,
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
}
