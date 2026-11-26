import 'dart:async';

import '../../asmr/presentation/asmr_providers.dart';
import '../../library/presentation/library_providers.dart';
import '../../player/presentation/playback_providers.dart';
import '../../settings/presentation/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_settings_group_card.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/state/listening_activity_provider.dart';
import '../../../app/state/subtitle_settings_provider.dart';
import '../../../core/logging/app_log_service.dart';
import '../application/cross_platform_sync_service.dart';
import '../application/data_backup_service.dart';
import '../application/data_support_file_service.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../app/presentation/onboarding_page.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_settings_action_tile.dart';
import '../../../core/widgets/unified_popup_menu.dart';

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

  Future<void> _openWebDavSyncConfigDialog() async {
    final syncService = ref.read(crossPlatformSyncServiceProvider);
    await syncService.initialize();
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (_) => _WebDavSyncSettingsDialog(syncService: syncService),
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
    await _run(
      scope: UiOperationScope.dataSupportBackupRestore,
      labelKey: 'restore_backup',
      action: () async {
        if (!mounted) return;
        final navigator = Navigator.of(context, rootNavigator: true);
        final syncService = ref.read(crossPlatformSyncServiceProvider);
        final selected = await _fileService.pickBackupFile(
          dialogTitle: i18n.tr('restore_backup'),
        );
        if (selected == null || !mounted) return;

        var dismissProgress = showAppProgressFeedback(
          context,
          i18n.tr('loading_dot'),
          title: i18n.tr('restore_backup'),
          icon: Icons.restore_rounded,
        );
        var progressVisible = true;
        void hideProgress() {
          if (!progressVisible) return;
          progressVisible = false;
          dismissProgress();
        }

        var staged = false;
        try {
          await _fileService.withBackupFilePath<void>(selected, (
            resolvedPath,
          ) async {
            final inspection = await _fileService.inspectBackupPath(
              resolvedPath,
            );
            hideProgress();
            if (!mounted) return;

            final decision = await showAppDialog<_BackupImportDecision>(
              context: context,
              builder: (_) => _BackupImportConfirmDialog(
                inspection: inspection,
              ),
            );
            if (decision == null || !mounted) return;

            dismissProgress = showAppProgressFeedback(
              context,
              i18n.tr('loading_dot'),
              title: i18n.tr('restore_backup'),
              icon: Icons.restore_rounded,
            );
            progressVisible = true;

            if (decision.mode == _BackupImportMode.fullRestore) {
              final playback = ref.read(playbackFacadeProvider).nativeRepository;
              final listeningActivity = ref.read(
                listeningActivityServiceProvider,
              );
              await _fileService.stageRestorePath(resolvedPath);
              staged = true;
              await playback.clearAll();
              await listeningActivity?.refresh(forceReload: false);
              return;
            }

            final mergeResult = await _fileService.mergeBackupPath(
              resolvedPath,
              syncService: syncService,
              syncAccountAndPortableSettings:
                  decision.syncAccountAndPortableSettings,
            );
            if (mergeResult.portableSettingsSynced) {
              await Future.wait<void>([
                ref
                    .read(appLanguageProviderInstanceProvider)
                    .reloadPersistedState(),
                ref.read(themeProviderInstanceProvider).reloadPersistedState(),
                ref
                    .read(subtitleSettingsProvider.notifier)
                    .reloadPersistedState(),
                ref.read(settingsRepositoryProvider).loadPersistedState(),
              ]);
            }
            if (mergeResult.accountSynced ||
                mergeResult.portableSettingsSynced) {
              await ref
                  .read(asmrLibraryControllerProvider)
                  ?.reloadPersistedState();
            }
            hideProgress();
            if (!mounted) return;
            final summary = mergeResult.syncSummary;
            final messageKey =
                (mergeResult.accountSynced ||
                    mergeResult.portableSettingsSynced)
                ? 'backup_merge_completed_with_settings'
                : 'cross_platform_sync_completed';
            showAppSnackBar(
              context,
              i18n.tr(messageKey, {
                'tracks': '${summary.trackStatesMerged}',
                'days': '${summary.listeningDaysUpdated}',
                'segments': '${summary.timeSegmentsMerged}',
              }),
              tone: AppFeedbackTone.success,
              title: i18n.tr('operation_completed'),
              icon: Icons.check_circle_outline_rounded,
              duration: const Duration(seconds: 5),
            );
          });
        } finally {
          hideProgress();
          // A staged backup requires a restart even if playback cleanup fails.
          if (staged && navigator.mounted) {
            final lifecycle = ref.read(appLifecyclePlatformServiceProvider);
            await showAppDialog<void>(
              context: mounted ? context : navigator.context,
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
                        onPressed: () async {
                          final terminated = await lifecycle
                              .terminateForPendingRestore();
                          if (terminated || !dialogContext.mounted) return;
                          showAppSnackBar(
                            dialogContext,
                            i18n.tr('operation_failed_retry'),
                            tone: AppFeedbackTone.destructive,
                            icon: Icons.error_outline_rounded,
                          );
                        },
                        icon: Icons.close_rounded,
                        label: i18n.tr('close_app'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
        }
      },
      retry: _restoreBackup,
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
        task: (_) async {
          await ref.read(audioRuntimeCoordinatorProvider).start();
          await action();
        },
        cancelPrevious: false,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'data_support_operation_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      final formatCode = error is FormatException ? error.message : null;
      final incompatible =
          formatCode == 'incompatible_backup' ||
          formatCode == 'unsupported_database_schema';
      final messageKey = switch (formatCode) {
        'incompatible_backup' ||
        'unsupported_database_schema' => 'backup_incompatible',
        'backup_checksum_mismatch' => 'backup_checksum_mismatch',
        'backup_too_large' => 'backup_too_large',
        'invalid_backup_manifest' ||
        'backup_invalid_manifest' ||
        'invalid_backup_entries' ||
        'invalid_backup_entry_length' ||
        'invalid_preferences_backup' ||
        'invalid_account_backup' ||
        'invalid_database' ||
        'missing_database_tables' ||
        'invalid_database_columns' ||
        'invalid_database_primary_key' ||
        'invalid_database_unique_constraints' => 'backup_invalid_manifest',
        _ => 'operation_failed_diagnostics_hint',
      };
      showAppSnackBar(
        context,
        i18n.tr(messageKey),
        tone: AppFeedbackTone.destructive,
        title: i18n.tr('operation_failed'),
        icon: Icons.error_outline_rounded,
        actionLabel: incompatible || retry == null ? null : i18n.tr('retry'),
        onAction: incompatible ? null : retry,
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
    final displayDetail = detail == null
        ? null
        : PathDisplay.displayPathFor(detail);
    showAppSnackBar(
      context,
      displayDetail == null
          ? i18n.tr(key)
          : i18n.tr(key, {'path': displayDetail}),
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
    final webDavSyncBusy = ref.watch(
      crossPlatformSyncServiceProvider.select((s) => s.isSyncing),
    );
    final webDavSyncSettings = ref.watch(
      crossPlatformSyncServiceProvider.select((s) => s.webDavSettings),
    );
    final dataOperationBusy =
        diagnosticsBusy ||
        backupExportBusy ||
        backupRestoreBusy ||
        webDavSyncBusy;
    return PopScope(
      canPop: !backupRestoreBusy,
      child: Column(
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
                key: const ValueKey('data-support-webdav-sync-config'),
                title: i18n.tr(
                  webDavSyncSettings.isConfigured
                      ? 'cross_platform_sync_webdav_config'
                      : 'cross_platform_sync_webdav_setup',
                ),
                icon: Icons.cloud_sync_outlined,
                busy: webDavSyncBusy,
                onTap: dataOperationBusy ? null : _openWebDavSyncConfigDialog,
              ),
              AppSettingsActionTile(
                key: const ValueKey('data-support-export-diagnostics'),
                title: i18n.tr('export_diagnostics'),
                icon: Icons.bug_report_outlined,
                busy: diagnosticsBusy,
                onTap: dataOperationBusy ? null : _exportDiagnostics,
              ),
              AppSettingsActionTile(
                key: const ValueKey('data-support-privacy-summary'),
                title: i18n.tr('privacy_summary_title'),
                icon: Icons.privacy_tip_outlined,
                onTap: backupRestoreBusy
                    ? null
                    : () => Navigator.of(context).push(
                        buildAppPageRoute<void>(
                          context: context,
                          child: const PrivacySummaryPage(),
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _BackupImportMode { fullRestore, mergeSync }

class _BackupImportDecision {
  const _BackupImportDecision({
    required this.mode,
    this.syncAccountAndPortableSettings = false,
  });

  final _BackupImportMode mode;
  final bool syncAccountAndPortableSettings;
}

class _BackupImportConfirmDialog extends ConsumerStatefulWidget {
  const _BackupImportConfirmDialog({required this.inspection});

  final BackupInspectionResult inspection;

  @override
  ConsumerState<_BackupImportConfirmDialog> createState() =>
      _BackupImportConfirmDialogState();
}

class _BackupImportConfirmDialogState
    extends ConsumerState<_BackupImportConfirmDialog> {
  late _BackupImportMode _mode;
  bool _syncAccountAndPortableSettings = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.inspection.isSamePlatform
        ? _BackupImportMode.fullRestore
        : _BackupImportMode.mergeSync;
  }

  static String _displayPlatform(String raw) => switch (raw.toLowerCase()) {
    'windows' => 'Windows',
    'android' => 'Android',
    _ => raw,
  };

  static String _formatTimestamp(DateTime utcTime) {
    final local = utcTime.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isSamePlatform = widget.inspection.isSamePlatform;
    final isMerge = _mode == _BackupImportMode.mergeSync;
    final accountName = widget.inspection.accountName;

    return AppDialog(
      title: i18n.tr('restore_backup'),
      icon: Icons.restore_rounded,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                i18n.tr('backup_import_source_info', {
                  'platform': _displayPlatform(
                    widget.inspection.manifest.platform,
                  ),
                  'time': _formatTimestamp(
                    widget.inspection.manifest.createdAt,
                  ),
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (isSamePlatform) ...[
                RadioGroup<_BackupImportMode>(
                  groupValue: _mode,
                  onChanged: (next) {
                    if (next != null) setState(() => _mode = next);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<_BackupImportMode>(
                        key: const ValueKey('backup-import-mode-full'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _BackupImportMode.fullRestore,
                        title: Text(i18n.tr('backup_import_mode_full')),
                      ),
                      RadioListTile<_BackupImportMode>(
                        key: const ValueKey('backup-import-mode-merge'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _BackupImportMode.mergeSync,
                        title: Text(i18n.tr('backup_import_mode_merge')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    i18n.tr('backup_import_cross_platform_hint'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Text(
                i18n.tr(
                  isMerge
                      ? 'backup_import_merge_description'
                      : 'restore_backup_warning',
                ),
                style: theme.textTheme.bodyMedium,
              ),
              if (isMerge) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const ValueKey('backup-import-sync-portable-settings'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: _syncAccountAndPortableSettings,
                  onChanged: (v) => setState(
                    () => _syncAccountAndPortableSettings = v ?? false,
                  ),
                  title: Text(i18n.tr('backup_import_sync_account_settings')),
                  subtitle: accountName != null
                      ? Text(
                          i18n.tr('backup_import_account_included', {
                            'account': accountName,
                          }),
                        )
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: AppDialogActions(
        children: [
          AppSecondaryButton(
            onPressed: () => Navigator.of(context).pop(),
            label: i18n.tr('cancel'),
          ),
          AppPrimaryButton(
            key: const ValueKey('backup-import-confirm'),
            onPressed: () => Navigator.of(context).pop(
              _BackupImportDecision(
                mode: _mode,
                syncAccountAndPortableSettings:
                    isMerge && _syncAccountAndPortableSettings,
              ),
            ),
            icon: isMerge ? Icons.sync_rounded : Icons.restore_rounded,
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    );
  }
}

class _WebDavSyncSettingsDialog extends ConsumerStatefulWidget {
  const _WebDavSyncSettingsDialog({required this.syncService});

  final CrossPlatformSyncService syncService;

  @override
  ConsumerState<_WebDavSyncSettingsDialog> createState() =>
      _WebDavSyncSettingsDialogState();
}

class _WebDavSyncSettingsDialogState
    extends ConsumerState<_WebDavSyncSettingsDialog> {
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  final TextEditingController _passwordController = TextEditingController();
  late bool _autoSync;
  bool _obscurePassword = true;
  bool _testing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.syncService.webDavSettings;
    _urlController = TextEditingController(text: cfg.url);
    _usernameController = TextEditingController(text: cfg.username);
    _autoSync = cfg.autoSyncEnabled;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    if (_testing || _saving) return;
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    setState(() => _testing = true);
    try {
      await widget.syncService.testWebDavConnection(
        url: url,
        username: _usernameController.text.trim(),
        password: _passwordController.text.isEmpty
            ? null
            : _passwordController.text,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('remote_source_test_success'),
        tone: AppFeedbackTone.success,
      );
    } on Object {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('remote_source_test_failed'),
        tone: AppFeedbackTone.destructive,
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _testing) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    setState(() => _saving = true);
    try {
      final current = widget.syncService.webDavSettings;
      await widget.syncService.saveWebDavSettings(
        current.copyWith(
          url: _urlController.text.trim(),
          username: _usernameController.text.trim(),
          autoSyncEnabled: _autoSync,
        ),
        password: _passwordController.text.isEmpty
            ? null
            : _passwordController.text,
      );
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('network_invalid_value'),
        tone: AppFeedbackTone.destructive,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final current = widget.syncService.webDavSettings;

    return AppDialog(
      title: i18n.tr('cross_platform_sync_webdav_config'),
      icon: Icons.cloud_sync_outlined,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: _urlController,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: i18n.tr('remote_source_webdav_url'),
                  hintText: 'https://dav.example.com/DoujinAudioSync',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: _usernameController,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: i18n.tr('network_proxy_username'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                contextMenuBuilder: buildAppEditableTextMenu,
                controller: _passwordController,
                obscureText: _obscurePassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: i18n.tr('network_proxy_password'),
                  hintText: current.passwordConfigured
                      ? i18n.tr('network_password_keep')
                      : null,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(i18n.tr('cross_platform_sync_auto')),
                value: _autoSync,
                onChanged: (v) => setState(() => _autoSync = v),
              ),
            ],
          ),
        ),
      ),
      actions: AppDialogActions(
        leading: AppConnectionTestButton(
          tooltip: i18n.tr('network_test'),
          onPressed: _saving ? null : _test,
          isTesting: _testing,
        ),
        children: [
          AppSecondaryButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            label: i18n.tr('cancel'),
          ),
          AppPrimaryButton(
            onPressed: _saving ? null : _save,
            icon: Icons.check_rounded,
            label: i18n.tr('confirm'),
          ),
        ],
      ),
    );
  }
}
