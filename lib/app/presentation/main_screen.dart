import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../localization/app_language_provider.dart';
import '../state/app_runtime_providers.dart';
import '../state/subtitle_settings_provider.dart';
import '../../features/settings/application/app_preferences.dart';
import '../../features/settings/application/settings_state.dart';
import '../../core/logging/app_log_service.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_session.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/player/application/subtitle_overlay_controller.dart';
import '../../core/platform/notifications_platform_service.dart';
import '../../core/platform/permission_action_controller.dart';
import '../../core/platform/power_platform_service.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/ui/ui_operation_service.dart';
import '../theme/app_design_tokens.dart';
import '../theme/app_styles.dart';
import '../../features/asmr/presentation/asmr_tab.dart';
import '../../features/library/presentation/library_tab.dart';
import '../../features/player/presentation/playlist_tab.dart';
import '../../features/settings/presentation/settings_tab.dart';
import '../../features/settings/presentation/app_update_flow.dart';
import '../../features/player/presentation/timer_tab.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_edge_fade_mask.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/confirm_action_dialog.dart';
import '../../core/widgets/mobile_overlay_inset.dart';

part 'main_screen_notifications.dart';
part 'main_screen_layout.dart';
part 'main_screen_widgets.dart';
part 'main_screen_timer_scrim.dart';

