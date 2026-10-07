import '../../features/player/presentation/playback_providers.dart';
import '../../features/settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../localization/app_language_provider.dart';
import '../state/app_runtime_providers.dart';
import 'app_presentation_providers.dart';
import '../state/subtitle_settings_provider.dart';
import '../../core/persistence/app_preferences.dart';
import '../../features/settings/application/permission_status_service.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/player/application/playback_session_snapshot.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/player/application/subtitle_overlay_controller.dart';
import '../../core/ui/permission_action_controller.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/ui/ui_operation_service.dart';
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
import '../../features/player/presentation/bedtime_canvas_page.dart';

import 'mobile_dock_capsule_content.dart';
import 'main_destination.dart';
import 'desktop_main_navigation.dart';
import 'app_dock_panel.dart';
export 'main_destination.dart' show MainDestinationType;
export 'app_dock_panel.dart';

part 'main_screen_permissions.dart';
part 'main_screen_layout.dart';
part 'main_screen_widgets.dart';

@visibleForTesting
bool shouldRunGlobalSubtitleOverlay({required bool appInForeground}) {
  return defaultTargetPlatform == TargetPlatform.windows || !appInForeground;
}

class PlaybackDockGeometryController extends ChangeNotifier {
  Rect? get mainCoverRect => _mainCoverRect;
  Rect? get mainDockRect => _mainDockRect;
  Rect? get mainExpandedDockRect => _mainExpandedDockRect;
  bool get mainDockCollapsed => _mainDockCollapsed;
  double? get mainDockRight => _mainDockRect?.right;
  Rect? _mainCoverRect;
  Rect? _mainDockRect;
  Rect? _mainExpandedDockRect;
  bool _mainDockCollapsed = false;

