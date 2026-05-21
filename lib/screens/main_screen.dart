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
import '../services/app_update_service.dart';
import '../services/audio_state_services.dart';
import '../services/permission_action_controller.dart';
import '../services/platform_channels.dart';
import 'asmr_tab.dart';
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
      await _ensureInstallPermissionThenRun(
        context,
        () => _downloadAndInstallUpdate(info),
      );
    }
  }

  Future<void> _downloadAndInstallUpdate(AppUpdateInfo info) async {
    final i18n = context.read<AppLanguageProvider>();
    File apkFile;
    try {
      apkFile = await AppUpdateService.downloadUpdate(info, onProgress: (_) {});
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
      final result = await AppUpdateService.installApk(apkFile);
      if (!mounted) return;
      if (result.needsPermission) {
        await _ensureInstallPermissionThenRun(
          context,
          () => _installDownloadedApk(apkFile),
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

  Future<void> _installDownloadedApk(File apkFile) async {
    if (!mounted) return;
    final i18n = context.read<AppLanguageProvider>();
    try {
      final result = await AppUpdateService.installApk(apkFile);
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
    if ((settingsState?.autoCheckUpdates ?? false) &&
        (playbackState?.isInitialized ?? false) &&
        !_autoUpdateCheckQueued) {
      _autoUpdateCheckQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_checkForUpdatesOnLaunch());
      });
    }
    final hasPlayingSession = (playbackState?.playingSessionCount ?? 0) > 0;
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
    if (hasPlayingSession &&
        !_backgroundPlaybackPromptShownThisLaunch &&
        !_backgroundPlaybackPromptQueued) {
      _backgroundPlaybackPromptQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybePromptForBackgroundPlaybackReliability());
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
    final isDesktop = width >= _desktopBreakpoint;
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
                              : const SizedBox.expand(),
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
