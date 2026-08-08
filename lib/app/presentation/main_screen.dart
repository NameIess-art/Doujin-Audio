import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
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
import '../../features/player/presentation/playlist_tab.dart';
import '../../features/settings/presentation/settings_tab.dart';
import '../../features/settings/presentation/app_update_flow.dart';
import '../../features/player/presentation/timer_tab.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_edge_fade_mask.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/confirm_action_dialog.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import 'audio_library_page.dart';

part 'main_screen_notifications.dart';
part 'main_screen_layout.dart';
part 'main_screen_widgets.dart';

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

  bool _isMenuCollapsed = false;
  late final ValueNotifier<int> _activePageIndex;
  late final ValueNotifier<int> _audioLibrarySectionIndex;
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
  int _globalSubtitleOverlayGeneration = 0;
  Timer? _globalSubtitleOverlayTimer;
  String? _globalSubtitleOverlaySessionId;
  String? _globalSubtitleOverlayTrackPath;
  String? _lastGlobalSubtitleOverlayText;

  static const List<_MainDestination> _destinations = [
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
    _activePageIndex = ValueNotifier<int>(0);
    _audioLibrarySectionIndex = ValueNotifier<int>(
      AudioLibraryPage.localSection,
    );
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
      _requestGlobalSubtitleOverlaySync();
      unawaited(_consumePendingNotificationSession());
      Future.delayed(const Duration(milliseconds: 750), () {
        if (!mounted) return;
        warmup.schedule(
          currentPageIndex: _activePageIndex.value,
          immediate: true,
        );
      });
    });
  }

  void _handleStartupReadyChanged(bool startupReady) {
    if (!mounted || !startupReady) return;
    if (!_isDataReady) {
      final startupPage =
          ref.read(settingsStateProvider).value?.startupPage ??
          StartupPage.library;
      _audioLibrarySectionIndex.value = startupPage == StartupPage.asmrOne
          ? AudioLibraryPage.asmrSection
          : AudioLibraryPage.localSection;
      final startupIndex = startupPage == StartupPage.playlist ? 1 : 0;
      _activePageIndex.value = startupIndex;
      setState(() => _isDataReady = true);
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
    _audioLibrarySectionIndex.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (_isKeyboardVisible) {
      _metricsRecoveryTimer?.cancel();
      return;
    }
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
          .schedule(currentPageIndex: _activePageIndex.value, immediate: true);
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

  void _requestGlobalSubtitleOverlaySync() {
    _globalSubtitleOverlayGeneration++;
    unawaited(_syncGlobalSubtitleOverlay());
  }

  bool _isGlobalSubtitleOverlayRequestCurrent(
    int generation,
    String sessionId,
    String trackPath,
  ) {
    if (!mounted ||
        generation != _globalSubtitleOverlayGeneration ||
        !shouldRunGlobalSubtitleOverlay(appInForeground: _appInForeground)) {
      return false;
    }
    final session = _globalSubtitleOverlaySession(
      ref.read(playbackFacadeProvider),
      ref.read(subtitleSettingsProvider),
    );
    return session?.id == sessionId && session?.currentTrackPath == trackPath;
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
    final generation = _globalSubtitleOverlayGeneration;
    _globalSubtitleOverlaySyncing = true;
    try {
      final playback = ref.read(playbackFacadeProvider);
      final settings = ref.read(subtitleSettingsProvider);
      final session = _globalSubtitleOverlaySession(playback, settings);
      if (session == null) {
        await _stopGlobalSubtitleOverlay(immediate: true);
        return;
      }
      final sessionId = session.id;
      final trackPath = session.currentTrackPath;
      final canDraw = await _subtitleOverlay.canDrawOverlays();
      if (!_isGlobalSubtitleOverlayRequestCurrent(
        generation,
        sessionId,
        trackPath,
      )) {
        return;
      }
      if (!canDraw) {
        await _stopGlobalSubtitleOverlay(immediate: true);
        return;
      }
      await _applyGlobalSubtitleOverlayStyle(settings);
      if (!_isGlobalSubtitleOverlayRequestCurrent(
        generation,
        sessionId,
        trackPath,
      )) {
        return;
      }
      final started = await _subtitleOverlay.startOverlay();
      if (!started ||
          !_isGlobalSubtitleOverlayRequestCurrent(
            generation,
            sessionId,
            trackPath,
          )) {
        if (started) {
          await _subtitleOverlay.stopOverlay(immediate: true);
        }
        return;
      }
      _globalSubtitleOverlayRunning = true;
      _ensureGlobalSubtitleOverlayTimer();
      _updateGlobalSubtitleOverlayForSession(session);
    } finally {
      _globalSubtitleOverlaySyncing = false;
      if (_globalSubtitleOverlaySyncPending &&
          mounted &&
          shouldRunGlobalSubtitleOverlay(appInForeground: _appInForeground)) {
        _globalSubtitleOverlaySyncPending = false;
        unawaited(_syncGlobalSubtitleOverlay());
      } else {
        _globalSubtitleOverlaySyncPending = false;
      }
    }
  }

  Future<void> _stopGlobalSubtitleOverlay({bool immediate = false}) async {
    _globalSubtitleOverlayGeneration++;
    _globalSubtitleOverlaySyncPending = false;
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
      _requestGlobalSubtitleOverlaySync();
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
        warmup.schedule(
          currentPageIndex: _activePageIndex.value,
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

  void _switchPage(int index) {
    if (index == _activePageIndex.value) {
      ref.read(mainScreenControllerProvider).requestScrollToTop(index);
      return;
    }

    final coordinator = UiInteractionCoordinator.instance;
    coordinator.beginInteraction(_pageSwitchInteraction);
    _pageSwitchCoordinatorGeneration = coordinator.beginGeneration();
    _activePageIndex.value = index;
    if (index == 0 &&
        _audioLibrarySectionIndex.value == AudioLibraryPage.asmrSection) {
      unawaited(_showAsmrOnlineNoticeOnce());
    }
  }

  void _openLocalLibrary() {
    _switchAudioLibrarySection(AudioLibraryPage.localSection);
    _switchPage(0);
  }

  void _switchAudioLibrarySection(int index) {
    if (_audioLibrarySectionIndex.value == index) return;
    _pageSwitchCoordinatorGeneration = UiInteractionCoordinator.instance
        .beginGeneration();
    _audioLibrarySectionIndex.value = index;
    if (index == AudioLibraryPage.asmrSection) {
      unawaited(_showAsmrOnlineNoticeOnce());
    }
  }

  Widget _buildMainPage(BuildContext context, int index) {
    return switch (index) {
      0 => AudioLibraryPage(
        sectionIndex: _audioLibrarySectionIndex,
        activePageIndex: _activePageIndex,
        onSectionChanged: _switchAudioLibrarySection,
      ),
      1 => PlaylistTab(
        onTimerTap: _openTimerFromPlaylist,
        onOpenLibrary: _openLocalLibrary,
        activeTabIndexListenable: _activePageIndex,
      ),
      2 => const SettingsTab(),
      _ => const SizedBox.shrink(),
    };
  }

  void _toggleAudioLibrarySectionFromNavigation() {
    final nextSection =
        _audioLibrarySectionIndex.value == AudioLibraryPage.localSection
        ? AudioLibraryPage.asmrSection
        : AudioLibraryPage.localSection;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    _switchAudioLibrarySection(nextSection);
  }

  void _handlePageTransitionCompleted(int index) {
    if (!mounted || _activePageIndex.value != index) return;
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
        if (!mounted || _activePageIndex.value != index) return;
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
      provideHapticFeedback: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SubtitleSettingsState>(subtitleSettingsProvider, (_, _) {
      _requestGlobalSubtitleOverlaySync();
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

    final content = AnnotatedRegion<SystemUiOverlayStyle>(
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
    return MediaQuery.removeViewInsets(
      key: const ValueKey<String>('main_screen_keyboard_inset_boundary'),
      context: context,
      removeBottom: true,
      child: content,
    );
  }
}
