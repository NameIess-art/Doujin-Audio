import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_settings_group_card.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/logging/app_log_service.dart';
import '../application/data_support_file_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../app/presentation/onboarding_page.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_settings_action_tile.dart';

class DataSupportSettingsControls extends ConsumerStatefulWidget {
  const DataSupportSettingsControls({super.key});

  @override
  ConsumerState<DataSupportSettingsControls> createState() =>
      _DataSupportSettingsControlsState();
}

class _DataSupportSettingsControlsState
    extends ConsumerState<DataSupportSettingsControls> {
  UiOperationService get _operationService =>
      ref.read(uiOperationServiceProvider);
  late final DataSupportFileService _fileService;

  @override
  void initState() {
    super.initState();
    _fileService = ref.read(dataSupportFileServiceProvider);
  }

  Future<void> _exportDiagnostics() async {
    final dialogTitle = ref
        .read(appLanguageProviderInstanceProvider)
        .tr('export_diagnostics');
    await _run(
      scope: UiOperationScope.dataSupportDiagnosticsExport,
      labelKey: 'export_diagnostics',
      action: () async {
        final savedPath = await _fileService.exportDiagnostics(
          dialogTitle: dialogTitle,
        );
        if (savedPath != null && mounted) {
          _showSuccess(
            'diagnostics_exported',
            titleKey: 'operation_completed',
            detail: savedPath,
            duration: const Duration(seconds: 5),
          );
        }
      },
    );
  }

  Future<void> _exportBackup() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('export_backup'),
      message: i18n.tr('backup_sensitive_warning'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('confirm'),
      icon: Icons.security_rounded,
    );
    if (!confirmed || !mounted) return;
    await _run(
      scope: UiOperationScope.dataSupportBackupExport,
      labelKey: 'export_backup',
      action: () async {
        final savedPath = await _fileService.exportBackup(
          dialogTitle: i18n.tr('export_backup'),
        );
        if (savedPath != null && mounted) {
          _showSuccess(
            'backup_exported',
            titleKey: 'operation_completed',
            detail: savedPath,
            duration: const Duration(seconds: 5),
          );
        }
      },
      retry: _exportBackup,
    );
  }

  Future<void> _restoreBackup() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('restore_backup'),
      message: i18n.tr('restore_backup_warning'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('select_backup'),
      icon: Icons.restore_rounded,
    );
    if (!confirmed || !mounted) return;
    await _run(
      scope: UiOperationScope.dataSupportBackupRestore,
      labelKey: 'restore_backup',
      action: () async {
        final result = await _fileService.pickAndStageBackup(
          dialogTitle: i18n.tr('restore_backup'),
        );
        if (result == null || !mounted) return;
        await ref.read(playbackFacadeProvider).nativeRepository.clearAll();
        if (!mounted) return;
        await showAppDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => PopScope(
            canPop: false,
            child: AppDialog(
              title: i18n.tr('backup_ready_to_restore'),
              icon: Icons.restart_alt_rounded,
              content: Text(i18n.tr('backup_restart_required')),
              actions: AppDialogActions(
                children: [
                  AppPrimaryButton(
                    onPressed: _terminateForPendingRestore,
                    icon: Icons.close_rounded,
                    label: i18n.tr('close_and_restart'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      retry: _restoreBackup,
    );
  }

  Future<void> _terminateForPendingRestore() async {
    final terminated = await ref
        .read(appLifecyclePlatformServiceProvider)
        .terminateForPendingRestore();
    if (terminated || !mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      i18n.tr('operation_failed_retry'),
      tone: AppFeedbackTone.destructive,
      icon: Icons.error_outline_rounded,
    );
  }

  Future<void> _run({
    required UiOperationScope scope,
    required String labelKey,
    required Future<void> Function() action,
    VoidCallback? retry,
  }) async {
    if (_operationService.operationFor(scope).isBusy) return;
    try {
      await _operationService.run<void>(
        scope: scope,
        labelKey: labelKey,
        task: (_) => action(),
        cancelPrevious: false,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'data_support_operation_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('operation_failed_diagnostics_hint'),
        tone: AppFeedbackTone.destructive,
        title: ref
            .read(appLanguageProviderInstanceProvider)
            .tr('operation_failed'),
        icon: Icons.error_outline_rounded,
        actionLabel: retry == null
            ? null
            : ref.read(appLanguageProviderInstanceProvider).tr('retry'),
        onAction: retry,
        duration: const Duration(seconds: 6),
      );
    }
  }

  void _showSuccess(
    String key, {
    String? titleKey,
    String? detail,
    Duration? duration,
  }) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    showAppSnackBar(
      context,
      detail == null ? i18n.tr(key) : i18n.tr(key, {'path': detail}),
      tone: AppFeedbackTone.success,
      title: titleKey == null ? null : i18n.tr(titleKey),
      icon: Icons.check_circle_outline_rounded,
      duration: duration,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final diagnosticsBusy = ref
        .watch(
          uiOperationForScopeProvider(
            UiOperationScope.dataSupportDiagnosticsExport,
          ),
        )
        .isBusy;
    final backupExportBusy = ref
        .watch(
          uiOperationForScopeProvider(UiOperationScope.dataSupportBackupExport),
        )
        .isBusy;
    final backupRestoreBusy = ref
        .watch(
          uiOperationForScopeProvider(
            UiOperationScope.dataSupportBackupRestore,
          ),
        )
        .isBusy;
    final dataOperationBusy =
        diagnosticsBusy || backupExportBusy || backupRestoreBusy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 4,
          child: dataOperationBusy ? const LinearProgressIndicator() : null,
        ),
        AppSettingsGroupCard(
          children: [
            AppSettingsActionTile(
              key: const ValueKey('data-support-export-backup'),
              title: i18n.tr('export_backup'),
              icon: Icons.archive_outlined,
              busy: backupExportBusy,
              onTap: dataOperationBusy ? null : _exportBackup,
            ),
            AppSettingsActionTile(
              key: const ValueKey('data-support-restore-backup'),
              title: i18n.tr('restore_backup'),
              icon: Icons.settings_backup_restore_rounded,
              busy: backupRestoreBusy,
              onTap: dataOperationBusy ? null : _restoreBackup,
            ),
            AppSettingsActionTile(
              key: const ValueKey('data-support-export-diagnostics'),
              title: i18n.tr('export_diagnostics'),
              icon: Icons.support_agent_rounded,
              busy: diagnosticsBusy,
              onTap: dataOperationBusy ? null : _exportDiagnostics,
            ),
            AppSettingsActionTile(
              key: const ValueKey('data-support-privacy-summary'),
              title: i18n.tr('privacy_summary_title'),
              icon: Icons.privacy_tip_outlined,
              onTap: () => Navigator.of(context).push(
                buildAppPageRoute<void>(
                  context: context,
                  child: const PrivacySummaryPage(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
