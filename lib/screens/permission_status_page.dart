import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../services/app_update_service.dart';
import '../services/notifications_platform_service.dart';
import '../services/permission_status_service.dart';
import '../services/power_platform_service.dart';
import '../services/subtitle_overlay_controller.dart';
import '../widgets/app_feedback.dart';

class PermissionStatusPage extends StatefulWidget {
  const PermissionStatusPage({super.key});

  @override
  State<PermissionStatusPage> createState() => _PermissionStatusPageState();
}

class _PermissionStatusPageState extends State<PermissionStatusPage>
    with WidgetsBindingObserver {
  final _powerService = PowerPlatformService();
  final _notificationsService = NotificationsPlatformService();
  late final PermissionStatusService _statusService = PermissionStatusService(
    powerService: _powerService,
    notificationsService: _notificationsService,
  );
  late Future<PermissionStatusSnapshot> _snapshot = _statusService.load();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _snapshot = _statusService.load());
  }

  Future<void> _open(Future<bool> Function() action) async {
    final opened = await action();
    if (!mounted) return;
    if (!opened) {
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr('system_settings_open_failed'),
        tone: AppFeedbackTone.warning,
        icon: Icons.settings_applications_rounded,
      );
    }
    Future<void>.delayed(const Duration(milliseconds: 600), _refresh);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('permission_center'))),
      body: FutureBuilder<PermissionStatusSnapshot>(
        future: _snapshot,
        builder: (context, snapshot) {
          final status = snapshot.data;
          if (status == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(
                  i18n.tr('permission_center_subtitle'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                _PermissionTile(
                  title: i18n.tr('notification_permission_status'),
                  description: i18n.tr('permission_notification_description'),
                  icon: Icons.notifications_rounded,
                  enabled: status.notificationsEnabled,
                  onTap: () =>
                      _open(_notificationsService.openNotificationSettings),
                ),
                _PermissionTile(
                  title: i18n.tr('allow_background_run'),
                  description: i18n.tr('permission_background_description'),
                  icon: Icons.battery_saver_rounded,
                  enabled: status.backgroundRunAllowed,
                  onTap: () => _open(_powerService.openBackgroundRunSettings),
                ),
                _PermissionTile(
                  title: i18n.tr('exact_alarm_permission_status'),
                  description: i18n.tr('permission_exact_alarm_description'),
                  icon: Icons.alarm_on_rounded,
                  enabled: status.exactAlarmsAllowed,
                  onTap: () => _open(_powerService.openExactAlarmSettings),
                ),
                _PermissionTile(
                  title: i18n.tr('manage_files_permission_title'),
                  description: i18n.tr('permission_manage_files_description'),
                  icon: Icons.folder_open_rounded,
                  enabled: status.manageFilesAllowed,
                  onTap: () =>
                      _open(_powerService.openManageAllFilesAccessSettings),
                ),
                _PermissionTile(
                  title: i18n.tr('overlay_permission_title'),
                  description: i18n.tr('permission_overlay_description'),
                  icon: Icons.subtitles_rounded,
                  enabled: status.overlayAllowed,
                  onTap: () =>
                      _open(SubtitleOverlayController.openOverlaySettings),
                ),
                _PermissionTile(
                  title: i18n.tr('install_permission_title'),
                  description: i18n.tr('permission_update_install_description'),
                  icon: Icons.install_mobile_rounded,
                  enabled: status.updateInstallsAllowed,
                  onTap: () =>
                      _open(AppUpdateService.openInstallPermissionSettings),
                ),
              ],
            ),
          );
        },
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
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final statusColor = enabled ? Colors.green : cs.error;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        minTileHeight: 72,
        leading: Icon(icon, color: cs.primary),
        title: Text(title),
        subtitle: Text(description),
        trailing: Tooltip(
          message: i18n.tr('go_settings'),
          child: Icon(
            enabled ? Icons.check_circle_rounded : Icons.warning_rounded,
            color: statusColor,
            semanticLabel: enabled
                ? i18n.tr('permission_enabled')
                : i18n.tr('permission_not_enabled'),
          ),
        ),
      ),
    );
  }
}
