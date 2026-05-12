part of 'main_screen.dart';

extension _MainScreenNotifications on _MainScreenState {
  Future<bool> _areNotificationsEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _MainScreenState._notificationsChannel.invokeMethod<bool>(
            NotificationsMethod.areNotificationsEnabled,
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _MainScreenState._powerChannel.invokeMethod<bool>(
            PowerMethod.isIgnoringBatteryOptimizations,
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _MainScreenState._powerChannel.invokeMethod<bool>(
        PowerMethod.openBatteryOptimizationSettings,
      );
    } catch (_) {}
  }

  Future<void> _maybeEnableBackgroundKeepAliveOnFirstLaunch() async {
    if (!mounted || !Platform.isAndroid) return;
    final initialized =
        await AppPreferences.getBool(
          _MainScreenState._backgroundKeepAliveInitializedKey,
        ) ??
        false;
    if (initialized) return;
    await AppPreferences.setBool(
      _MainScreenState._backgroundKeepAliveInitializedKey,
      true,
    );
    final ignoringBatteryOptimizations =
        await _isIgnoringBatteryOptimizations();
    if (!mounted || ignoringBatteryOptimizations) return;
    await _promptOpenBatteryOptimizationSettings();
  }

  Future<void> _promptOpenBatteryOptimizationSettings() async {
    if (!mounted) return;
    final i18n = context.read<AppLanguageProvider>();
    final openSettings = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('background_play_permission_title'),
      message: i18n.tr('background_play_permission_message'),
      cancelLabel: i18n.tr('later'),
      confirmLabel: i18n.tr('go_settings'),
      icon: Icons.battery_saver_rounded,
    );
    if (openSettings != true) return;
    await _openBatteryOptimizationSettings();
  }

  Future<void> _openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      final opened =
          await _MainScreenState._notificationsChannel.invokeMethod<bool>(
            NotificationsMethod.openNotificationSettings,
          ) ??
          false;
      if (!opened && mounted) {
        await openAppSettings();
      }
    } catch (_) {
      if (mounted) {
        await openAppSettings();
      }
    }
  }

  String _notificationPermissionTitle(AppLanguageProvider i18n) {
    return i18n.tr('notification_permission_title');
  }

  String _notificationPermissionMessage(AppLanguageProvider i18n) {
    return i18n.tr('notification_permission_message');
  }

  String _notificationPermissionEnabledMessage(AppLanguageProvider i18n) {
    return i18n.tr('notification_permission_enabled');
  }

  String _openSettingsLabel(AppLanguageProvider i18n) {
    return i18n.tr('go_settings');
  }

  String _laterLabel(AppLanguageProvider i18n) {
    return i18n.tr('later');
  }

  void _showNotificationPermissionEnabledSnack() {
    showAppSnackBar(
      context,
      _notificationPermissionEnabledMessage(
        context.read<AppLanguageProvider>(),
      ),
      tone: AppFeedbackTone.success,
      icon: Icons.notifications_active_rounded,
    );
  }

  Future<void> _ensureNotificationPermission() async {
    _notificationPermissionCheckQueued = false;
    if (_notificationPermissionCheckDone || !Platform.isAndroid || !mounted) {
      return;
    }
    _notificationPermissionCheckDone = true;
    final provider = ref.read(audioProviderFacadeProvider);

    var enabled = await _areNotificationsEnabled();
    if (enabled) return;

    var status = await Permission.notification.status;
    if (status.isGranted) {
      await _promptOpenNotificationSettings();
      return;
    }

    if (status.isDenied) {
      status = await Permission.notification.request();
      if (!context.mounted) return;
      enabled = await _areNotificationsEnabled();
      if (!context.mounted) return;
      if (status.isGranted && enabled) {
        provider.refreshNotificationState();
        _showNotificationPermissionEnabledSnack();
        return;
      }
    }

    await _promptOpenNotificationSettings();
  }

  Future<void> _promptOpenNotificationSettings() async {
    if (!mounted || _notificationSettingsDialogVisible) return;
    _notificationSettingsDialogVisible = true;
    final i18n = context.read<AppLanguageProvider>();
    final openSettings = await showConfirmActionDialog(
      context: context,
      title: _notificationPermissionTitle(i18n),
      message: _notificationPermissionMessage(i18n),
      cancelLabel: _laterLabel(i18n),
      confirmLabel: _openSettingsLabel(i18n),
      icon: Icons.notifications_active_rounded,
    );
    _notificationSettingsDialogVisible = false;
    if (openSettings != true) return;
    _notificationSettingsOpened = true;
    await _openNotificationSettings();
  }

  Future<void> _handleNotificationSettingsReturn() async {
    if (!mounted || !Platform.isAndroid) return;
    final audioProvider = ref.read(audioProviderFacadeProvider);
    final enabled = await _areNotificationsEnabled();
    if (!mounted || !enabled) return;
    audioProvider.refreshNotificationState();
    _showNotificationPermissionEnabledSnack();
  }

  Future<dynamic> _handleNotificationsChannelCall(MethodCall call) async {
    switch (call.method) {
      case NotificationsMethod.openSessionFromNotification:
        final args = call.arguments;
        String? sessionId;
        if (args is Map) {
          sessionId = args['sessionId'] as String?;
        } else if (args is String) {
          sessionId = args;
        }
        if (sessionId != null && sessionId.isNotEmpty) {
          _queueNotificationSessionNavigation(sessionId);
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> _consumePendingNotificationSession() async {
    if (!Platform.isAndroid || !mounted) return;
    try {
      final sessionId = await _MainScreenState._notificationsChannel
          .invokeMethod<String>(NotificationsMethod.consumePendingNotificationSessionId);
      if (!mounted || sessionId == null || sessionId.isEmpty) {
        return;
      }
      _queueNotificationSessionNavigation(sessionId);
    } catch (_) {}
  }

  void _queueNotificationSessionNavigation(String sessionId) {
    final now = DateTime.now();
    if (_lastOpenedNotificationSessionId == sessionId &&
        _lastOpenedNotificationAt != null &&
        now.difference(_lastOpenedNotificationAt!) <
            const Duration(milliseconds: 800)) {
      return;
    }
    _pendingNotificationSessionId = sessionId;
    _notificationSessionNavigationTimer?.cancel();
    _notificationSessionNavigationTimer = Timer(
      const Duration(milliseconds: 60),
      _openPendingNotificationSession,
    );
  }

  void _openPendingNotificationSession() {
    if (!mounted) return;
    final sessionId = _pendingNotificationSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    final playbackService = ref.read(playbackSessionServiceProvider);
    if (playbackService.sessionById(sessionId) == null) {
      _notificationSessionNavigationTimer?.cancel();
      _notificationSessionNavigationTimer = Timer(
        const Duration(milliseconds: 240),
        _openPendingNotificationSession,
      );
      return;
    }

    _pendingNotificationSessionId = null;
    _lastOpenedNotificationSessionId = sessionId;
    _lastOpenedNotificationAt = DateTime.now();
    _switchPage(1, withFeedback: false);
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: sessionId));
  }
}
