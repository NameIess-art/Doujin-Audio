part of 'main_screen.dart';

extension _MainScreenNotifications on _MainScreenState {
  Future<bool> _areNotificationsEnabled() async {
    return _notificationsPlatformService.areNotificationsEnabled();
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    return _powerPlatformService.isIgnoringBatteryOptimizations();
  }

  Future<void> _openBatteryOptimizationSettings() async {
    await _powerPlatformService.openBatteryOptimizationSettings();
  }

  Future<void> _maybePromptForBackgroundPlaybackReliability() async {
    try {
      if (!mounted ||
          !Platform.isAndroid ||
          _backgroundPlaybackPromptShownThisLaunch) {
        return;
      }
      final diagnostics = await _powerPlatformService
          .getBackgroundRunDiagnostics();
      if (!mounted) return;
      final ignoringBatteryOptimizations =
          diagnostics?.batteryOptimizationExempt ??
          await _isIgnoringBatteryOptimizations();
      if (!mounted || ignoringBatteryOptimizations) {
        _backgroundPlaybackPromptShownThisLaunch = true;
        return;
      }
      _backgroundPlaybackPromptShownThisLaunch = true;
      await _promptOpenBatteryOptimizationSettings();
    } finally {
      _backgroundPlaybackPromptQueued = false;
    }
  }

  Future<void> _promptOpenBatteryOptimizationSettings() async {
    if (!mounted) return;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final openSettings = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('background_play_permission_title'),
      message: i18n.tr('background_play_permission_message'),
      cancelLabel: i18n.tr('later'),
      confirmLabel: i18n.tr('go_settings'),
      icon: Icons.battery_saver_rounded,
      confirmIcon: Icons.settings_rounded,
      isDestructive: false,
    );
    if (openSettings != true) return;
    await _openBatteryOptimizationSettings();
  }

  Future<void> _openNotificationSettings() async {
    final opened = await _notificationsPlatformService
        .openNotificationSettings();
    if (!opened && mounted && Platform.isAndroid) {
      await openAppSettings();
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
        ProviderScope.containerOf(
          context,
          listen: false,
        ).read(appLanguageProviderInstanceProvider),
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
    final notifications = ref.read(notificationFacadeProvider);

    var enabled = await _areNotificationsEnabled();
    if (enabled) return;

    var status = await Permission.notification.status;
    if (status.isGranted) {
      await _promptOpenNotificationSettings();
      return;
    }

    if (status.isDenied) {
      status = await Permission.notification.request();
      if (!mounted) return;
      enabled = await _areNotificationsEnabled();
      if (!mounted) return;
      if (status.isGranted && enabled) {
        notifications.refreshState();
        _showNotificationPermissionEnabledSnack();
        return;
      }
    }

    await _promptOpenNotificationSettings();
  }

  Future<void> _promptOpenNotificationSettings() async {
    if (!mounted || _notificationSettingsDialogVisible) return;
    _notificationSettingsDialogVisible = true;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final openSettings = await showConfirmActionDialog(
      context: context,
      title: _notificationPermissionTitle(i18n),
      message: _notificationPermissionMessage(i18n),
      cancelLabel: _laterLabel(i18n),
      confirmLabel: _openSettingsLabel(i18n),
      icon: Icons.notifications_active_rounded,
      confirmIcon: Icons.settings_rounded,
      isDestructive: false,
    );
    _notificationSettingsDialogVisible = false;
    if (openSettings != true) return;
    _notificationSettingsOpened = true;
    await _openNotificationSettings();
  }

  Future<void> _handleNotificationSettingsReturn() async {
    if (!mounted || !Platform.isAndroid) return;
    final notifications = ref.read(notificationFacadeProvider);
    final enabled = await _areNotificationsEnabled();
    if (!mounted || !enabled) return;
    notifications.refreshState();
    _showNotificationPermissionEnabledSnack();
  }

  Future<void> _consumePendingNotificationSession() async {
    if (!Platform.isAndroid || !mounted) return;
    final sessionId = await _notificationsPlatformService
        .consumePendingNotificationSessionId();
    if (!mounted || sessionId == null || sessionId.isEmpty) {
      return;
    }
    _queueNotificationSessionNavigation(sessionId);
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
    _pendingNotificationSessionStartedAt = now;
    _pendingNotificationSessionRetryCount = 0;
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
    final playback = ref.read(playbackFacadeProvider);
    if (playback.sessionById(sessionId) == null) {
      _pendingNotificationSessionRetryCount++;
      final startedAt = _pendingNotificationSessionStartedAt;
      if (startedAt == null ||
          DateTime.now().difference(startedAt) >= const Duration(seconds: 5)) {
        _notificationSessionNavigationTimer?.cancel();
        _notificationSessionNavigationTimer = null;
        _pendingNotificationSessionId = null;
        _pendingNotificationSessionStartedAt = null;
        final retryCount = _pendingNotificationSessionRetryCount;
        _pendingNotificationSessionRetryCount = 0;
        AppLogService.warning(
          'notification_session_navigation_timeout '
          'sessionId=$sessionId retries=$retryCount',
        );
        return;
      }
      _notificationSessionNavigationTimer?.cancel();
      _notificationSessionNavigationTimer = Timer(
        const Duration(milliseconds: 240),
        _openPendingNotificationSession,
      );
      return;
    }

    _pendingNotificationSessionId = null;
    _pendingNotificationSessionStartedAt = null;
    _pendingNotificationSessionRetryCount = 0;
    _lastOpenedNotificationSessionId = sessionId;
    _lastOpenedNotificationAt = DateTime.now();
    _switchPage(1);
    Navigator.of(context).push(buildSessionDetailRoute(sessionId: sessionId));
  }
}
