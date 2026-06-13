import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../services/app_backup_service.dart';
import '../services/app_log_service.dart';
import '../services/diagnostic_report_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';

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
      if (savedPath != null && mounted) _showSuccess('backup_exported');
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
          i18n.tr('backup_invalid'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      showAppSnackBar(
        context,
        i18n.tr('backup_restored_restart'),
        tone: AppFeedbackTone.success,
        icon: Icons.restart_alt_rounded,
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
      if (savedPath != null && mounted) _showSuccess('diagnostics_exported');
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
        context.read<AppLanguageProvider>().tr('operation_failed_retry'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSuccess(String key) {
    showAppSnackBar(
      context,
      context.read<AppLanguageProvider>().tr(key),
      tone: AppFeedbackTone.success,
      icon: Icons.check_circle_outline_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('data_and_support'))),
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
        ],
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
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        minTileHeight: 72,
        onTap: onTap,
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
