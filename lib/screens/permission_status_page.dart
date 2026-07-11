import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../services/app_update_service.dart';
import '../services/notifications_platform_service.dart';
import '../services/permission_status_service.dart';
import '../services/power_platform_service.dart';
import '../services/subtitle_overlay_controller.dart';
import '../services/ui_operation_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/operation_feedback.dart';

class PermissionStatusPage extends StatefulWidget {
  const PermissionStatusPage({super.key, this.statusService});

  final PermissionStatusService? statusService;

  @override
  State<PermissionStatusPage> createState() => _PermissionStatusPageState();
}

class _PermissionStatusPageState extends State<PermissionStatusPage>
    with WidgetsBindingObserver {
  final _powerService = PowerPlatformService();
  final _notificationsService = NotificationsPlatformService();
  final _operationService = UiOperationService.instance;
  late final PermissionStatusService _statusService;
  late Future<PermissionStatusSnapshot> _snapshot;
  PermissionStatusSnapshot? _lastSnapshot;
  bool _recentlyOpenedSettings = false;

  @override
  void initState() {
    super.initState();
    _statusService =
        widget.statusService ??
        PermissionStatusService(
          powerService: _powerService,
          notificationsService: _notificationsService,
        );
    _snapshot = _loadSnapshot();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      if (_recentlyOpenedSettings) {
        _recentlyOpenedSettings = false;
        Future<void>.delayed(const Duration(milliseconds: 1000), _refresh);
        Future<void>.delayed(const Duration(milliseconds: 2500), _refresh);
      }
    }
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _snapshot = _loadSnapshot());
  }

  Future<PermissionStatusSnapshot> _loadSnapshot() {
    return _operationService.run<PermissionStatusSnapshot>(
      scope: UiOperationScope.settingsPermissionStatus,
      labelKey: 'permission_center',
      task: (_) => _statusService.load(),
      onSuccess: (status) => _lastSnapshot = status,
    );
  }

  Future<void> _open({
    required String title,
    required String description,
    required Future<bool> Function() action,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(i18n.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(i18n.tr('go_settings')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _recentlyOpenedSettings = true;
    final opened = await _operationService.run<bool>(
      scope: UiOperationScope.settingsPermissionStatus,
      labelKey: 'permission_center',
      task: (_) => action(),
    );
    if (!mounted) return;
    if (!opened) {
      _recentlyOpenedSettings = false;
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('system_settings_open_failed'),
        tone: AppFeedbackTone.warning,
        icon: Icons.settings_applications_rounded,
      );
    }
    Future<void>.delayed(const Duration(milliseconds: 800), _refresh);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(i18n.tr('permission_center')),
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
        ),
        body: FutureBuilder<PermissionStatusSnapshot>(
          future: _snapshot,
          builder: (context, snapshot) {
            final status = snapshot.data ?? _lastSnapshot;
            if (status == null) {
              return const OperationSkeletonList(
                itemCount: 6,
                padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
              );
            }
            final checking =
                snapshot.connectionState == ConnectionState.waiting;
            return Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Text(
                      i18n.tr('permission_center_subtitle'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _PermissionSection(
                      title: i18n.tr('permission_group_playback'),
                    ),
                  _PermissionTile(
                    title: i18n.tr('notification_permission_status'),
                    description: i18n.tr('permission_notification_description'),
                    icon: Icons.notifications_rounded,
                    enabled: status.notificationsEnabled,
                    disabledState: _PermissionUiState.restricted,
                    onTap: () => _open(
                      title: i18n.tr('notification_permission_status'),
                      description: i18n.tr(
                        'permission_notification_description',
                      ),
                      action: _notificationsService.openNotificationSettings,
                    ),
                  ),
                  _PermissionTile(
                    title: i18n.tr('allow_background_run'),
                    description: i18n.tr('permission_background_description'),
                    icon: Icons.battery_saver_rounded,
                    enabled: status.backgroundRunAllowed,
                    disabledState: _PermissionUiState.recommended,
                    onTap: () => _open(
                      title: i18n.tr('allow_background_run'),
                      description: i18n.tr('permission_background_description'),
                      action: _powerService.openBackgroundRunSettings,
                    ),
                  ),
                  _PermissionSection(
                    title: i18n.tr('permission_group_reliability'),
                  ),
                  _PermissionTile(
                    title: i18n.tr('exact_alarm_permission_status'),
                    description: i18n.tr('permission_exact_alarm_description'),
                    icon: Icons.alarm_on_rounded,
                    enabled: status.exactAlarmsAllowed,
                    disabledState: _PermissionUiState.recommended,
                    onTap: () => _open(
                      title: i18n.tr('exact_alarm_permission_status'),
                      description: i18n.tr(
                        'permission_exact_alarm_description',
                      ),
                      action: _powerService.openExactAlarmSettings,
                    ),
                  ),
                  _PermissionSection(
                    title: i18n.tr('permission_group_advanced'),
                  ),
                  _PermissionTile(
                    title: i18n.tr('manage_files_permission_title'),
                    description: i18n.tr('permission_manage_files_description'),
                    icon: Icons.folder_open_rounded,
                    enabled: status.manageFilesAllowed,
                    disabledState: _PermissionUiState.unauthorized,
                    onTap: () => _open(
                      title: i18n.tr('manage_files_permission_title'),
                      description: i18n.tr(
                        'permission_manage_files_description',
                      ),
                      action: _powerService.openManageAllFilesAccessSettings,
                    ),
                  ),
                  _PermissionTile(
                    title: i18n.tr('overlay_permission_title'),
                    description: i18n.tr('permission_overlay_description'),
                    icon: Icons.subtitles_rounded,
                    enabled: status.overlayAllowed,
                    disabledState: _PermissionUiState.unauthorized,
                    onTap: () => _open(
                      title: i18n.tr('overlay_permission_title'),
                      description: i18n.tr('permission_overlay_description'),
                      action: SubtitleOverlayController.openOverlaySettings,
                    ),
                  ),
                  _PermissionTile(
                    title: i18n.tr('install_permission_title'),
                    description: i18n.tr(
                      'permission_update_install_description',
                    ),
                    icon: Icons.install_mobile_rounded,
                    enabled: status.updateInstallsAllowed,
                    disabledState: _PermissionUiState.unauthorized,
                    onTap: () => _open(
                      title: i18n.tr('install_permission_title'),
                      description: i18n.tr(
                        'permission_update_install_description',
                      ),
                      action: AppUpdateService.openInstallPermissionSettings,
                    ),
                  ),
                ],
              ),
              if (checking)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

enum _PermissionUiState { authorized, unauthorized, restricted, recommended }

class _PermissionSection extends StatelessWidget {
  const _PermissionSection({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.enabled,
    required this.disabledState,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool enabled;
  final _PermissionUiState disabledState;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final state = enabled ? _PermissionUiState.authorized : disabledState;
    final statusColor = _permissionStateColor(cs, state);
    final statusLabel = _permissionStateLabel(i18n, state);
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHigh.withValues(alpha: 0.6),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        minTileHeight: 82,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: statusColor, size: 22),
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
            description,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.3,
            ),
          ),
        ),
        trailing: Semantics(
          label: statusLabel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              statusLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _permissionStateColor(ColorScheme cs, _PermissionUiState state) {
  switch (state) {
    case _PermissionUiState.authorized:
      return cs.primary;
    case _PermissionUiState.unauthorized:
      return cs.error;
    case _PermissionUiState.restricted:
      return cs.tertiary;
    case _PermissionUiState.recommended:
      return cs.onSurfaceVariant;
  }
}

String _permissionStateLabel(
  AppLanguageProvider i18n,
  _PermissionUiState state,
) {
  return switch (state) {
    _PermissionUiState.authorized => i18n.tr('permission_state_authorized'),
    _PermissionUiState.unauthorized => i18n.tr('permission_state_unauthorized'),
    _PermissionUiState.restricted => i18n.tr('permission_state_restricted'),
    _PermissionUiState.recommended => i18n.tr('permission_state_recommended'),
  };
}
