import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/logging/app_log_service.dart';
import '../application/data_support_file_service.dart';
import '../../library/presentation/library_scan_feedback.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../app/presentation/onboarding_page.dart';

class DataSupportPage extends ConsumerStatefulWidget {
  const DataSupportPage({super.key});

  @override
  ConsumerState<DataSupportPage> createState() => _DataSupportPageState();
}

class _DataSupportPageState extends ConsumerState<DataSupportPage> {
  UiOperationService get _operationService =>
      ref.read(uiOperationServiceProvider);
  late final DataSupportFileService _fileService;

  @override
  void initState() {
    super.initState();
    _fileService = ref.read(dataSupportFileServiceProvider);
  }

  Future<void> _exportBackup() async {
    final dialogTitle = ref
        .read(appLanguageProviderInstanceProvider)
        .tr('export_backup');
    await _run(
      scope: UiOperationScope.dataSupportBackupExport,
      labelKey: 'export_backup',
      action: () async {
        final savedPath = await ref
            .read(backupRestoreCoordinatorProvider)
            .exportBackup(dialogTitle: dialogTitle);
        if (savedPath != null && mounted) {
          _showSuccess(
            'backup_exported',
            titleKey: 'operation_completed',
            detail: savedPath,
            duration: const Duration(seconds: 5),
          );
        }
      },
    );
  }

  Future<void> _restoreBackup() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('restore_backup'),
      message: i18n.tr('restore_backup_confirm'),
      confirmLabel: i18n.tr('restore'),
      cancelLabel: i18n.tr('cancel'),
      icon: Icons.restore_rounded,
    );
    if (!confirmed) return;

    await _run(
      scope: UiOperationScope.dataSupportBackupRestore,
      labelKey: 'restore_backup',
      action: () async {
        final result = await ref
            .read(backupRestoreCoordinatorProvider)
            .pickAndRestoreBackup(
              labels: LibraryScanPresentationMapper.labels(i18n),
            );
        if (result == null) return;
        if (result.isCancelled) return;
        if (!result.isValid) {
          if (!mounted) return;
          showAppSnackBar(
            context,
            i18n.tr('backup_invalid_next_step'),
            tone: AppFeedbackTone.destructive,
            title: i18n.tr('backup_invalid'),
            icon: Icons.error_outline_rounded,
            actionLabel: i18n.tr('export_diagnostics'),
            onAction: _exportDiagnostics,
            duration: const Duration(seconds: 6),
          );
          return;
        }
        if (!mounted) return;
        showAppSnackBar(
          context,
          i18n.tr('backup_restored_loaded'),
          tone: AppFeedbackTone.success,
          title: i18n.tr('operation_completed'),
          icon: Icons.check_circle_outline_rounded,
          duration: const Duration(seconds: 4),
        );
      },
    );
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

  Future<void> _run({
    required UiOperationScope scope,
    required String labelKey,
    required Future<void> Function() action,
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
        actionLabel: ref
            .read(appLanguageProviderInstanceProvider)
            .tr('export_diagnostics'),
        onAction: _exportDiagnostics,
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
    final exportBusy = ref
        .watch(
          uiOperationForScopeProvider(UiOperationScope.dataSupportBackupExport),
        )
        .isBusy;
    final restoreBusy = ref
        .watch(
          uiOperationForScopeProvider(
            UiOperationScope.dataSupportBackupRestore,
          ),
        )
        .isBusy;
    final diagnosticsBusy = ref
        .watch(
          uiOperationForScopeProvider(
            UiOperationScope.dataSupportDiagnosticsExport,
          ),
        )
        .isBusy;
    final dataOperationBusy = exportBusy || restoreBusy || diagnosticsBusy;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(i18n.tr('data_and_support')),
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(
              i18n.tr('data_and_support_subtitle'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 4,
              child: dataOperationBusy ? const LinearProgressIndicator() : null,
            ),
            const SizedBox(height: 8),
            _ActionCard(
              key: const ValueKey('data-support-export-backup'),
              title: i18n.tr('export_backup'),
              subtitle: i18n.tr('export_backup_subtitle'),
              icon: Icons.archive_outlined,
              busy: exportBusy,
              onTap: dataOperationBusy ? null : _exportBackup,
            ),
            _ActionCard(
              key: const ValueKey('data-support-restore-backup'),
              title: i18n.tr('restore_backup'),
              subtitle: i18n.tr('restore_backup_subtitle'),
              icon: Icons.restore_rounded,
              busy: restoreBusy,
              onTap: dataOperationBusy ? null : _restoreBackup,
            ),
            _ActionCard(
              key: const ValueKey('data-support-export-diagnostics'),
              title: i18n.tr('export_diagnostics'),
              subtitle: i18n.tr('export_diagnostics_subtitle'),
              icon: Icons.support_agent_rounded,
              busy: diagnosticsBusy,
              onTap: dataOperationBusy ? null : _exportDiagnostics,
            ),
            _ActionCard(
              key: const ValueKey('data-support-privacy-summary'),
              title: i18n.tr('privacy_summary_title'),
              subtitle: i18n.tr('privacy_summary_local_body'),
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
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.busy = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 76,
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: tokens.iconContainerSize,
          height: tokens.iconContainerSize,
          alignment: Alignment.center,
          child: Icon(icon, color: cs.onSurface, size: 20),
        ),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ),
        trailing: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
      ),
    );
  }
}
