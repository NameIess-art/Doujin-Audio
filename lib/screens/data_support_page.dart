import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../platform/app_platform.dart';
import '../providers/audio_provider.dart';
import '../services/app_backup_service.dart';
import '../services/app_log_service.dart';
import '../services/diagnostic_report_service.dart';
import '../services/asmr_library_controller.dart';
import '../services/file_cache_platform_gateway.dart';
import '../services/ui_operation_service.dart';
import '../theme/app_design_tokens.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/app_transitions.dart';
import 'onboarding_page.dart';

class DataSupportPage extends StatefulWidget {
  const DataSupportPage({super.key});

  @override
  State<DataSupportPage> createState() => _DataSupportPageState();
}

class _DataSupportPageState extends State<DataSupportPage> {
  final _backupService = AppBackupService();
  final _diagnosticService = DiagnosticReportService();
  final _operationService = UiOperationService.instance;
  final _fileCacheGateway = FileCachePlatformGateway.instance;

  Future<File> _temporaryFile(String name) async {
    final directory = await getTemporaryDirectory();
    final exportDirectory = Directory(path.join(directory.path, 'exports'));
    await exportDirectory.create(recursive: true);
    return File(path.join(exportDirectory.path, name));
  }

  Future<void> _deleteTemporaryFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
      final parent = file.parent;
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'temporary_export_cleanup_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<String?> _saveGeneratedFile({
    required File source,
    required String dialogTitle,
    required List<String> allowedExtensions,
    required String mimeType,
  }) async {
    if (AppPlatform.isAndroid) {
      return _fileCacheGateway.exportFile(
        sourcePath: source.path,
        fileName: path.basename(source.path),
        mimeType: mimeType,
      );
    }
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: path.basename(source.path),
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      lockParentWindow: true,
    );
    if (savedPath == null) return null;
    await source.openRead().pipe(File(savedPath).openWrite());
    return savedPath;
  }

  Future<void> _exportBackup() async {
    final dialogTitle = context.read<AppLanguageProvider>().tr('export_backup');
    await _run(
      scope: UiOperationScope.dataSupportBackupExport,
      labelKey: 'export_backup',
      action: () async {
        final temporary = await _temporaryFile(
          'NamelessAudio-${_timestamp()}.nalbackup',
        );
        try {
          final backup = await _backupService.exportBackup(temporary.path);
          final savedPath = await _saveGeneratedFile(
            source: backup,
            dialogTitle: dialogTitle,
            allowedExtensions: const <String>['nalbackup'],
            mimeType: 'application/zip',
          );
          if (savedPath != null && mounted) {
            _showSuccess(
              'backup_exported',
              titleKey: 'operation_completed',
              detail: savedPath,
              duration: const Duration(seconds: 5),
            );
          }
        } finally {
          await _deleteTemporaryFile(temporary);
        }
      },
    );
  }

  Future<void> _restoreBackup() async {
    final i18n = context.read<AppLanguageProvider>();
    final audioProvider = context.read<AudioProvider>();
    final asmrController = context.read<AsmrLibraryController>();
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
        final selection = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const <String>['nalbackup'],
          lockParentWindow: true,
        );
        final selected = selection?.files.singleOrNull;
        if (selected == null) return;
        try {
          final selectedPath = selected.path;
          if (selectedPath == null || selectedPath.trim().isEmpty) {
            throw const FileSystemException('Selected backup is not readable.');
          }
          final result = await _backupService.restoreBackup(selectedPath);
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
          await audioProvider.reloadPersistedStateAfterBackupRestore();
          await asmrController.reloadPersistedStateAfterBackupRestore();
          if (!mounted) return;
          showAppSnackBar(
            context,
            i18n.tr('backup_restored_loaded'),
            tone: AppFeedbackTone.success,
            title: i18n.tr('operation_completed'),
            icon: Icons.check_circle_outline_rounded,
            duration: const Duration(seconds: 4),
          );
        } finally {
          if (AppPlatform.isAndroid) {
            try {
              await FilePicker.platform.clearTemporaryFiles();
            } catch (error, stackTrace) {
              AppLogService.warning(
                'backup_picker_cache_cleanup_failed',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        }
      },
    );
  }

  Future<void> _exportDiagnostics() async {
    final dialogTitle = context.read<AppLanguageProvider>().tr(
      'export_diagnostics',
    );
    await _run(
      scope: UiOperationScope.dataSupportDiagnosticsExport,
      labelKey: 'export_diagnostics',
      action: () async {
        final temporary = await _temporaryFile(
          'NamelessAudio-diagnostic-${_timestamp()}.zip',
        );
        try {
          final report = await _diagnosticService.exportReport(temporary.path);
          final savedPath = await _saveGeneratedFile(
            source: report,
            dialogTitle: dialogTitle,
            allowedExtensions: const <String>['zip'],
            mimeType: 'application/zip',
          );
          if (savedPath != null && mounted) {
            _showSuccess(
              'diagnostics_exported',
              titleKey: 'operation_completed',
              detail: savedPath,
              duration: const Duration(seconds: 5),
            );
          }
        } finally {
          await _deleteTemporaryFile(temporary);
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
        context.read<AppLanguageProvider>().tr(
          'operation_failed_diagnostics_hint',
        ),
        tone: AppFeedbackTone.destructive,
        title: context.read<AppLanguageProvider>().tr('operation_failed'),
        icon: Icons.error_outline_rounded,
        actionLabel: context.read<AppLanguageProvider>().tr(
          'export_diagnostics',
        ),
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
    final i18n = context.read<AppLanguageProvider>();
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
    final i18n = context.watch<AppLanguageProvider>();
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
        body: StreamBuilder<UiOperationRegistryState>(
          stream: _operationService.stream,
          initialData: _operationService.state,
          builder: (context, snapshot) {
            final operations = snapshot.data ?? UiOperationRegistryState.empty;
            final exportBusy = operations
                .forScope(UiOperationScope.dataSupportBackupExport)
                .isBusy;
            final restoreBusy = operations
                .forScope(UiOperationScope.dataSupportBackupRestore)
                .isBusy;
            final diagnosticsBusy = operations
                .forScope(UiOperationScope.dataSupportDiagnosticsExport)
                .isBusy;
            final dataOperationBusy =
                exportBusy || restoreBusy || diagnosticsBusy;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(
                  i18n.tr('data_and_support_subtitle'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                if (dataOperationBusy) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                _ActionCard(
                  title: i18n.tr('export_backup'),
                  subtitle: i18n.tr('export_backup_subtitle'),
                  icon: Icons.archive_outlined,
                  busy: exportBusy,
                  onTap: dataOperationBusy ? null : _exportBackup,
                ),
                _ActionCard(
                  title: i18n.tr('restore_backup'),
                  subtitle: i18n.tr('restore_backup_subtitle'),
                  icon: Icons.restore_rounded,
                  busy: restoreBusy,
                  onTap: dataOperationBusy ? null : _restoreBackup,
                ),
                _ActionCard(
                  title: i18n.tr('export_diagnostics'),
                  subtitle: i18n.tr('export_diagnostics_subtitle'),
                  icon: Icons.support_agent_rounded,
                  busy: diagnosticsBusy,
                  onTap: dataOperationBusy ? null : _exportDiagnostics,
                ),
                _ActionCard(
                  title: i18n.tr('privacy_summary_title'),
                  subtitle: i18n.tr('privacy_summary_local_body'),
                  icon: Icons.privacy_tip_outlined,
                  onTap: () => Navigator.of(context).push(
                    buildAppPageRoute<void>(child: const PrivacySummaryPage()),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
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
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(tokens.radiusSmall),
          ),
          child: Icon(icon, color: cs.primary, size: 20),
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
