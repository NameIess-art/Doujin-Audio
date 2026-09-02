import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../localization/app_language_provider.dart';
import '../state/app_runtime_providers.dart';
import 'app_presentation_providers.dart';
import '../state/subtitle_settings_provider.dart';
import '../../features/settings/application/app_preferences.dart';
import '../../features/settings/application/permission_status_service.dart';
import '../../features/settings/application/settings_state.dart';
import '../../core/logging/app_log_service.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_session_snapshot.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/player/application/subtitle_overlay_controller.dart';
import '../../core/ui/permission_action_controller.dart';
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
import '../../features/library/presentation/library_tab.dart';
import '../../features/asmr/presentation/asmr_tab.dart';
import '../../features/player/application/playback_session.dart';

part 'main_screen_notifications.dart';
part 'main_screen_layout.dart';
part 'main_screen_widgets.dart';

@visibleForTesting
bool shouldRunGlobalSubtitleOverlay({required bool appInForeground}) {
  return !appInForeground;
}

enum MainDestinationType {
  library,
  asmrOne,
  playlist,
  settings,
}

class _MainDestination {
  const _MainDestination({
    required this.type,
    required this.icon,
    required this.selectedIcon,
    required this.labelKey,
  });

  final MainDestinationType type;
  final IconData icon;
  final IconData selectedIcon;
  final String labelKey;
}