@visibleForTesting
bool shouldRunGlobalSubtitleOverlay({required bool appInForeground}) {
  return !appInForeground;
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
  late final ValueNotifier<int> _activePageIndex;
  final Object _pageSwitchInteraction = Object();
  final GlobalKey _dockContentKey = GlobalKey();
  int _pageSwitchCoordinatorGeneration = 0;

  bool _notificationPermissionCheckDone = false;
  bool _notificationPermissionCheckQueued = false;
  bool _notificationSettingsDialogVisible = false;
  bool _notificationSettingsOpened = false;
  bool _backgroundPlaybackPromptShownThisLaunch = false;
  bool _backgroundPlaybackPromptQueued = false;
  bool _autoUpdateCheckQueued = false;
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  late final AppUpdateFlow _updateFlow;
  late final SubtitleOverlayController _subtitleOverlay;
  bool _timerOverlayPrimed = false;

  bool _isDataReady = false;
  bool? _lastHasNowPlaying;
  Timer? _notificationSessionNavigationTimer;
  String? _pendingNotificationSessionId;
  DateTime? _pendingNotificationSessionStartedAt;
  int _pendingNotificationSessionRetryCount = 0;
  String? _lastOpenedNotificationSessionId;
  DateTime? _lastOpenedNotificationAt;
  Timer? _metricsRecoveryTimer;
  Size? _lastRecoveredViewSize;
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
    _subtitleOverlay = ref.read(subtitleOverlayControllerProvider);
    _updateFlow = AppUpdateFlow(
      permissionController: _permissionActionController,
      languageProvider: ref.read(appLanguageProviderInstanceProvider),
      updateService: ref.read(appUpdateServiceProvider),
    );
    _activePageIndex = ValueNotifier<int>(_currentIndex);
    _pages = [
      const AsmrTab(),
      LibraryTab(activeTabIndexListenable: _activePageIndex),
      PlaylistTab(
        onTimerTap: _openTimerFromPlaylist,
        onOpenLibrary: () => _switchPage(1),
        activeTabIndexListenable: _activePageIndex,
      ),
      const SettingsTab(),
    ];
    ref.listenManual<bool>(
      mainOverlayUiProvider.select((state) => state.startupReady),
      (_, startupReady) => _handleStartupReadyChanged(startupReady),
      fireImmediately: true,
    );
    ref.listenManual<int>(
      mainOverlayUiProvider.select((state) => state.activeSessionCount),
      (_, activeSessionCount) =>
          _handleActiveSessionCountChanged(activeSessionCount),
      fireImmediately: true,
    );
    ref.listenManual<bool>(
      mainOverlayUiProvider.select((state) => state.hasPlayingSession),
      (_, hasPlayingSession) => _handlePlayingSessionChanged(hasPlayingSession),
      fireImmediately: true,
    );
    ref.listenManual<bool>(
      settingsStateProvider.select(
        (value) => value.value?.autoCheckUpdates ?? false,
      ),
      (_, _) => _queueAutoUpdateCheckIfReady(),
      fireImmediately: true,
    );
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
      final warmup = ref.read(audioUiWarmupCoordinatorProvider);
      unawaited(_syncGlobalSubtitleOverlay());
      unawaited(_consumePendingNotificationSession());
      Future.delayed(const Duration(milliseconds: 750), () {
        if (!mounted) return;
        warmup.schedule(currentPageIndex: _currentIndex, immediate: true);
      });
    });
  }

  void _handleStartupReadyChanged(bool startupReady) {
    if (!mounted || !startupReady) return;
    if (!_isDataReady) {
      final startupPage =
          ref.read(settingsStateProvider).value?.startupPage ??
          StartupPage.library;
      setState(() {
        _currentIndex = startupPage.index;
        _isDataReady = true;
      });
      _activePageIndex.value = _currentIndex;
    }
    _queueAutoUpdateCheckIfReady();
  }

  void _handleActiveSessionCountChanged(int activeSessionCount) {
    if (!mounted) return;
    if (activeSessionCount > 0 &&
        !_notificationPermissionCheckDone &&
        !_notificationPermissionCheckQueued) {
      _notificationPermissionCheckQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureNotificationPermission();
      });
    }
  }

  void _handlePlayingSessionChanged(bool hasPlayingSession) {
    if (!mounted) return;
    if (Platform.isAndroid &&
        hasPlayingSession &&
        !_backgroundPlaybackPromptShownThisLaunch &&
        !_backgroundPlaybackPromptQueued) {
      _backgroundPlaybackPromptQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybePromptForBackgroundPlaybackReliability());
      });
    }
  }

  void _queueAutoUpdateCheckIfReady() {
    if (!mounted || _autoUpdateCheckQueued) return;
    final autoCheckUpdates =
        ref.read(settingsStateProvider).value?.autoCheckUpdates ?? false;
    if (!autoCheckUpdates || !ref.read(mainOverlayUiProvider).startupReady) {
      return;
    }
    _autoUpdateCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForUpdatesOnLaunch());
    });
  }

  void _openTimerFromPlaylist() {
    if (!mounted) return;
    final timer =
        ref.read(timerStateProvider).value ??
        ref.read(timerFacadeProvider).state;
    final timerState = _TimerPresentation(
      duration: timer.duration,
      remaining: timer.remaining,
      active: timer.active,
      mode: timer.mode,
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

  Future<void> _checkForUpdatesOnLaunch() async {
    if (!mounted) return;
    await _updateFlow.checkAndPresent(
      context: context,
      operations: ref.read(uiOperationServiceProvider),
      automatic: true,
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(_pageSwitchInteraction);
    _metricsRecoveryTimer?.cancel();
    _notificationSessionNavigationTimer?.cancel();
    _notificationSessionNavigationTimer = null;
    _pendingNotificationSessionId = null;
    _pendingNotificationSessionStartedAt = null;
    _pendingNotificationSessionRetryCount = 0;
    _globalSubtitleOverlayTimer?.cancel();
    unawaited(_stopGlobalSubtitleOverlay(immediate: true));
    _permissionActionController.dispose();
    _notificationsPlatformService.setOpenSessionHandler(null);
    _activePageIndex.dispose();
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

  void _rememberCurrentViewMetrics() {
    _lastRecoveredViewSize = _currentLogicalViewSize();
  }

  bool _hasRecoverableViewMetricChange() {
    if (_isKeyboardVisible) return false;

    final size = _currentLogicalViewSize();
    final previousSize = _lastRecoveredViewSize;

    _lastRecoveredViewSize = size;

    if (previousSize == null) {
      return false;
    }

    return (previousSize.width - size.width).abs() > 0.5 ||
        (previousSize.height - size.height).abs() > 0.5;
  }

  void _recoverAfterMetricsChange() {
    if (!mounted) return;
    if (_isKeyboardVisible) {
      return;
    }

    if (!_hasRecoverableViewMetricChange()) {
      return;
    }

    // Refresh the responsive chrome after the platform view settles. The
    // persistent page stack keeps each tab's State mounted during this rebuild.
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(audioUiWarmupCoordinatorProvider)
          .schedule(currentPageIndex: _currentIndex, immediate: true);
    });
  }

  PlaybackSession? _globalSubtitleOverlaySession(
    PlaybackFacade playback,
    SubtitleSettingsState settings,
  ) {
    final candidates = playback.state.activeSessions
        .where((session) {
          return settings.isShowEnabled(session.id) &&
              settings.isGlobalEnabled(session.id);
        })
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    return candidates.firstWhere(
      (session) => session.effectivePlaying || session.isLoading,
      orElse: () => candidates.first,
    );
  }

  Future<void> _syncGlobalSubtitleOverlay() async {
    if (_globalSubtitleOverlaySyncing) {
      _globalSubtitleOverlaySyncPending = true;
      return;
    }
    if (!mounted ||
        !shouldRunGlobalSubtitleOverlay(appInForeground: _appInForeground)) {
      return;
    }
    _globalSubtitleOverlaySyncing = true;
    try {
      final playback = ref.read(playbackFacadeProvider);
      final settings = ref.read(subtitleSettingsProvider);
      final session = _globalSubtitleOverlaySession(playback, settings);
      if (session == null) {
        await _stopGlobalSubtitleOverlay(immediate: true);
        return;
      }
      final canDraw = await _subtitleOverlay.canDrawOverlays();
      if (!canDraw) {
        await _stopGlobalSubtitleOverlay(immediate: true);
        return;
      }
      await _applyGlobalSubtitleOverlayStyle(settings);
      await _subtitleOverlay.startOverlay();
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
    await _subtitleOverlay.updateSubtitle('');
    await _subtitleOverlay.stopOverlay(immediate: immediate);
  }

  Future<void> _applyGlobalSubtitleOverlayStyle(
    SubtitleSettingsState settings,
  ) {
    final backgroundColor = (settings.backgroundColor ?? Colors.black)
        .withValues(alpha: settings.backgroundOpacity);
    final textColor = settings.fontColor ?? Colors.white;
    return _subtitleOverlay.updateStyle(
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
    if (!shouldRunGlobalSubtitleOverlay(appInForeground: _appInForeground)) {
      unawaited(_stopGlobalSubtitleOverlay(immediate: true));
      return;
    }
    final playback = ref.read(playbackFacadeProvider);
    final settings = ref.read(subtitleSettingsProvider);
    final session = _globalSubtitleOverlaySession(playback, settings);
    if (session == null) {
      unawaited(_stopGlobalSubtitleOverlay(immediate: true));
      return;
    }
    _updateGlobalSubtitleOverlayForSession(session);
  }

  void _updateGlobalSubtitleOverlayForSession(PlaybackSession session) {
    final subtitles = ref.read(playbackSubtitleServiceProvider);
    if (_globalSubtitleOverlaySessionId != session.id) {
      _globalSubtitleOverlaySessionId = session.id;
      _lastGlobalSubtitleOverlayText = null;
    }
    if (_globalSubtitleOverlayTrackPath != session.currentTrackPath) {
      final trackPath = session.currentTrackPath;
      _globalSubtitleOverlayTrackPath = trackPath;
      _lastGlobalSubtitleOverlayText = null;
      unawaited(() async {
        try {
          await subtitles.load(trackPath);
          if (mounted &&
              _globalSubtitleOverlayTrackPath == trackPath &&
              shouldRunGlobalSubtitleOverlay(
                appInForeground: _appInForeground,
              )) {
            _updateGlobalSubtitleOverlay();
          }
        } catch (error, stackTrace) {
          AppLogService.warning(
            'global_subtitle_load_failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }());
    }

    final subtitleTrack = subtitles.trackSync(session.currentTrackPath);
    final text =
        subtitles.textAt(
          session.currentTrackPath,
          session.position,
          subtitleTrack: subtitleTrack,
        ) ??
        '';
    if (_lastGlobalSubtitleOverlayText != text) {
      _lastGlobalSubtitleOverlayText = text;
      unawaited(_subtitleOverlay.updateSubtitle(text));
    }
    unawaited(_subtitleOverlay.updatePlaybackState(session.state.playing));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _appInForeground = false;
      unawaited(ref.read(audioRuntimeCoordinatorProvider).enterBackground());
      unawaited(_syncGlobalSubtitleOverlay());
      return;
    }
    if (state != AppLifecycleState.resumed) {
      return;
    }
    _appInForeground = true;
    unawaited(_stopGlobalSubtitleOverlay(immediate: true));
    unawaited(_consumePendingNotificationSession());
    unawaited(_permissionActionController.handleAppResumed());
    unawaited(
      ref.read(audioRuntimeCoordinatorProvider).resumeForeground().then((_) {
        if (!mounted) return;
        final warmup = ref.read(audioUiWarmupCoordinatorProvider);
        warmup.schedule(currentPageIndex: _currentIndex, immediate: true);
      }),
    );
    if (!_notificationSettingsOpened) {
      return;
    }
    _notificationSettingsOpened = false;
    _handleNotificationSettingsReturn();
  }

  void _switchPage(int index) {
    if (index == _currentIndex) {
      ref.read(mainScreenControllerProvider).requestScrollToTop(index);
      return;
    }

    final coordinator = UiInteractionCoordinator.instance;
    coordinator.beginInteraction(_pageSwitchInteraction);
    _pageSwitchCoordinatorGeneration = coordinator.beginGeneration();
    setState(() {
      _currentIndex = index;
    });
    _activePageIndex.value = index;
    if (index == 0) {
      unawaited(_showAsmrOnlineNoticeOnce());
    }
  }

  void _handlePageTransitionCompleted(int index) {
    if (!mounted || _currentIndex != index) return;
    final warmup = ref.read(audioUiWarmupCoordinatorProvider);
    final coordinator = UiInteractionCoordinator.instance;
    final generation = _pageSwitchCoordinatorGeneration;
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
        warmup.schedule(currentPageIndex: index, immediate: true);
      },
    );
  }

  Future<void> _showAsmrOnlineNoticeOnce() async {
    const key = 'asmr_online_notice_seen_v1';
    if (await AppPreferences.getBool(key) == true) return;
    await AppPreferences.setBool(key, true);
    if (!mounted) return;
    showAppSnackBar(
      context,
      ProviderScope.containerOf(context, listen: false)
          .read(appLanguageProviderInstanceProvider)
          .tr('asmr_online_optional_notice'),
      icon: Icons.cloud_outlined,
      duration: const Duration(seconds: 4),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SubtitleSettingsState>(subtitleSettingsProvider, (_, _) {
      unawaited(_syncGlobalSubtitleOverlay());
    });
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
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
    final bottomNavigationStyle = ref.watch(
      settingsStateProvider.select(
        (value) =>
            value.value?.bottomNavigationStyle ?? BottomNavigationStyle.capsule,
      ),
    );
    final hasNowPlaying = ref.watch(
      mainOverlayUiProvider.select((state) => state.hasNowPlaying),
    );
    final previousHasNowPlaying = _lastHasNowPlaying;
    _lastHasNowPlaying = hasNowPlaying;
    final layoutSize = _layoutViewSize();
    final width = layoutSize.width;
    final isDesktop =
        MediaQuery.orientationOf(context) == Orientation.landscape ||
        width >= _desktopBreakpoint;
    final isTinyWindow = width < 300 || layoutSize.height < 300;
    final mobileContentInset = isDesktop
        ? 0.0
        : _mobileContentInset(
            hasNowPlaying: hasNowPlaying,
            previousHasNowPlaying: previousHasNowPlaying,
            bottomNavigationStyle: bottomNavigationStyle,
          );

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
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (isDesktop)
                            Consumer(
                              builder: (context, ref, _) {
                                final visibleSessions = ref.watch(
                                  mainOverlayUiProvider.select(
                                    (state) => state.visibleSessions,
                                  ),
                                );
                                return _buildDesktopNavigation(
                                  context,
                                  i18n,
                                  visibleSessions,
                                );
                              },
                            )
                          else
                            const SizedBox.shrink(),
                          Expanded(
                            child: MobileOverlayInset(
                              bottomInset: mobileContentInset,
                              child: _buildAnimatedBody(isDesktop: isDesktop),
                            ),
                          ),
                        ],
                      ),

                      if (!isDesktop)
                        Consumer(
                          builder: (context, ref, _) {
                            final visibleSessions = ref.watch(
                              mainOverlayUiProvider.select(
                                (state) => state.visibleSessions,
                              ),
                            );
                            return _buildMobileBottomDock(
                              context,
                              i18n: i18n,
                              overlaySessions: visibleSessions,
                              style: bottomNavigationStyle,
                              tinyMode: isTinyWindow,
                            );
                          },
                        ),

                      if (_timerOverlayPrimed) const _ImmediateTimerScrim(),
                    ],
                  ),
                ),
              ],
            ),
            const _GlobalUpdateOperationBanner(),
          ],
        ),
      ),
    );
  }
}
