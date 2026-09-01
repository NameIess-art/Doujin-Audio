import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/presentation/app_settings_group_card.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_settings_action_tile.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../application/permission_status_service.dart';

class PermissionSettingsControls extends ConsumerStatefulWidget {
  const PermissionSettingsControls({super.key, this.statusService});

  final PermissionStatusService? statusService;

  @override
  ConsumerState<PermissionSettingsControls> createState() =>
      _PermissionSettingsControlsState();
}

class _PermissionSettingsControlsState
    extends ConsumerState<PermissionSettingsControls>
    with WidgetsBindingObserver {
  late final PermissionStatusService _statusService;
  Future<PermissionStatusSnapshot>? _statusRequest;
  PermissionStatusSnapshot? _status;
  bool _recentlyOpenedSettings = false;

  @override
  void initState() {
    super.initState();
    _statusService =
        widget.statusService ?? ref.read(permissionStatusServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _refreshStatus();
    if (_recentlyOpenedSettings) {
      _recentlyOpenedSettings = false;
      Future<void>.delayed(const Duration(seconds: 1), _refreshStatus);
      Future<void>.delayed(const Duration(milliseconds: 2500), _refreshStatus);
    }
  }

  Future<void> _refreshStatus() async {
    if (!mounted) return;
    final request = _statusService.load();
    setState(() {
      _statusRequest = request;
    });
    final status = await request;
    if (!mounted || !identical(_statusRequest, request)) return;
    setState(() => _status = status);
  }

  Future<void> _open({
    required String title,
    required String description,
    required PermissionCapability capability,
  }) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: title,
      message: description,
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('go_settings'),
      icon: Icons.admin_panel_settings_outlined,
      confirmIcon: Icons.settings_rounded,
      isDestructive: false,
    );
    if (!confirmed) return;

    _recentlyOpenedSettings = true;
    final opened = await ref
        .read(uiOperationServiceProvider)
        .run<bool>(
          scope: UiOperationScope.settingsPermissionStatus,
          labelKey: 'settings_group_permissions',
          task: (_) => _statusService.openSettings(capability),
        );
    if (!mounted) return;
    if (!opened) {
      _recentlyOpenedSettings = false;
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('system_settings_open_failed'),
        tone: AppFeedbackTone.warning,
        icon: Icons.settings_applications_rounded,
      );
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 800), _refreshStatus);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return AppSettingsGroupCard(
      children: [
        _PermissionActionTile(
          title: i18n.tr('notification_permission_status'),
          description: i18n.tr('permission_notification_description'),
          icon: Icons.notifications_rounded,
          enabled: _enabled(PermissionCapability.notifications),
          enabledLabel: i18n.tr('permission_enabled'),
          disabledLabel: i18n.tr('permission_not_enabled'),
          onTap: () => _open(
            title: i18n.tr('notification_permission_status'),
            description: i18n.tr('permission_notification_description'),
            capability: PermissionCapability.notifications,
          ),
        ),
        _PermissionActionTile(
          title: i18n.tr('allow_background_run'),
          description: i18n.tr('permission_background_description'),
          icon: Icons.battery_saver_rounded,
          enabled: _enabled(PermissionCapability.backgroundRun),
          enabledLabel: i18n.tr('permission_enabled'),
          disabledLabel: i18n.tr('permission_not_enabled'),
          onTap: () => _open(
            title: i18n.tr('allow_background_run'),
            description: i18n.tr('permission_background_description'),
            capability: PermissionCapability.backgroundRun,
          ),
        ),
        _PermissionActionTile(
          title: i18n.tr('exact_alarm_permission_status'),
          description: i18n.tr('permission_exact_alarm_description'),
          icon: Icons.alarm_on_rounded,
          enabled: _enabled(PermissionCapability.exactAlarms),
          enabledLabel: i18n.tr('permission_enabled'),
          disabledLabel: i18n.tr('permission_not_enabled'),
          onTap: () => _open(
            title: i18n.tr('exact_alarm_permission_status'),
            description: i18n.tr('permission_exact_alarm_description'),
            capability: PermissionCapability.exactAlarms,
          ),
        ),
        _PermissionActionTile(
          title: i18n.tr('manage_files_permission_title'),
          description: i18n.tr('permission_manage_files_description'),
          icon: Icons.folder_open_rounded,
          enabled: _enabled(PermissionCapability.manageFiles),
          enabledLabel: i18n.tr('permission_enabled'),
          disabledLabel: i18n.tr('permission_not_enabled'),
          onTap: () => _open(
            title: i18n.tr('manage_files_permission_title'),
            description: i18n.tr('permission_manage_files_description'),
            capability: PermissionCapability.manageFiles,
          ),
        ),
        _PermissionActionTile(
          title: i18n.tr('overlay_permission_title'),
          description: i18n.tr('permission_overlay_description'),
          icon: Icons.subtitles_rounded,
          enabled: _enabled(PermissionCapability.overlay),
          enabledLabel: i18n.tr('permission_enabled'),
          disabledLabel: i18n.tr('permission_not_enabled'),
          onTap: () => _open(
            title: i18n.tr('overlay_permission_title'),
            description: i18n.tr('permission_overlay_description'),
            capability: PermissionCapability.overlay,
          ),
        ),
        _PermissionActionTile(
          title: i18n.tr('install_permission_title'),
          description: i18n.tr('permission_update_install_description'),
          icon: Icons.install_mobile_rounded,
          enabled: _enabled(PermissionCapability.updateInstalls),
          enabledLabel: i18n.tr('permission_enabled'),
          disabledLabel: i18n.tr('permission_not_enabled'),
          onTap: () => _open(
            title: i18n.tr('install_permission_title'),
            description: i18n.tr('permission_update_install_description'),
            capability: PermissionCapability.updateInstalls,
          ),
        ),
      ],
    );
  }

  bool? _enabled(PermissionCapability capability) {
    final status = _status;
    if (status == null) return null;
    return switch (capability) {
      PermissionCapability.notifications => status.notificationsEnabled,
      PermissionCapability.backgroundRun => status.backgroundRunAllowed,
      PermissionCapability.exactAlarms => status.exactAlarmsAllowed,
      PermissionCapability.manageFiles => status.manageFilesAllowed,
      PermissionCapability.overlay => status.overlayAllowed,
      PermissionCapability.updateInstalls => status.updateInstallsAllowed,
    };
  }
}

class _PermissionActionTile extends StatelessWidget {
  const _PermissionActionTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.enabled,
    required this.enabledLabel,
    required this.disabledLabel,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool? enabled;
  final String enabledLabel;
  final String disabledLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppSettingsActionTile(
      title: title,
      icon: icon,
      onTap: onTap,
      trailing: _PermissionStatusButton(
        enabled: enabled,
        enabledLabel: enabledLabel,
        disabledLabel: disabledLabel,
        onPressed: onTap,
      ),
    );
  }
}

class _PermissionStatusButton extends StatelessWidget {
  const _PermissionStatusButton({
    required this.enabled,
    required this.enabledLabel,
    required this.disabledLabel,
    required this.onPressed,
  });

  final bool? enabled;
  final String enabledLabel;
  final String disabledLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (enabled == null) {
      return const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final color = enabled! ? AppDesignTokens.of(context).success : cs.error;
    final label = enabled! ? enabledLabel : disabledLabel;
    return Semantics(
      button: true,
      label: label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: color,
          backgroundColor: color.withValues(alpha: 0.12),
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: const StadiumBorder(),
          textStyle: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        child: Text(label),
      ),
    );
  }
}
