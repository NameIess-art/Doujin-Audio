import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/permission_action_controller.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_feedback.dart';
import '../application/app_update_service.dart';

class AppUpdateFlow {
  AppUpdateFlow({
    required PermissionActionController permissionController,
    required AppLanguageProvider languageProvider,
    required AppUpdateService updateService,
    Future<AppUpdateInfo> Function()? checkLatest,
  }) : _permissionController = permissionController,
       _languageProvider = languageProvider,
       _updateService = updateService,
       _checkLatest = checkLatest ?? updateService.checkLatest;

  final PermissionActionController _permissionController;
  final AppLanguageProvider _languageProvider;
  final AppUpdateService _updateService;
  final Future<AppUpdateInfo> Function() _checkLatest;

  Future<void> checkAndPresent({
    required BuildContext context,
    required UiOperationService operations,
    bool automatic = false,
    ValueChanged<AppUpdateInfo>? onInfo,
  }) async {
    if (operations.isBusy(UiOperationScope.settingsUpdate)) return;
    final i18n = _languageProvider;
    AppUpdateInfo info;
    try {
      info = await operations.run<AppUpdateInfo>(
        scope: UiOperationScope.settingsUpdate,
        labelKey: 'loading_dot',
        cancelPrevious: false,
        task: (_) => _checkLatest(),
      );
      onInfo?.call(info);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'update_check_failed automatic=$automatic',
        error: error,
        stackTrace: stackTrace,
      );
      if (!automatic && context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('update_check_failed_next_step'),
          tone: AppFeedbackTone.destructive,
          title: i18n.tr('update_check_failed'),
          icon: Icons.cloud_off_rounded,
          actionLabel: i18n.tr('retry'),
          onAction: () => unawaited(
            checkAndPresent(
              context: context,
              operations: operations,
              onInfo: onInfo,
            ),
          ),
          duration: const Duration(seconds: 6),
        );
      }
      return;
    }

    if (!context.mounted) return;
    if (!info.isUpdateAvailable) {
      if (!automatic) _showNoUpdateFeedback(context, info, i18n);
      return;
    }
    await _showUpdateDialog(context, operations, info);
  }

  void _showNoUpdateFeedback(
    BuildContext context,
    AppUpdateInfo info,
    AppLanguageProvider i18n,
  ) {
    final messageKey = switch (info.status) {
      AppUpdateStatus.noCompatibleRelease => 'update_no_compatible_release',
      AppUpdateStatus.missingAsset => 'update_missing_asset',
      AppUpdateStatus.missingChecksum => 'update_missing_checksum',
      _ => 'no_updates_available',
    };
    showAppSnackBar(
      context,
      i18n.tr(messageKey),
      tone: info.status == AppUpdateStatus.upToDate
          ? AppFeedbackTone.success
          : AppFeedbackTone.warning,
      icon: info.status == AppUpdateStatus.upToDate
          ? Icons.verified_rounded
          : Icons.info_outline_rounded,
    );
  }

  Future<void> _showUpdateDialog(
    BuildContext context,
    UiOperationService operations,
    AppUpdateInfo info,
  ) async {
    final i18n = _languageProvider;
    final shouldDownload = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: i18n.tr('latest_version_available'),
        icon: Icons.system_update_rounded,
        scrollable: true,
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
              info.assetName ?? '',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: AppDialogActions(
          children: [
            AppSecondaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              label: i18n.tr('later'),
            ),
            AppPrimaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              label: i18n.tr('download_update'),
              icon: Icons.download_rounded,
            ),
          ],
        ),
      ),
    );
    if (shouldDownload != true || !context.mounted || !info.canDownload) {
      return;
    }
    if (Platform.isAndroid) {
      await _ensureInstallPermission(
        context,
        () => _downloadAndInstall(context, operations, info),
      );
      return;
    }
    await _downloadAndInstall(context, operations, info);
  }

  Future<bool> _ensureInstallPermission(
    BuildContext context,
    Future<void> Function() onGranted,
  ) {
    final i18n = _languageProvider;
    return _permissionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('install_permission_title'),
      message: i18n.tr('install_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('cancel'),
      isGranted: _updateService.canInstallUnknownApps,
      openSettings: _updateService.openInstallPermissionSettings,
      onGranted: onGranted,
    );
  }

  Future<void> _downloadAndInstall(
    BuildContext context,
    UiOperationService operations,
    AppUpdateInfo info,
  ) async {
    final i18n = _languageProvider;
    File updateFile;
    try {
      updateFile = await operations.run<File>(
        scope: UiOperationScope.settingsUpdate,
        labelKey: 'downloading_update',
        task: (progress) => _updateService.downloadUpdate(
          info,
          onProgress: (value) {
            if (value != null) progress.report(value);
          },
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'update_download_or_verification_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      final retry = await _showDownloadFailureDialog(context, info, i18n);
      if (retry == true && context.mounted) {
        unawaited(_downloadAndInstall(context, operations, info));
      }
      return;
    }

    if (!context.mounted) return;
    showAppSnackBar(
      context,
      i18n.tr('update_install_preparing_message', {
        'version': info.latestVersionName,
        'path': updateFile.path,
      }),
      tone: AppFeedbackTone.warning,
      title: i18n.tr('update_install_preparing_title'),
      icon: Icons.system_update_alt_rounded,
      duration: const Duration(seconds: 8),
    );
    await _install(context, operations, updateFile);
  }

  Future<bool?> _showDownloadFailureDialog(
    BuildContext context,
    AppUpdateInfo info,
    AppLanguageProvider i18n,
  ) {
    return showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: i18n.tr('update_download_failed'),
        icon: Icons.error_outline_rounded,
        accentColor: Theme.of(dialogContext).colorScheme.error,
        content: Text(i18n.tr('update_download_failed_next_step')),
        actions: AppDialogActions(
          children: [
            AppSecondaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              label: i18n.tr('close'),
            ),
            AppSecondaryButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
                unawaited(_updateService.openReleasePage(info.releaseUrl));
              },
              label: i18n.tr('open_release_page'),
              icon: Icons.open_in_new_rounded,
            ),
            AppPrimaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              label: i18n.tr('retry'),
              icon: Icons.refresh_rounded,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _install(
    BuildContext context,
    UiOperationService operations,
    File updateFile,
  ) async {
    final i18n = _languageProvider;
    try {
      final result = await _updateService.installUpdate(updateFile);
      if (!context.mounted) return;
      if (result.needsPermission) {
        await _ensureInstallPermission(
          context,
          () => _install(context, operations, updateFile),
        );
        return;
      }
      if (!result.ok) {
        _showInstallFailure(context, i18n, detail: result.message);
        return;
      }
      showAppSnackBar(
        context,
        i18n.tr('update_ready_install'),
        tone: AppFeedbackTone.success,
        icon: Icons.install_mobile_rounded,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'update_install_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) _showInstallFailure(context, i18n);
    }
  }

  void _showInstallFailure(
    BuildContext context,
    AppLanguageProvider i18n, {
    String? detail,
  }) {
    final normalizedDetail = detail?.trim();
    showAppSnackBar(
      context,
      normalizedDetail != null && normalizedDetail.isNotEmpty
          ? i18n.tr('update_install_failed_with_detail', {
              'detail': normalizedDetail,
            })
          : i18n.tr('update_install_failed_next_step'),
      tone: AppFeedbackTone.destructive,
      title: i18n.tr('update_install_failed'),
      icon: Icons.error_outline_rounded,
      duration: const Duration(seconds: 8),
    );
  }
}