  void updateMainGeometry({
    required Rect coverRect,
    required Rect dockRect,
    Rect? expandedDockRect,
    bool dockCollapsed = false,
  }) {
    final resolvedExpandedDockRect = expandedDockRect ?? dockRect;
    if (_mainCoverRect == coverRect &&
        _mainDockRect == dockRect &&
        _mainExpandedDockRect == resolvedExpandedDockRect &&
        _mainDockCollapsed == dockCollapsed) {
      return;
    }
    _mainCoverRect = coverRect;
    _mainDockRect = dockRect;
    _mainExpandedDockRect = resolvedExpandedDockRect;
    _mainDockCollapsed = dockCollapsed;
    notifyListeners();
  }
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key, this.playbackDockGeometry});

  final PlaybackDockGeometryController? playbackDockGeometry;

  @visibleForTesting
  static Duration sleepModeAutoTriggerDelay = const Duration(minutes: 5);

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  static const double _desktopBreakpoint = 980;
  double _stablePortraitTopPadding = 0;
  bool _isMenuCollapsed = false;
  final List<LayerLink> _menuIconLinks = List<LayerLink>.generate(
    MainDestinationType.values.length,
    (_) => LayerLink(),
  );
  final List<GlobalKey> _menuIconKeys = List<GlobalKey>.generate(
    MainDestinationType.values.length,
    (_) => GlobalKey(),
  );
  final List<Offset> _menuIconCenters = List<Offset>.filled(
    MainDestinationType.values.length,
    Offset.zero,
  );
  bool _isMobilePlaybackExpanded = false;
  late final ValueNotifier<int> _activePageIndex;
  final Object _pageSwitchInteraction = Object();
  final Object _foregroundInteraction = Object();
  int _foregroundInteractionGeneration = 0;
  final GlobalKey _dockContentKey = GlobalKey();
  final GlobalKey _mobilePlaybackGeometryKey = GlobalKey();
  final GlobalKey _desktopPlaybackGeometryKey = GlobalKey();
  int _pageSwitchCoordinatorGeneration = 0;

  Offset _menuIconCollapseOffset(
    MainDestinationType source,
    MainDestinationType target,
  ) => _menuIconCenters[target.index] - _menuIconCenters[source.index];

  void _reportMobilePlaybackCoverRect() {
    final geometry = widget.playbackDockGeometry;
    if (geometry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box =
          _mobilePlaybackGeometryKey.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) return;
      const inset = 4.0;
      final origin = box.localToGlobal(Offset.zero);
      geometry.updateMainGeometry(
        coverRect:
            origin + const Offset(inset, inset) &
            Size.square(box.size.height - inset * 2),
        dockRect: origin & box.size,
        dockCollapsed: !_isMobilePlaybackExpanded,
      );
    });
  }

  void _reportDesktopPlaybackRect({
    required bool dockCollapsed,
    required double dockAreaWidth,
    required double expandedDockWidth,
  }) {
    final geometry = widget.playbackDockGeometry;
    if (geometry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box =
          _desktopPlaybackGeometryKey.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) return;
      const inset = 4.0;
      final origin = box.localToGlobal(Offset.zero);
      final collapsedLeadingInset = dockCollapsed
          ? (dockAreaWidth - box.size.width) / 2
          : 0.0;
      final expandedOrigin = dockCollapsed
          ? origin - Offset(collapsedLeadingInset, 0)
          : origin;
      geometry.updateMainGeometry(
        coverRect:
            origin + const Offset(inset, inset) &
            Size.square(box.size.height - inset * 2),
        dockRect: origin & box.size,
        expandedDockRect:
            expandedOrigin & Size(expandedDockWidth, box.size.height),
        dockCollapsed: dockCollapsed,
      );
    });
  }

  bool _backgroundPlaybackPromptShownThisLaunch = false;
  bool _backgroundPlaybackPromptQueued = false;
  bool _autoUpdateCheckQueued = false;
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  late final AppUpdateFlow _updateFlow;
  late final SubtitleOverlayController _subtitleOverlay;

  bool _isDataReady = false;
  Timer? _metricsRecoveryTimer;
  Size? _lastRecoveredViewSize;
  FlutterView? _observedView;
  bool _appInForeground = true;
  Timer? _sleepModeAutoEntryTimer;
  bool _sleepModeAutoEntryTriggeredThisRun = false;
  SleepModeAutoTrigger? _lastSleepModeTrigger;

  @override
  void initState() {
    super.initState();
    _protectForegroundFrame();
    _subtitleOverlay = ref.read(subtitleOverlayControllerProvider);
    _subtitleOverlay.attachRuntime(
      enabled: () =>
          mounted &&
          shouldRunGlobalSubtitleOverlay(appInForeground: _appInForeground),
      session: () => ref.read(globalSubtitleOverlaySessionProvider)?.session,
      subtitles: () => ref.read(playbackSubtitleServiceProvider),
      style: _globalSubtitleStyle,
    );
    ref.listenManual(globalSubtitleOverlaySessionProvider, (_, _) {
      _subtitleOverlay.requestRuntimeSync();
    });
    ref.listenManual<SubtitleSettingsState>(subtitleSettingsProvider, (_, _) {
      _subtitleOverlay.requestRuntimeSync();
    });
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
    ref.listenManual<bool>(
      mainOverlayUiProvider.select((state) => state.hasPlayingSession),
      (_, hasPlayingSession) => _handlePlayingSessionChanged(hasPlayingSession),
      fireImmediately: true,
    );
    if (defaultTargetPlatform != TargetPlatform.windows) {
      ref.listenManual<bool>(
        mainOverlayUiProvider.select((state) => state.hasPlayingAudioSession),
        (_, _) => _evaluateSleepModeAutoTrigger(),
        fireImmediately: true,
      );
    }
    ref.listenManual<bool>(
      mainOverlayUiProvider.select((state) => state.hasNowPlaying),
      (_, hasNowPlaying) {
        if (!hasNowPlaying && _isMobilePlaybackExpanded && mounted) {
          setState(() => _isMobilePlaybackExpanded = false);
        }
      },
      fireImmediately: true,
    );
    if (defaultTargetPlatform != TargetPlatform.windows) {
      ref.listenManual<SleepModeAutoTrigger>(
        settingsStateProvider.select(
          (value) =>
              value.value?.sleepModeAutoTrigger ?? SleepModeAutoTrigger.manual,
        ),
        (_, _) => _evaluateSleepModeAutoTrigger(),
        fireImmediately: true,
      );
      ref.listenManual<bool>(
        timerStateProvider.select((state) => state.value?.active ?? false),
        (_, _) => _evaluateSleepModeAutoTrigger(),
        fireImmediately: true,
      );
    }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rememberCurrentViewMetrics();
      final warmup = ref.read(audioUiWarmupCoordinatorProvider);
      _subtitleOverlay.requestRuntimeSync();
      Future.delayed(const Duration(milliseconds: 750), () {
        if (!mounted) return;
        warmup.schedule(isPlaybackPage: _isPlaybackPage, immediate: true);
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
      final destinations = resolveMainDestinations(
        showLocalLibrary: showLocal,
        showAsmrOne: showAsmr,
      );
      final startupPage = settings?.startupPage ?? StartupPage.library;
      final targetType = switch (startupPage) {
        StartupPage.library =>
          showLocal
              ? MainDestinationType.library
              : (showAsmr
                    ? MainDestinationType.asmrOne
                    : MainDestinationType.playlist),
        StartupPage.asmrOne =>
          showAsmr
              ? MainDestinationType.asmrOne
              : (showLocal
                    ? MainDestinationType.library
                    : MainDestinationType.playlist),
        StartupPage.playlist => MainDestinationType.playlist,
      };
      final savedDestination = ref
          .read(browsePageStateStoreProvider)
          .stateFor('main')['destination'];
      final restoredIndex = destinations.indexWhere(
        (d) => d.type.name == savedDestination,
      );
      final startupIndex = restoredIndex >= 0
          ? restoredIndex
          : destinations.indexWhere((d) => d.type == targetType);
      _activePageIndex.value = startupIndex >= 0 ? startupIndex : 0;
      setState(() => _isDataReady = true);
    }
    _queueAutoUpdateCheckIfReady();
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

  void _evaluateSleepModeAutoTrigger() {
    if (!mounted || defaultTargetPlatform == TargetPlatform.windows) return;
    final settings = ref.read(settingsStateProvider).value;
    final trigger =
        settings?.sleepModeAutoTrigger ?? SleepModeAutoTrigger.manual;
    if (_lastSleepModeTrigger != trigger) {
      _sleepModeAutoEntryTimer?.cancel();
      _sleepModeAutoEntryTimer = null;
      _sleepModeAutoEntryTriggeredThisRun = false;
      _lastSleepModeTrigger = trigger;
    }

    final hasPlaying = ref.read(mainOverlayUiProvider).hasPlayingAudioSession;
    final timerActive =
        ref.read(timerStateProvider).value?.active ??
        ref.read(timerFacadeProvider).state.active;

    final shouldRun = switch (trigger) {
      SleepModeAutoTrigger.manual => false,
      SleepModeAutoTrigger.afterPlayback5min => hasPlaying,
      SleepModeAutoTrigger.afterCountdown5min => timerActive && hasPlaying,
    };

    if (!shouldRun) {
      _sleepModeAutoEntryTimer?.cancel();
      _sleepModeAutoEntryTimer = null;
      _sleepModeAutoEntryTriggeredThisRun = false;
      return;
    }

    if (_sleepModeAutoEntryTriggeredThisRun ||
        BedtimeCanvasPage.isCanvasActive) {
      return;
    }

    _sleepModeAutoEntryTimer ??= Timer(
      MainScreen.sleepModeAutoTriggerDelay,
      _onSleepModeAutoEntryTimerFired,
    );
  }

  void _onSleepModeAutoEntryTimerFired() {
    _sleepModeAutoEntryTimer = null;
    if (!mounted || defaultTargetPlatform == TargetPlatform.windows) return;
    final settings = ref.read(settingsStateProvider).value;
    final trigger =
        settings?.sleepModeAutoTrigger ?? SleepModeAutoTrigger.manual;
    final hasPlaying = ref.read(mainOverlayUiProvider).hasPlayingAudioSession;
    final timerActive =
        ref.read(timerStateProvider).value?.active ??
        ref.read(timerFacadeProvider).state.active;

    final conditionMet = switch (trigger) {
      SleepModeAutoTrigger.manual => false,
      SleepModeAutoTrigger.afterPlayback5min => hasPlaying,
      SleepModeAutoTrigger.afterCountdown5min => timerActive && hasPlaying,
    };

    if (!conditionMet) return;
    _sleepModeAutoEntryTriggeredThisRun = true;
    if (BedtimeCanvasPage.isCanvasActive) return;
    Navigator.of(context).push(BedtimeCanvasPage.route(context));
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
    // Rail destination spacing stays fixed during extension; sample it once.
    for (final destination in MainDestinationType.values) {
      final box =
          _menuIconKeys[destination.index].currentContext?.findRenderObject()
              as RenderBox?;
      if (box != null && box.hasSize) {
        _menuIconCenters[destination.index] = box.localToGlobal(
          box.size.center(Offset.zero),
        );
      }
    }
    setState(() {
      _isMenuCollapsed = !_isMenuCollapsed;
    });
    unawaited(
      AppPreferences.setBool('desktop_menu_collapsed', _isMenuCollapsed),
    );
  }

  void _showMobilePlayback() {
    if (_isMobilePlaybackExpanded) return;
    setState(() => _isMobilePlaybackExpanded = true);
  }

  void _showMobileDestinations() {
    if (!_isMobilePlaybackExpanded) return;
    setState(() => _isMobilePlaybackExpanded = false);
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
    _pageSwitchCoordinatorGeneration++;
    UiInteractionCoordinator.instance.cancelNavigation(_pageSwitchInteraction);
    _cancelForegroundProtection();
    _sleepModeAutoEntryTimer?.cancel();
    _sleepModeAutoEntryTimer = null;
    _metricsRecoveryTimer?.cancel();
    unawaited(_subtitleOverlay.detachRuntime());
    _permissionActionController.dispose();
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
          .schedule(isPlaybackPage: _isPlaybackPage, immediate: true);
    });
  }

  SubtitleOverlayRuntimeStyle _globalSubtitleStyle() {
    final settings = ref.read(subtitleSettingsProvider);
    final backgroundColor = (settings.backgroundColor ?? Colors.black)
        .withValues(alpha: settings.backgroundOpacity);
    final textColor = settings.fontColor ?? Colors.white;
    String colorValue(Color color) =>
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
    return (
      fontSize: settings.fontSize,
      backgroundColor: colorValue(backgroundColor),
      textColor: colorValue(textColor),
      backgroundOpacity: settings.backgroundOpacity,
      fontFamily: settings.fontFamily,
      borderDepth: settings.borderDepth,
    );
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(ref.read(audioRuntimeCoordinatorProvider).handleMemoryPressure());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _appInForeground = false;
      _cancelForegroundProtection();
      unawaited(ref.read(audioRuntimeCoordinatorProvider).dispose());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _appInForeground = false;
      _cancelForegroundProtection();
      unawaited(ref.read(audioRuntimeCoordinatorProvider).enterBackground());
      _subtitleOverlay.requestRuntimeSync();
      return;
    }
    if (state != AppLifecycleState.resumed) {
      return;
    }
    _appInForeground = true;
    // Keep cached content available for the first restored frame. Coalesced
    // presentation updates and warmup resume after that frame's idle period.
    _protectForegroundFrame();
    if (shouldRunGlobalSubtitleOverlay(appInForeground: _appInForeground)) {
      _subtitleOverlay.requestRuntimeSync();
    } else {
      unawaited(_subtitleOverlay.stopRuntime(immediate: true));
    }
    unawaited(_permissionActionController.handleAppResumed());
    unawaited(
      ref.read(audioRuntimeCoordinatorProvider).resumeForeground().then((_) {
        if (!mounted) return;
        final warmup = ref.read(audioUiWarmupCoordinatorProvider);
        warmup.schedule(isPlaybackPage: _isPlaybackPage, immediate: true);
      }),
    );
  }

  void _protectForegroundFrame() {
    final generation = ++_foregroundInteractionGeneration;
    final interaction = UiInteractionCoordinator.instance;
    interaction.beginInteraction(
      _foregroundInteraction,
      deferVisualUpdates: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _appInForeground &&
          generation == _foregroundInteractionGeneration) {
        interaction.endInteraction(_foregroundInteraction);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _cancelForegroundProtection() {
    _foregroundInteractionGeneration++;
    UiInteractionCoordinator.instance.cancelInteraction(_foregroundInteraction);
  }

  void _switchPage(int index) {
    if (!UiInteractionCoordinator.instance.navigationAllowed.value) return;
    if (index == _activePageIndex.value) {
      ref.read(mainScreenControllerProvider).requestScrollToTop(index);
      return;
    }

    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    ref
        .read(mainScreenControllerProvider)
        .requestStopScroll(_activePageIndex.value);

    final coordinator = UiInteractionCoordinator.instance;
    coordinator.beginNavigation(_pageSwitchInteraction);
    _pageSwitchCoordinatorGeneration = coordinator.beginGeneration();
    _activePageIndex.value = index;
    final destinations = _currentDestinations();
    if (index >= 0 && index < destinations.length) {
      ref.read(browsePageStateStoreProvider).update('main', {
        'destination': destinations[index].type.name,
      });
    }
    if (index >= 0 &&
        index < destinations.length &&
        destinations[index].type == MainDestinationType.asmrOne) {
      unawaited(_showAsmrOnlineNoticeOnce());
    }
  }

  List<MainDestination> _currentDestinations() {
    final settings = ref.read(settingsStateProvider).value;
    final showLocal = settings?.showLocalLibrary ?? true;
    final showAsmr = settings?.showAsmrOne ?? true;
    return resolveMainDestinations(
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
    List<MainDestination> destinations,
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
    final isPlaybackPage = _isPlaybackPage;
    coordinator.endNavigation(_pageSwitchInteraction);
    coordinator.scheduleAfterIdle(
      key: 'main_page_warmup_$index',
      generation: generation,
      priority: 0,
      task: () async {
        if (!mounted ||
            generation != _pageSwitchCoordinatorGeneration ||
            _activePageIndex.value != index) {
          return;
        }
        warmup.schedule(isPlaybackPage: isPlaybackPage, immediate: true);
      },
    );
  }

  bool get _isPlaybackPage {
    final destinations = _currentDestinations();
    final index = _activePageIndex.value;
    return index >= 0 &&
        index < destinations.length &&
        destinations[index].type == MainDestinationType.playlist;
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
    final layoutSize = _layoutViewSize();
    final width = layoutSize.width;
    final mediaQuery = MediaQuery.of(context);
    final rawTop = mediaQuery.padding.top;
    final isDesktop =
        defaultTargetPlatform == TargetPlatform.windows ||
        mediaQuery.orientation == Orientation.landscape ||
        width >= _desktopBreakpoint;
    final isTinyWindow = width < 300 || layoutSize.height < 300;
    final mobileContentInset = isDesktop ? 0.0 : _mobileContentInset();

    if (!isDesktop && rawTop > _stablePortraitTopPadding) {
      _stablePortraitTopPadding = rawTop;
    }

    final effectiveTop = !isDesktop && _stablePortraitTopPadding > 0
        ? max(rawTop, _stablePortraitTopPadding)
        : rawTop;
    final effectivePadding = effectiveTop != rawTop
        ? mediaQuery.padding.copyWith(top: effectiveTop)
        : mediaQuery.padding;
    final effectiveViewPadding = !isDesktop && _stablePortraitTopPadding > 0
        ? mediaQuery.viewPadding.copyWith(
            top: max(mediaQuery.viewPadding.top, _stablePortraitTopPadding),
          )
        : mediaQuery.viewPadding;
    final effectiveMediaQuery = mediaQuery.copyWith(
      padding: effectivePadding,
      viewPadding: effectiveViewPadding,
    );

    final content = MediaQuery(
      data: effectiveMediaQuery,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
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
                                  final overlaySessions = ref.watch(
                                    mainOverlayUiProvider.select(
                                      (state) => state.overlaySessions,
                                    ),
                                  );
                                  return _buildDesktopNavigation(
                                    context,
                                    i18n,
                                    overlaySessions,
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
                              final overlaySessions = ref.watch(
                                mainOverlayUiProvider.select(
                                  (state) => state.overlaySessions,
                                ),
                              );
                              return _buildMobileBottomDock(
                                context,
                                i18n: i18n,
                                overlaySessions: overlaySessions,
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
      ),
    );
    return MediaQuery.removeViewInsets(
      key: const ValueKey<String>('main_screen_keyboard_inset_boundary'),
      context: context,
      removeBottom: true,
      child: defaultTargetPlatform == TargetPlatform.windows
          ? CallbackShortcuts(
              bindings: {
                for (final (index, key) in [
                  LogicalKeyboardKey.digit1,
                  LogicalKeyboardKey.digit2,
                  LogicalKeyboardKey.digit3,
                  LogicalKeyboardKey.digit4,
                ].indexed)
                  SingleActivator(key, control: true): () {
                    if (index < _currentDestinations().length) {
                      _switchPage(index);
                    }
                  },
                for (final backwards in [false, true])
                  SingleActivator(
                    LogicalKeyboardKey.tab,
                    control: true,
                    shift: backwards,
                  ): () => _switchPage(
                    (_activePageIndex.value + (backwards ? -1 : 1)) %
                        _currentDestinations().length,
                  ),
              },
              child: Focus(
                autofocus: true,
                skipTraversal: true,
                child: content,
              ),
            )
          : content,
    );
  }
}
