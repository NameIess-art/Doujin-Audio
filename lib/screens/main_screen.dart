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
import '../services/app_preferences.dart';
import '../services/app_update_service.dart';
import '../services/notifications_platform_service.dart';
import '../services/permission_action_controller.dart';
import '../services/power_platform_service.dart';
import 'asmr_tab.dart';
import 'library_tab.dart';
import 'playlist_tab.dart';
import 'settings_tab.dart';
import 'timer_tab.dart';
import '../widgets/active_session_carousel.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/windows_title_bar.dart';

import '../widgets/floating_subtitle_window.dart';

part 'main_screen_notifications.dart';
part 'main_screen_storage_permission.dart';
part 'main_screen_layout.dart';
part 'main_screen_widgets.dart';
part 'main_screen_timer_scrim.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  static const Duration _pageTransitionDuration = Duration(milliseconds: 240);
  static const Curve _pageTransitionCurve = Curves.easeOutCubic;
  static const double _desktopBreakpoint = 980;
  static const String _backgroundKeepAliveInitializedKey =
      'background_keep_alive_initialized_v2';
  final PowerPlatformService _powerPlatformService = PowerPlatformService();
  final NotificationsPlatformService _notificationsPlatformService =
      NotificationsPlatformService();

  int _currentIndex = 1;
  late final PageController _pageController;
  late final List<Widget> _pages;
  final GlobalKey _bottomDockKey = GlobalKey();
  final GlobalKey _dockContentKey = GlobalKey();
  double _measuredBottomInset = 0;
  double _measuredDockContent = 0;
  bool _notificationPermissionCheckDone = false;
  bool _notificationPermissionCheckQueued = false;
  bool _notificationSettingsDialogVisible = false;
  bool _notificationSettingsOpened = false;
  bool _backgroundPlaybackPromptShownThisLaunch = false;
  bool _backgroundPlaybackPromptQueued = false;
  bool _manageFilesPermissionCheckDone = false;
  bool _autoUpdateCheckQueued = false;
  bool _autoUpdateCheckRunning = false;
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  bool _timerOverlayPrimed = false;
  bool _needsMeasurement = true;
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

  int? _pendingTargetIndex;
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
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addObserver(this);
    _notificationsPlatformService.setOpenSessionHandler(
      _queueNotificationSessionNavigation,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rememberCurrentViewMetrics();
      final provider = ref.read(audioProviderFacadeProvider);
      unawaited(_consumePendingNotificationSession());
      unawaited(_ensureManageFilesPermission());
      unawaited(_maybeEnableBackgroundKeepAliveOnFirstLaunch());
      provider.scheduleUiWarmup(
        currentPageIndex: _currentIndex,
        immediate: true,
      );
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
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_download_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
      return;
    }

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
    _pageController.dispose();
    _metricsRecoveryTimer?.cancel();
    _notificationSessionNavigationTimer?.cancel();
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
    if (!_hasRecoverableViewMetricChange()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measureBottomDock();
      });
      return;
    }

    setState(() {
      _metricsEpoch++;
      _needsMeasurement = true;
      _measuredBottomInset = 0;
      _measuredDockContent = 0;
      _pendingTargetIndex = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex.clamp(0, _pages.length - 1));
      }
      _measureBottomDock();
      ref
          .read(audioProviderFacadeProvider)
          .scheduleUiWarmup(currentPageIndex: _currentIndex, immediate: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final provider = ref.read(audioProviderFacadeProvider);
      provider.syncKeepAliveBeforeBackground();
      return;
    }
    if (state != AppLifecycleState.resumed) {
      return;
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
      Feedback.forTap(context);
    }

    int? adjacentPageIndex;
    if (_pageController.hasClients) {
      final int previousIndex = _pageController.page?.round() ?? _currentIndex;
      if ((index - previousIndex).abs() > 1) {
        adjacentPageIndex = index > previousIndex ? index - 1 : index + 1;
      }
    }

    _pendingTargetIndex = index;
    setState(() {
      _currentIndex = index;
    });

    if (adjacentPageIndex != null && _pageController.hasClients) {
      _pageController.jumpToPage(adjacentPageIndex);
    }

    if (!_pageController.hasClients) return;

    final width = MediaQuery.sizeOf(context).width;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final isDesktop =
        Platform.isWindows || width >= _desktopBreakpoint || isLandscape;

    if (isDesktop) {
      _pageController.jumpToPage(index);
      provider.scheduleUiWarmup(currentPageIndex: index);
    } else {
      _pageController
          .animateToPage(
            index,
            duration: _pageTransitionDuration,
            curve: _pageTransitionCurve,
          )
          .whenComplete(() {
            if (!mounted) return;
            provider.scheduleUiWarmup(currentPageIndex: index);
          });
    }
  }

  @override
  Widget build(BuildContext context) {
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
      _needsMeasurement = true;
    }
    final subtitleSessions = overlayUi.subtitleSessions;
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
      _isDataReady = true;
    }
    final width = MediaQuery.sizeOf(context).width;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final isDesktop =
        Platform.isWindows || width >= _desktopBreakpoint || isLandscape;
    final isTinyWindow = width < 300 || MediaQuery.sizeOf(context).height < 300;
    final mobileContentInset = isDesktop
        ? 0.0
        : _mobileContentInset(hasNowPlaying: hasNowPlaying);

    if (_needsMeasurement) {
      _needsMeasurement = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureBottomDock());
    }

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
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: _measuredDockContent > 0
                                  ? _measuredDockContent + 36
                                  : 136,
                              child: IgnorePointer(
                                child: ShaderMask(
                                  shaderCallback: (bounds) =>
                                      const LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.white,
                                        ],
                                        stops: [0, 0.45],
                                      ).createShader(bounds),
                                  child: RepaintBoundary(
                                    child: isTinyWindow
                                        ? const SizedBox.expand()
                                        : const SizedBox.expand(),
                                  ),
                                ),
                              ),
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
                      for (final session in subtitleSessions)
                        FloatingSubtitleWindow(
                          key: ValueKey('subtitle_${session.id}'),
                          sessionId: session.id,
                          isCrossPage: true,
                        ),
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
