import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/subtitle_settings_provider.dart';
import '../services/app_update_service.dart';
import '../services/app_preferences.dart';
import '../services/app_log_service.dart';
import '../services/notifications_platform_service.dart';
import '../services/permission_action_controller.dart';
import '../services/power_platform_service.dart';
import '../services/subtitle_overlay_controller.dart';
import '../services/ui_interaction_coordinator.dart';
import 'asmr_tab.dart';
import 'library_tab.dart';
import 'playlist_tab.dart';
import 'settings_tab.dart';
import 'timer_tab.dart';
import '../widgets/active_session_carousel.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_transitions.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/windows_title_bar.dart';

part 'main_screen_notifications.dart';
part 'main_screen_layout.dart';
part 'main_screen_widgets.dart';
part 'main_screen_timer_scrim.dart';

@visibleForTesting
bool shouldRunGlobalSubtitleOverlay({
  required bool appInForeground,
  required bool isWindows,
}) {
  return isWindows || !appInForeground;
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  static const double _desktopBreakpoint = 980;
  final PowerPlatformService _powerPlatformService = PowerPlatformService();
  final NotificationsPlatformService _notificationsPlatformService =
      NotificationsPlatformService();

  int _currentIndex = 1;
  bool _isMenuCollapsed = false;
  late final List<Widget> _pages;
  final Set<int> _visitedPageIndices = <int>{};
  final Object _pageSwitchInteraction = Object();
  final GlobalKey _bottomDockKey = GlobalKey();
  final GlobalKey _dockContentKey = GlobalKey();

  bool _notificationPermissionCheckDone = false;
  bool _notificationPermissionCheckQueued = false;
  bool _notificationSettingsDialogVisible = false;
  bool _notificationSettingsOpened = false;
  bool _backgroundPlaybackPromptShownThisLaunch = false;
  bool _backgroundPlaybackPromptQueued = false;
  bool _autoUpdateCheckQueued = false;
  bool _autoUpdateCheckRunning = false;
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  bool _timerOverlayPrimed = false;

  bool _bootstrapDone = false;
  bool _isDataReady = false;
  bool? _lastShowCard;
  Timer? _notificationSessionNavigationTimer;
  String? _pendingNotificationSessionId;
  String? _lastOpenedNotificationSessionId;
  DateTime? _lastOpenedNotificationAt;
  int _metricsEpoch = 0;
  Timer? _metricsRecoveryTimer;
  Size? _lastRecoveredViewSize;
  Orientation? _lastRecoveredOrientation;
  bool _appInForeground = true;
  bool _globalSubtitleOverlayRunning = false;
  bool _globalSubtitleOverlaySyncing = false;
  bool _globalSubtitleOverlaySyncPending = false;
  Timer? _globalSubtitleOverlayTimer;
  String? _globalSubtitleOverlaySessionId;
  String? _globalSubtitleOverlayTrackPath;
  String? _lastGlobalSubtitleOverlayText;

  void _setLocalState(VoidCallback fn) => setState(fn);

  static const List<_MainDestination> _destinations = [
    _MainDestination(
      icon: Icons.podcasts_outlined,
      selectedIcon: Icons.podcasts_rounded,
      labelKey: 'ASMR.ONE',
    ),
    _MainDestination(
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music_rounded,
      labelKey: 'nav_library',
    ),
    _MainDestination(
      icon: Icons.graphic_eq_outlined,
      selectedIcon: Icons.graphic_eq_rounded,
      labelKey: 'nav_sessions',
    ),
    _MainDestination(
      icon: Icons.tune_outlined,
      selectedIcon: Icons.tune_rounded,
      labelKey: 'nav_settings',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pages = [
      const AsmrTab(),
      const LibraryTab(),
      PlaylistTab(onTimerTap: _openTimerFromPlaylist),
      const SettingsTab(),
    ];
    AppPreferences.getBool('desktop_menu_collapsed').then((collapsed) {
      if (mounted) {
        setState(() {
          _isMenuCollapsed = collapsed ?? false;
        });
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _notificationsPlatformService.setOpenSessionHandler(
      _queueNotificationSessionNavigation,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rememberCurrentViewMetrics();
      final provider = ref.read(audioProviderFacadeProvider);
      unawaited(_syncGlobalSubtitleOverlay());
      unawaited(_consumePendingNotificationSession());
      Future.delayed(const Duration(milliseconds: 750), () {
        if (!mounted) return;
        provider.scheduleUiWarmup(
          currentPageIndex: _currentIndex,
          immediate: true,
        );
      });
    });
  }

  void _openTimerFromPlaylist() {
    if (!mounted) return;
    final provider = ref.read(audioProviderFacadeProvider);
    final timerState = _TimerPresentation(
      duration: provider.timerDuration,
      remaining: provider.timerRemaining,
      active: provider.timerActive,
      mode: provider.timerMode,
    );
    _openTimerSettingsPage(context, timerState);
  }

  void _toggleMenuCollapsed() {
    setState(() {
      _isMenuCollapsed = !_isMenuCollapsed;
    });
    unawaited(
      AppPreferences.setBool('desktop_menu_collapsed', _isMenuCollapsed),
    );
  }

  Future<bool> _ensureInstallPermissionThenRun(
    BuildContext context,
    Future<void> Function() onGranted,
  ) {
    final i18n = context.read<AppLanguageProvider>();
    return _permissionActionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('install_permission_title'),
      message: i18n.tr('install_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('cancel'),
      isGranted: AppUpdateService.canInstallUnknownApps,
      openSettings: AppUpdateService.openInstallPermissionSettings,
      onGranted: onGranted,
    );
  }

  Future<void> _checkForUpdatesOnLaunch() async {
    if (_autoUpdateCheckRunning || !mounted) return;
    _autoUpdateCheckRunning = true;
    try {
      final info = await AppUpdateService.checkLatest();
      if (!mounted || !info.isUpdateAvailable) return;
      await _showUpdateDialog(info);
    } catch (_) {
      // Automatic checks stay silent unless an update is actually available.
    } finally {
      _autoUpdateCheckRunning = false;
    }
  }

  Future<void> _showUpdateDialog(AppUpdateInfo info) async {
    if (!mounted) return;
    final i18n = context.read<AppLanguageProvider>();
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          scrollable: true,
          title: Text(i18n.tr('latest_version_available')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                i18n.tr('current_version_label', {
                  'version': info.currentVersion.versionName,
                }),
              ),
              const SizedBox(height: 6),
              Text(
                i18n.tr('latest_version_label', {
                  'version': info.latestVersionName,
                }),
              ),
              const SizedBox(height: 10),
              Text(
                info.assetName,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(i18n.tr('later')),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.download_rounded),
              label: Text(i18n.tr('download_update')),
            ),
          ],
        );
      },
    );
    if (shouldDownload == true && mounted) {
      if (Platform.isAndroid) {
        await _ensureInstallPermissionThenRun(
          context,
          () => _downloadAndInstallUpdate(info),
        );
      } else {
        await _downloadAndInstallUpdate(info);
      }
    }
  }

  Future<void> _downloadAndInstallUpdate(AppUpdateInfo info) async {
    final i18n = context.read<AppLanguageProvider>();
    File updateFile;
    try {
      updateFile = await AppUpdateService.downloadUpdate(
        info,
        onProgress: (_) {},
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'automatic_update_download_or_verification_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      final retry = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(i18n.tr('update_download_failed')),
          content: Text(i18n.tr('update_download_failed_next_step')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(i18n.tr('close')),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
                unawaited(AppUpdateService.openReleasePage(info.releaseUrl));
              },
              child: Text(i18n.tr('open_release_page')),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(i18n.tr('retry')),
            ),
          ],
        ),
      );
      if (retry == true && mounted) {
        unawaited(_downloadAndInstallUpdate(info));
      }
      return;
    }

    if (!mounted) return;
    showAppSnackBar(
      context,
      i18n.tr('update_download_verified_message', {
        'version': info.latestVersionName,
        'path': updateFile.path,
      }),
      tone: AppFeedbackTone.success,
      title: i18n.tr('update_download_verified_title'),
      icon: Icons.verified_rounded,
      duration: const Duration(seconds: 5),
    );

    try {
      final result = await AppUpdateService.installUpdate(updateFile);
      if (!mounted) return;
      if (result.needsPermission) {
        await _ensureInstallPermissionThenRun(
          context,
          () => _installDownloadedUpdate(updateFile),
        );
        return;
      }
      if (!result.ok) {
        showAppSnackBar(
          context,
          result.message ?? i18n.tr('update_install_failed'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      showAppSnackBar(
        context,
        i18n.tr('update_ready_install'),
        tone: AppFeedbackTone.success,
        icon: Icons.install_mobile_rounded,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_install_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<void> _installDownloadedUpdate(File updateFile) async {
    if (!mounted) return;
    final i18n = context.read<AppLanguageProvider>();
    try {
      final result = await AppUpdateService.installUpdate(updateFile);
      if (!mounted) return;
      if (!result.ok) {
        showAppSnackBar(
          context,
          result.message ?? i18n.tr('update_install_failed'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      showAppSnackBar(
        context,
        i18n.tr('update_ready_install'),
        tone: AppFeedbackTone.success,
        icon: Icons.install_mobile_rounded,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_install_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(_pageSwitchInteraction);
    _metricsRecoveryTimer?.cancel();
    _notificationSessionNavigationTimer?.cancel();
    _globalSubtitleOverlayTimer?.cancel();
    unawaited(_stopGlobalSubtitleOverlay(immediate: true));
    _permissionActionController.dispose();
    _notificationsPlatformService.setOpenSessionHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _metricsRecoveryTimer?.cancel();
    _metricsRecoveryTimer = Timer(
      const Duration(milliseconds: 16),
      _recoverAfterMetricsChange,
    );
  }

  Size _currentLogicalViewSize() {
    final view = View.maybeOf(context);
    if (view != null &&
        view.physicalSize.width > 0 &&
        view.physicalSize.height > 0 &&
        view.devicePixelRatio > 0) {
      return view.physicalSize / view.devicePixelRatio;
    }
    return MediaQuery.sizeOf(context);
  }

  double _currentLogicalKeyboardInset() {
    final view = View.maybeOf(context);
    if (view != null && view.devicePixelRatio > 0) {
      return view.viewInsets.bottom / view.devicePixelRatio;
    }
    return MediaQuery.viewInsetsOf(context).bottom;
  }

  bool get _isKeyboardVisible => _currentLogicalKeyboardInset() > 0.5;

  Size _layoutViewSize() {
    if (_isKeyboardVisible && _lastRecoveredViewSize != null) {
      return Size(
        _currentLogicalViewSize().width,
        _lastRecoveredViewSize!.height,
      );
    }
    return _currentLogicalViewSize();
  }

  Orientation _orientationForSize(Size size) {
    return size.width > size.height
        ? Orientation.landscape
        : Orientation.portrait;
  }

  void _rememberCurrentViewMetrics() {
    final size = _currentLogicalViewSize();
    _lastRecoveredViewSize = size;
    _lastRecoveredOrientation = _orientationForSize(size);
  }

  bool _hasRecoverableViewMetricChange() {
    if (_isKeyboardVisible) return false;

    final size = _currentLogicalViewSize();
    final orientation = _orientationForSize(size);
    final previousSize = _lastRecoveredViewSize;
    final previousOrientation = _lastRecoveredOrientation;

    _lastRecoveredViewSize = size;
    _lastRecoveredOrientation = orientation;

    if (Platform.isWindows) {
      return false;
    }

    if (previousSize == null || previousOrientation == null) {
      return false;
    }

    return (previousSize.width - size.width).abs() > 0.5 ||
        (previousSize.height - size.height).abs() > 0.5 ||
        previousOrientation != orientation;
  }

  void _recoverAfterMetricsChange() {
    if (!mounted) return;
    if (_isKeyboardVisible) return;

    if (!_hasRecoverableViewMetricChange()) {
      return;
    }

    setState(() {
      _metricsEpoch++;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(audioProviderFacadeProvider)
          .scheduleUiWarmup(currentPageIndex: _currentIndex, immediate: true);
    });
  }

  PlaybackSession? _globalSubtitleOverlaySession(
    AudioProvider provider,
    SubtitleSettingsState settings,
  ) {
    final candidates = provider.activeSessions
        .where((session) {
          return settings.isShowEnabled(session.id) &&
              settings.isGlobalEnabled(session.id);
        })
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    return candidates.firstWhere(
      (session) => session.state.playing || session.isLoading,
      orElse: () => candidates.first,
    );
  }

  Future<void> _syncGlobalSubtitleOverlay() async {
    if (_globalSubtitleOverlaySyncing) {
      _globalSubtitleOverlaySyncPending = true;
      return;
    }
    if (!mounted ||
        !shouldRunGlobalSubtitleOverlay(
          appInForeground: _appInForeground,
          isWindows: Platform.isWindows,
        )) {
      return;
    }
    _globalSubtitleOverlaySyncing = true;
    try {
      final provider = ref.read(audioProviderFacadeProvider);
      final settings = ref.read(subtitleSettingsProvider);
      final session = _globalSubtitleOverlaySession(provider, settings);
      if (session == null) {
        await _stopGlobalSubtitleOverlay(immediate: true);
        return;
      }
      final canDraw = await SubtitleOverlayController.canDrawOverlays();
      if (!canDraw) {
        await _stopGlobalSubtitleOverlay(immediate: true);
        return;
      }
      await _applyGlobalSubtitleOverlayStyle(settings);
      await SubtitleOverlayController.startOverlay();
      _globalSubtitleOverlayRunning = true;
      _ensureGlobalSubtitleOverlayTimer();
      _updateGlobalSubtitleOverlayForSession(session);
    } finally {
      _globalSubtitleOverlaySyncing = false;
      if (_globalSubtitleOverlaySyncPending) {
        _globalSubtitleOverlaySyncPending = false;
        unawaited(_syncGlobalSubtitleOverlay());
      }
    }
  }

  Future<void> _stopGlobalSubtitleOverlay({bool immediate = false}) async {
    _globalSubtitleOverlayTimer?.cancel();
    _globalSubtitleOverlayTimer = null;
    _globalSubtitleOverlaySessionId = null;
    _globalSubtitleOverlayTrackPath = null;
    _lastGlobalSubtitleOverlayText = null;
    if (!_globalSubtitleOverlayRunning && !immediate) return;
    _globalSubtitleOverlayRunning = false;
    await SubtitleOverlayController.updateSubtitle('');
    await SubtitleOverlayController.stopOverlay(immediate: immediate);
  }

  Future<void> _applyGlobalSubtitleOverlayStyle(
    SubtitleSettingsState settings,
  ) {
    final backgroundColor = (settings.backgroundColor ?? Colors.black)
        .withValues(alpha: settings.backgroundOpacity);
    final textColor = settings.fontColor ?? Colors.white;
    return SubtitleOverlayController.updateStyle(
      fontSize: settings.fontSize,
      backgroundColor: _overlayColorValue(backgroundColor),
      textColor: _overlayColorValue(textColor),
      backgroundOpacity: settings.backgroundOpacity,
      fontFamily: settings.fontFamily,
      borderDepth: settings.borderDepth,
    );
  }

  String _overlayColorValue(Color color) {
    return '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
  }

  void _ensureGlobalSubtitleOverlayTimer() {
    _globalSubtitleOverlayTimer ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _updateGlobalSubtitleOverlay(),
    );
  }

  void _updateGlobalSubtitleOverlay() {
    if (!mounted) return;
    if (!shouldRunGlobalSubtitleOverlay(
      appInForeground: _appInForeground,
      isWindows: Platform.isWindows,
    )) {
      unawaited(_stopGlobalSubtitleOverlay(immediate: true));
      return;
    }
    final provider = ref.read(audioProviderFacadeProvider);
    final settings = ref.read(subtitleSettingsProvider);
    final session = _globalSubtitleOverlaySession(provider, settings);
    if (session == null) {
      unawaited(_stopGlobalSubtitleOverlay(immediate: true));
      return;
    }
    _updateGlobalSubtitleOverlayForSession(session);
  }

  void _updateGlobalSubtitleOverlayForSession(PlaybackSession session) {
    final provider = ref.read(audioProviderFacadeProvider);
    if (_globalSubtitleOverlaySessionId != session.id) {
      _globalSubtitleOverlaySessionId = session.id;
      _lastGlobalSubtitleOverlayText = null;
    }
    if (_globalSubtitleOverlayTrackPath != session.currentTrackPath) {
      _globalSubtitleOverlayTrackPath = session.currentTrackPath;
      _lastGlobalSubtitleOverlayText = null;
      unawaited(
        provider.subtitleTrackForPath(session.currentTrackPath).then((_) {
          if (mounted &&
              shouldRunGlobalSubtitleOverlay(
                appInForeground: _appInForeground,
                isWindows: Platform.isWindows,
              )) {
            _updateGlobalSubtitleOverlay();
          }
        }),
      );
    }

    final subtitleTrack = provider.getSubtitleTrackSync(
      session.currentTrackPath,
    );
    final text =
        provider.subtitleTextForTrackAt(
          session.currentTrackPath,
          session.position,
          subtitleTrack: subtitleTrack,
        ) ??
        '';
    if (_lastGlobalSubtitleOverlayText != text) {
      _lastGlobalSubtitleOverlayText = text;
      unawaited(SubtitleOverlayController.updateSubtitle(text));
    }
    unawaited(
      SubtitleOverlayController.updatePlaybackState(session.state.playing),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _appInForeground = false;
      final provider = ref.read(audioProviderFacadeProvider);
      provider.syncKeepAliveBeforeBackground();
      unawaited(_syncGlobalSubtitleOverlay());
      return;
    }
    if (state != AppLifecycleState.resumed) {
      return;
    }
    _appInForeground = true;
    if (Platform.isWindows) {
      unawaited(_syncGlobalSubtitleOverlay());
    } else {
      unawaited(_stopGlobalSubtitleOverlay(immediate: true));
    }
    unawaited(_consumePendingNotificationSession());
    final provider = ref.read(audioProviderFacadeProvider);
    unawaited(_permissionActionController.handleAppResumed());
    provider.resyncNotificationsAfterResume();
    unawaited(
      provider.syncTimerRuntimeFromNative().then((_) {
        provider.retryOverdueAutoResume();
        provider.scheduleUiWarmup(
          currentPageIndex: _currentIndex,
          immediate: true,
        );
      }),
    );
    if (!_notificationSettingsOpened) {
      return;
    }
    _notificationSettingsOpened = false;
    _handleNotificationSettingsReturn();
  }

  void _switchPage(int index, {bool withFeedback = true}) {
    final provider = ref.read(audioProviderFacadeProvider);
    if (index == _currentIndex) {
      provider.triggerScrollToTop(index);
      return;
    }
    if (withFeedback) {
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    }

    final coordinator = UiInteractionCoordinator.instance;
    coordinator.beginInteraction(_pageSwitchInteraction);
    final generation = coordinator.beginGeneration();
    setState(() {
      if (_isDataReady) _visitedPageIndices.add(_currentIndex);
      _currentIndex = index;
    });
    if (index == 0) {
      unawaited(_showAsmrOnlineNoticeOnce());
    }

    Timer(const Duration(milliseconds: 140), () {
      coordinator.endInteraction(_pageSwitchInteraction);
      coordinator.scheduleCommit(
        key: 'main_page_$index',
        priority: 0,
        commit: () {},
      );
      coordinator.scheduleAfterIdle(
        key: 'main_page_warmup_$index',
        generation: generation,
        priority: 0,
        task: () async {
          if (!mounted || _currentIndex != index) return;
          provider.scheduleUiWarmup(currentPageIndex: index, immediate: true);
        },
      );
    });
  }

  Future<void> _showAsmrOnlineNoticeOnce() async {
    const key = 'asmr_online_notice_seen_v1';
    if (await AppPreferences.getBool(key) == true) return;
    await AppPreferences.setBool(key, true);
    if (!mounted) return;
    showAppSnackBar(
      context,
      context.read<AppLanguageProvider>().tr('asmr_online_optional_notice'),
      icon: Icons.cloud_outlined,
      duration: const Duration(seconds: 4),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SubtitleSettingsState>(subtitleSettingsProvider, (_, _) {
      unawaited(_syncGlobalSubtitleOverlay());
    });
    final i18n = context.watch<AppLanguageProvider>();
    final brightness = Theme.of(context).brightness;
    final overlayStyle = brightness == Brightness.dark
        ? const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarIconBrightness: Brightness.light,
            systemStatusBarContrastEnforced: false,
            systemNavigationBarContrastEnforced: false,
          )
        : const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarIconBrightness: Brightness.dark,
            systemStatusBarContrastEnforced: false,
            systemNavigationBarContrastEnforced: false,
          );
    final overlayUi = ref.watch(mainOverlayUiProvider);
    final startupPage = ref.watch(
      settingsStateProvider.select(
        (value) => value.valueOrNull?.startupPage ?? StartupPage.library,
      ),
    );
    final autoCheckUpdates = ref.watch(
      settingsStateProvider.select(
        (value) => value.valueOrNull?.autoCheckUpdates ?? false,
      ),
    );
    if (autoCheckUpdates &&
        overlayUi.isInitialized &&
        !_autoUpdateCheckQueued) {
      _autoUpdateCheckQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_checkForUpdatesOnLaunch());
      });
    }
    final hasPlayingSession = overlayUi.hasPlayingSession;
    final activeSessionCount = overlayUi.activeSessionCount;
    final showCard = overlayUi.showPlaybackCard;
    final visibleSessions = overlayUi.visibleSessions;
    if (_lastShowCard != showCard) {
      _lastShowCard = showCard;
    }
    final hasNowPlaying = overlayUi.hasNowPlaying;
    if (activeSessionCount > 0 &&
        !_notificationPermissionCheckDone &&
        !_notificationPermissionCheckQueued) {
      _notificationPermissionCheckQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureNotificationPermission();
      });
    }
    if (hasPlayingSession &&
        !_backgroundPlaybackPromptShownThisLaunch &&
        !_backgroundPlaybackPromptQueued) {
      _backgroundPlaybackPromptQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybePromptForBackgroundPlaybackReliability());
      });
    }
    if (!_isDataReady && overlayUi.isInitialized) {
      _currentIndex = startupPage.index;
      _isDataReady = true;
    }
    final layoutSize = _layoutViewSize();
    final width = layoutSize.width;
    final isLandscape =
        _orientationForSize(layoutSize) == Orientation.landscape;
    final isDesktop =
        (Platform.isWindows && width >= 600) ||
        width >= _desktopBreakpoint ||
        isLandscape;
    final isTinyWindow = width < 300 || layoutSize.height < 300;
    final mobileContentInset = isDesktop
        ? 0.0
        : _mobileContentInset(hasNowPlaying: hasNowPlaying);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        extendBody: !isDesktop,
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _AmbientBackground(tinyMode: isTinyWindow),
            Column(
              children: [
                const WindowsTitleBar(),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (isDesktop)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildDesktopNavigation(
                              context,
                              i18n,
                              visibleSessions,
                            ),
                            Expanded(
                              child: _buildAnimatedBody(isDesktop: true),
                            ),
                          ],
                        )
                      else
                        Stack(
                          fit: StackFit.expand,
                          children: [
                            MobileOverlayInset(
                              bottomInset: mobileContentInset,
                              child: _buildAnimatedBody(isDesktop: false),
                            ),
                            _buildMobileBottomDock(
                              context,
                              i18n: i18n,
                              overlaySessions: visibleSessions,
                              tinyMode: isTinyWindow,
                            ),
                          ],
                        ),
                      if (_timerOverlayPrimed) const _ImmediateTimerScrim(),

                      if (!_bootstrapDone)
                        _BootstrapOverlay(
                          visible: !_isDataReady,
                          onAnimationEnd: () {
                            if (mounted) setState(() => _bootstrapDone = true);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