List<_MainDestination> _resolveMainDestinations({
  required bool showLocalLibrary,
  required bool showAsmrOne,
}) {
  return [
    if (showAsmrOne)
      const _MainDestination(
        type: MainDestinationType.asmrOne,
        icon: Icons.cloud_outlined,
        selectedIcon: Icons.cloud_rounded,
        labelKey: 'show_asmr_one',
      ),
    if (showLocalLibrary)
      const _MainDestination(
        type: MainDestinationType.library,
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music_rounded,
        labelKey: 'music_library',
      ),
    const _MainDestination(
      type: MainDestinationType.playlist,
      icon: Icons.graphic_eq_outlined,
      selectedIcon: Icons.graphic_eq_rounded,
      labelKey: 'nav_sessions',
    ),
    const _MainDestination(
      type: MainDestinationType.settings,
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      labelKey: 'nav_settings',
    ),
  ];
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  static const double _desktopBreakpoint = 980;
  bool _isMenuCollapsed = false;
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
  late final NotificationFacade _notificationFacade;

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
  FlutterView? _observedView;
  bool _appInForeground = true;
  bool _globalSubtitleOverlayRunning = false;
  bool _globalSubtitleOverlaySyncing = false;
  bool _globalSubtitleOverlaySyncPending = false;
  int _globalSubtitleOverlayGeneration = 0;
  Timer? _globalSubtitleOverlayTimer;
  String? _globalSubtitleOverlaySessionId;
  String? _globalSubtitleOverlayTrackPath;
  String? _lastGlobalSubtitleOverlayText;

  @override
  void initState() {
    super.initState();
    _subtitleOverlay = ref.read(subtitleOverlayControllerProvider);
    _notificationFacade = ref.read(notificationFacadeProvider);
    _updateFlow = AppUpdateFlow(
      permissionController: _permissionActionController,
      languageProvider: ref.read(appLanguageProviderInstanceProvider),
      updateService: ref.read(appUpdateServiceProvider),
    );
    _activePageIndex = ValueNotifier<int>(0);
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
    _notificationFacade.setOpenSessionHandler(
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observedView = View.maybeOf(context);
  }

  void _handleStartupReadyChanged(bool startupReady) {
    if (!mounted || !startupReady) return;
    if (!_isDataReady) {
      final settings = ref.read(settingsStateProvider).value;
      final showLocal = settings?.showLocalLibrary ?? true;
      final showAsmr = settings?.showAsmrOne ?? true;
      final destinations = _resolveMainDestinations(
        showLocalLibrary: showLocal,
        showAsmrOne: showAsmr,
      );
      final startupPage = settings?.startupPage ?? StartupPage.library;
      final targetType = switch (startupPage) {
        StartupPage.library => showLocal
            ? MainDestinationType.library
            : (showAsmr
                ? MainDestinationType.asmrOne
                : MainDestinationType.playlist),
        StartupPage.asmrOne => showAsmr
            ? MainDestinationType.asmrOne
            : (showLocal
                ? MainDestinationType.library
                : MainDestinationType.playlist),
        StartupPage.playlist => MainDestinationType.playlist,
      };
      final startupIndex = destinations.indexWhere(
        (d) => d.type == targetType,
      );
      _activePageIndex.value = startupIndex >= 0 ? startupIndex : 0;
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
    _notificationFacade.setOpenSessionHandler(null);
    _activePageIndex.dispose();
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
    final view = _observedView;
    if (view != null &&
        view.physicalSize.width > 0 &&
        view.physicalSize.height > 0 &&
        view.devicePixelRatio > 0) {
      return view.physicalSize / view.devicePixelRatio;
    }
    return Size.zero;
  }

  double _currentLogicalKeyboardInset() {
    final view = _observedView;
    if (view != null && view.devicePixelRatio > 0) {
      return view.viewInsets.bottom / view.devicePixelRatio;
    }
    return 0;
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
    final candidates = playback.activeSessions
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
    if (subtitleTrack == null &&
        !subtitles.isLoading(session.currentTrackPath) &&
        !subtitles.hasResult(session.currentTrackPath)) {
      unawaited(subtitles.load(session.currentTrackPath));
    }
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
    if (state == AppLifecycleState.detached) {
      _appInForeground = false;
      unawaited(ref.read(audioRuntimeCoordinatorProvider).dispose());
      return;
    }
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

    ref
        .read(mainScreenControllerProvider)
        .requestStopScroll(_activePageIndex.value);

    final coordinator = UiInteractionCoordinator.instance;
    coordinator.beginInteraction(_pageSwitchInteraction);
    _pageSwitchCoordinatorGeneration = coordinator.beginGeneration();
    _activePageIndex.value = index;
    final destinations = _currentDestinations();
    if (index >= 0 &&
        index < destinations.length &&
        destinations[index].type == MainDestinationType.asmrOne) {
      unawaited(_showAsmrOnlineNoticeOnce());
    }
  }

  List<_MainDestination> _currentDestinations() {
    final settings = ref.read(settingsStateProvider).value;
    final showLocal = settings?.showLocalLibrary ?? true;
    final showAsmr = settings?.showAsmrOne ?? true;
    return _resolveMainDestinations(
      showLocalLibrary: showLocal,
      showAsmrOne: showAsmr,
    );
  }

  void _openLocalLibrary() {
    final destinations = _currentDestinations();
    final localIndex = destinations.indexWhere(
      (d) => d.type == MainDestinationType.library,
    );
    if (localIndex >= 0) {
      _switchPage(localIndex);
      return;
    }
    final asmrIndex = destinations.indexWhere(
      (d) => d.type == MainDestinationType.asmrOne,
    );
    if (asmrIndex >= 0) {
      _switchPage(asmrIndex);
    }
  }

  Widget _buildMainPage(
    BuildContext context,
    int index,
    List<_MainDestination> destinations,
  ) {
    if (index < 0 || index >= destinations.length) {
      return const SizedBox.shrink();
    }
    final dest = destinations[index];
    return switch (dest.type) {
      MainDestinationType.library => LibraryTab(
          key: const ValueKey<String>('audio_library_local_page'),
          tabIndex: index,
          activeTabIndexListenable: _activePageIndex,
        ),
      MainDestinationType.asmrOne => AsmrTab(
          key: const ValueKey<String>('audio_library_asmr_page'),
          tabIndex: index,
          activeTabIndexListenable: _activePageIndex,
        ),
      MainDestinationType.playlist => PlaylistTab(
          tabIndex: index,
          onTimerTap: _openTimerFromPlaylist,
          onOpenLibrary: _openLocalLibrary,
          activeTabIndexListenable: _activePageIndex,
        ),
      MainDestinationType.settings => SettingsTab(
          tabIndex: index,
          activeTabIndexListenable: _activePageIndex,
        ),
    };
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
        backgroundColor: Theme.of(context).colorScheme.surface,
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
                              child: _buildBody(isDesktop: isDesktop),
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
