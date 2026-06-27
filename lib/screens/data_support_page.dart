import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/app_backup_service.dart';
import '../services/app_log_service.dart';
import '../services/diagnostic_report_service.dart';
import '../services/asmr_library_controller.dart';
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
  bool _busy = false;

  Future<File> _temporaryFile(String name) async {
    final directory = await getTemporaryDirectory();
    final exportDirectory = Directory(path.join(directory.path, 'exports'));
    await exportDirectory.create(recursive: true);
    return File(path.join(exportDirectory.path, name));
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<void> _exportBackup() async {
    final dialogTitle = context.read<AppLanguageProvider>().tr('export_backup');
    await _run(() async {
      final temporary = await _temporaryFile(
        'NamelessAudio-${_timestamp()}.nalbackup',
      );
      final backup = await _backupService.exportBackup(temporary.path);
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: path.basename(backup.path),
        type: FileType.custom,
        allowedExtensions: const <String>['nalbackup'],
        bytes: await backup.readAsBytes(),
        lockParentWindow: true,
      );
      if (savedPath != null && mounted) {
        _showSuccess(
          'backup_exported',
          titleKey: 'operation_completed',
          detail: savedPath,
          duration: const Duration(seconds: 5),
        );
      }
    });
  }

  Future<void> _restoreBackup() async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('restore_backup'),
      message: i18n.tr('restore_backup_confirm'),
      confirmLabel: i18n.tr('restore'),
      cancelLabel: i18n.tr('cancel'),
      icon: Icons.restore_rounded,
    );
    if (!confirmed) return;

    await _run(() async {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['nalbackup'],
        withData: true,
        lockParentWindow: true,
      );
      final selected = selection?.files.singleOrNull;
      if (selected == null) return;
      final temporary = await _temporaryFile(
        'restore-${_timestamp()}.nalbackup',
      );
      final bytes = selected.bytes;
      if (bytes != null) {
        await temporary.writeAsBytes(bytes, flush: true);
      } else if (selected.path != null) {
        await File(selected.path!).copy(temporary.path);
      } else {
        throw const FileSystemException('Selected backup is not readable.');
      }

      final result = await _backupService.restoreBackup(temporary.path);
      if (!mounted) return;
      if (!result.isValid) {
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
      await context
          .read<AudioProvider>()
          .reloadPersistedStateAfterBackupRestore();
      if (!mounted) return;
      await context
          .read<AsmrLibraryController>()
          .reloadPersistedStateAfterBackupRestore();
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('backup_restored_loaded'),
        tone: AppFeedbackTone.success,
        title: i18n.tr('operation_completed'),
        icon: Icons.check_circle_outline_rounded,
        duration: const Duration(seconds: 4),
      );
    });
  }

  Future<void> _exportDiagnostics() async {
    final dialogTitle = context.read<AppLanguageProvider>().tr(
      'export_diagnostics',
    );
    await _run(() async {
      final temporary = await _temporaryFile(
        'NamelessAudio-diagnostic-${_timestamp()}.zip',
      );
      final report = await _diagnosticService.exportReport(temporary.path);
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: path.basename(report.path),
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
        bytes: await report.readAsBytes(),
        lockParentWindow: true,
      );
      if (savedPath != null && mounted) {
        _showSuccess(
          'diagnostics_exported',
          titleKey: 'operation_completed',
          detail: savedPath,
          duration: const Duration(seconds: 5),
        );
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
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
    } finally {
      if (mounted) setState(() => _busy = false);
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
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            _ActionCard(
              title: i18n.tr('export_backup'),
              subtitle: i18n.tr('export_backup_subtitle'),
              icon: Icons.archive_outlined,
              onTap: _busy ? null : _exportBackup,
            ),
            _ActionCard(
              title: i18n.tr('restore_backup'),
              subtitle: i18n.tr('restore_backup_subtitle'),
              icon: Icons.restore_rounded,
              onTap: _busy ? null : _restoreBackup,
            ),
            _ActionCard(
              title: i18n.tr('export_diagnostics'),
              subtitle: i18n.tr('export_diagnostics_subtitle'),
              icon: Icons.support_agent_rounded,
              onTap: _busy ? null : _exportDiagnostics,
            ),
            _ActionCard(
              title: i18n.tr('privacy_summary_title'),
              subtitle: i18n.tr('privacy_summary_local_body'),
              icon: Icons.privacy_tip_outlined,
              onTap: _busy
                  ? null
                  : () => Navigator.of(context).push(
                      buildAppPageRoute<void>(
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
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 76,
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: cs.primary, size: 22),
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
        trailing: Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
      ),
    );
  }
}
