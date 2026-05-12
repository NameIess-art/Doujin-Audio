import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/subtitle_settings_provider.dart';
import '../services/app_preferences.dart';
import '../services/audio_state_services.dart';
import '../services/permission_action_controller.dart';
import '../services/platform_channels.dart';
import 'library_tab.dart';
import 'playlist_tab.dart';
import 'settings_tab.dart';
import 'timer_tab.dart';
import '../widgets/active_session_carousel.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/snap_scroll_physics.dart';
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
  static const MethodChannel _powerChannel = MethodChannel(PowerChannel.name);
  static const MethodChannel _notificationsChannel = MethodChannel(
    NotificationsChannel.name,
  );

  int _currentIndex = 0;
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
  bool _manageFilesPermissionCheckDone = false;
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

  int? _pendingTargetIndex;
  void _setLocalState(VoidCallback fn) => setState(fn);

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
    _pages = [
      const LibraryTab(),
      PlaylistTab(onTimerTap: _openTimerFromPlaylist),
      const SettingsTab(),
    ];
    _pageController = PageController();
    WidgetsBinding.instance.addObserver(this);
    _notificationsChannel.setMethodCallHandler(_handleNotificationsChannelCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
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

  @override
  void dispose() {
    _pageController.dispose();
    _notificationSessionNavigationTimer?.cancel();
    _permissionActionController.dispose();
    _notificationsChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _needsMeasurement = true;
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
    _pendingTargetIndex = index;
    setState(() {
      _currentIndex = index;
    });
    if (!_pageController.hasClients) return;
    provider.setPageTransitioning(true);
    provider.triggerScrollToTop(index);
    _pageController
        .animateToPage(
          index,
          duration: _pageTransitionDuration,
          curve: _pageTransitionCurve,
        )
        .whenComplete(() {
          if (!mounted) return;
          provider.setPageTransitioning(false);
          provider.scheduleUiWarmup(currentPageIndex: index);
        });
  }

  List<PlaybackSession> _buildOverlaySessions(PlaybackStateSliceData? state) {
    if (state == null) return const <PlaybackSession>[];
    final sessions = state.activeSessions;
    if (state.multiThreadPlaybackEnabled || sessions.isEmpty) {
      return sessions;
    }
    final retainedSession = sessions.firstWhere(
      (session) => session.state.playing || session.isLoading,
      orElse: () => sessions.first,
    );
    return <PlaybackSession>[retainedSession];
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
    final playbackState = ref.watch(playbackStateProvider).valueOrNull;
    final settingsState = ref.watch(settingsStateProvider).valueOrNull;
    final overlaySessions = _buildOverlaySessions(playbackState);
    final activeSessionCount = playbackState?.activeSessions.length ?? 0;
    final showCard = settingsState?.showPlaybackCard ?? false;
    final visibleSessions = showCard ? overlaySessions : <PlaybackSession>[];
    if (_lastShowCard != showCard) {
      _lastShowCard = showCard;
      _needsMeasurement = true;
    }
    final subtitleSettings = ref.watch(subtitleSettingsProvider);
    final subtitleSessions = overlaySessions
        .where((session) => subtitleSettings.isGlobalEnabled(session.id))
        .toList(growable: false);
    final hasNowPlaying = visibleSessions.isNotEmpty;
    if (activeSessionCount > 0 &&
        !_notificationPermissionCheckDone &&
        !_notificationPermissionCheckQueued) {
      _notificationPermissionCheckQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureNotificationPermission();
      });
    }
    final timerSlice =
        ref.watch(timerStateProvider).valueOrNull ??
        const TimerStateSliceData();
    final timerState = _TimerPresentation(
      duration: timerSlice.duration,
      remaining: timerSlice.remaining,
      active: timerSlice.active,
      mode: timerSlice.mode,
    );

    if (!_isDataReady && (playbackState?.isInitialized ?? false)) {
      _isDataReady = true;
    }
    final width = MediaQuery.sizeOf(context).width;
    final height = MediaQuery.sizeOf(context).height;
    final isDesktop = width >= _desktopBreakpoint;
    final isSmallWindow = width < 450 || height < 400;
    final isTinyWindow = width < 300 || height < 300;
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
            if (isDesktop)
              Row(
                children: [
                  _buildDesktopNavigation(context, timerState, i18n),
                  Expanded(child: _buildAnimatedBody(isDesktop: true)),
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
                        shaderCallback: (bounds) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.white],
                          stops: [0, 0.45],
                        ).createShader(bounds),
                        child: RepaintBoundary(
                          child: isTinyWindow
                              ? const SizedBox.expand()
                              : BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: isSmallWindow ? 4.0 : 7.0,
                                    sigmaY: isSmallWindow ? 4.0 : 7.0,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                        ),
                      ),
                    ),
                  ),
                  _buildMobileBottomDock(
                    context,
                    i18n: i18n,
                    timerState: timerState,
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
    );
  }
}
