import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/app_preferences.dart';
import 'library_tab.dart';
import 'playlist_tab.dart';
import 'settings_tab.dart';
import 'timer_tab.dart';
import '../widgets/active_session_carousel.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const Duration _pageTransitionDuration = Duration(milliseconds: 300);
  static const Curve _pageTransitionCurve = Curves.easeInOutCubic;
  static const double _desktopBreakpoint = 980;
  static const Color _appleMusicAccent = Color(0xFFFF2D55);
  static const String _backgroundKeepAliveInitializedKey =
      'background_keep_alive_initialized_v2';
  static const MethodChannel _powerChannel = MethodChannel(
    'music_player/power',
  );
  static const MethodChannel _notificationsChannel = MethodChannel(
    'music_player/notifications',
  );

  int _currentIndex = 0;
  late final PageController _pageController;
  bool _notificationPermissionCheckDone = false;
  bool _notificationPermissionCheckQueued = false;
  bool _notificationSettingsDialogVisible = false;
  bool _notificationSettingsOpened = false;
  Timer? _notificationSessionNavigationTimer;
  String? _pendingNotificationSessionId;
  String? _lastOpenedNotificationSessionId;
  DateTime? _lastOpenedNotificationAt;

  final List<Widget> _pages = const [
    LibraryTab(),
    PlaylistTab(),
    SettingsTab(),
  ];

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
    _pageController = PageController();
    WidgetsBinding.instance.addObserver(this);
    _notificationsChannel.setMethodCallHandler(_handleNotificationsChannelCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePendingNotificationSession());
      unawaited(_maybeEnableBackgroundKeepAliveOnFirstLaunch());
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _notificationSessionNavigationTimer?.cancel();
    _notificationsChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(_consumePendingNotificationSession());
    final provider = context.read<AudioProvider>();
    provider.resyncNotificationsAfterResume();
    if (!_notificationSettingsOpened) {
      return;
    }
    _notificationSettingsOpened = false;
    _handleNotificationSettingsReturn();
  }

  void _switchPage(int index, {bool withFeedback = true}) {
    if (index == _currentIndex) return;
    if (withFeedback) {
      Feedback.forTap(context);
    }
    setState(() {
      _currentIndex = index;
    });
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      index,
      duration: _pageTransitionDuration,
      curve: _pageTransitionCurve,
    );
  }

  Future<bool> _areNotificationsEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _notificationsChannel.invokeMethod<bool>(
            'areNotificationsEnabled',
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _powerChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _powerChannel.invokeMethod<bool>('openBatteryOptimizationSettings');
    } catch (_) {}
  }

  Future<void> _maybeEnableBackgroundKeepAliveOnFirstLaunch() async {
    if (!mounted || !Platform.isAndroid) return;
    final initialized =
        await AppPreferences.getBool(_backgroundKeepAliveInitializedKey) ??
        false;
    if (initialized) return;
    await AppPreferences.setBool(_backgroundKeepAliveInitializedKey, true);
    final ignoringBatteryOptimizations =
        await _isIgnoringBatteryOptimizations();
    if (!mounted || ignoringBatteryOptimizations) return;
    await _openBatteryOptimizationSettings();
  }

  Future<void> _openNotificationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      final opened =
          await _notificationsChannel.invokeMethod<bool>(
            'openNotificationSettings',
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
    final provider = context.read<AudioProvider>();

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
    final audioProvider = context.read<AudioProvider>();
    final enabled = await _areNotificationsEnabled();
    if (!mounted || !enabled) return;
    audioProvider.refreshNotificationState();
    _showNotificationPermissionEnabledSnack();
  }

  Future<dynamic> _handleNotificationsChannelCall(MethodCall call) async {
    switch (call.method) {
      case 'openSessionFromNotification':
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
      final sessionId = await _notificationsChannel.invokeMethod<String>(
        'consumePendingNotificationSessionId',
      );
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
    final provider = context.read<AudioProvider>();
    if (provider.sessionById(sessionId) == null) {
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

  Widget _buildAnimatedBody({required bool isDesktop}) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(isDesktop ? 28 : 24);

    Widget pageShell(int index) {
      return Align(
        alignment: Alignment.topCenter,
        child: isDesktop
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: radius,
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.85),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withValues(alpha: 0.1),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: RepaintBoundary(child: _pages[index]),
                    ),
                  ),
                ),
              )
            : RepaintBoundary(child: _pages[index]),
      );
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: _pages.length,
      physics: const PageScrollPhysics(parent: ClampingScrollPhysics()),
      onPageChanged: (index) {
        if (_currentIndex == index) return;
        setState(() {
          _currentIndex = index;
        });
      },
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _pageController,
          builder: (context, child) {
            double pageOffset = 0;
            if (_pageController.hasClients &&
                _pageController.position.haveDimensions) {
              pageOffset =
                  ((_pageController.page ?? _currentIndex.toDouble()) - index)
                      .toDouble();
            } else {
              pageOffset = (_currentIndex - index).toDouble();
            }
            final clampedOffset = pageOffset.clamp(-1.0, 1.0).toDouble();
            final opacity = (1 - (clampedOffset.abs() * 0.16))
                .clamp(0.0, 1.0)
                .toDouble();
            final scale = 1 - (clampedOffset.abs() * 0.018);

            return Opacity(
              opacity: opacity,
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: pageShell(index),
        );
      },
    );
  }

  Future<void> _openTimerSettingsPage(
    BuildContext context,
    _TimerPresentation timerState,
  ) {
    final i18n = context.read<AppLanguageProvider>();
    final mediaSize = MediaQuery.sizeOf(context);
    final isDesktop = mediaSize.width >= _desktopBreakpoint;

    return showGeneralDialog<void>(
      context: context,
      barrierLabel: i18n.tr('close'),
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return _TimerOverlaySheet(
          isDesktop: isDesktop,
          animation: animation,
          openDetail: timerState.duration != null,
        );
      },
    ).then((_) {});
  }

  String _fmtDuration(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:$m:$s';
    }
    return '$m:$s';
  }

  String _timerFabLabel(
    _TimerPresentation timerState,
    AppLanguageProvider i18n,
  ) {
    final configured = timerState.duration != null;
    if (!configured) return i18n.tr('timer');

    final remaining = timerState.remaining ?? timerState.duration!;
    if (timerState.active) {
      return _fmtDuration(remaining);
    }
    if (remaining <= Duration.zero) {
      return i18n.tr('done');
    }
    if (timerState.mode == TimerMode.trigger) {
      return i18n.tr('timer_play_plus', {'time': _fmtDuration(remaining)});
    }
    return _fmtDuration(remaining);
  }

  Widget _buildBottomBar(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final items = _destinations.asMap().entries.map((entry) {
      final index = entry.key;
      final item = entry.value;
      final selected = index == _currentIndex;
      final label = i18n.tr(item.labelKey);
      final inactive = Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6);

      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Semantics(
            button: true,
            selected: selected,
            label: label,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _switchPage(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? _appleMusicAccent.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected
                          ? _appleMusicAccent.withValues(alpha: 0.24)
                          : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: animation,
                            child: child,
                          ),
                        ),
                        child: Icon(
                          selected ? item.selectedIcon : item.icon,
                          key: ValueKey<bool>(selected),
                          size: 21,
                          color: selected ? _appleMusicAccent : inactive,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 9.4,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          letterSpacing: 0.1,
                          color: selected ? _appleMusicAccent : inactive,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 0, 3, 0),
      child: Row(children: items),
    );
  }

  Widget _buildMobileBottomDock(
    BuildContext context, {
    required AppLanguageProvider i18n,
    required _TimerPresentation timerState,
    required List<PlaybackSession> overlaySessions,
    required bool showTimerChip,
  }) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTimerChip)
                Align(
                  alignment: Alignment.centerRight,
                  child: _DockTimerChip(
                    label: _timerFabLabel(timerState, i18n),
                    onTap: () => _openTimerSettingsPage(context, timerState),
                  ),
                ),
              if (showTimerChip)
                SizedBox(height: overlaySessions.isNotEmpty ? 8 : 14),
              if (overlaySessions.isNotEmpty)
                ActiveSessionCarousel(
                  sessions: overlaySessions,
                  provider: context.read<AudioProvider>(),
                  i18n: i18n,
                  onOpenSession: (sessionId) {
                    Navigator.of(
                      context,
                    ).push(buildSessionDetailRoute(sessionId: sessionId));
                  },
                ),
              if (overlaySessions.isNotEmpty) const SizedBox(height: 6),
              _FloatingGlassPanel(
                radius: 24,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                borderOpacity: 0.8,
                shadowOpacity: 0.11,
                showTopHighlight: false,
                primaryFillOpacity: 1,
                secondaryFillOpacity: 0.82,
                child: _buildBottomBar(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopNavigation(
    BuildContext context,
    _TimerPresentation timerState,
    AppLanguageProvider i18n,
  ) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: 292,
      margin: const EdgeInsets.fromLTRB(16, 18, 8, 18),
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.1),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    i18n.tr('asmr_player'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: NavigationRail(
              backgroundColor: Colors.transparent,
              selectedIndex: _currentIndex,
              onDestinationSelected: _switchPage,
              extended: true,
              minExtendedWidth: 256,
              useIndicator: true,
              groupAlignment: -0.86,
              destinations: _destinations
                  .map(
                    (item) => NavigationRailDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: Text(i18n.tr(item.labelKey)),
                    ),
                  )
                  .toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: _DesktopQuickAction(
              icon: Icons.timer_rounded,
              title: _timerFabLabel(timerState, i18n),
              subtitle: i18n.tr('timer'),
              onTap: () => _openTimerSettingsPage(context, timerState),
            ),
          ),
        ],
      ),
    );
  }

  double _mobileContentInset({
    required bool hasNowPlaying,
    required bool hasTimerChip,
  }) {
    if (hasNowPlaying && hasTimerChip) return 248;
    if (hasNowPlaying) return 196;
    if (hasTimerChip) return 156;
    return 112;
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
    final overlaySessions = context
        .select<AudioProvider, List<PlaybackSession>>((provider) {
          final sessions = provider.activeSessions;
          if (provider.multiThreadPlaybackEnabled || sessions.isEmpty) {
            return sessions.toList(growable: false);
          }
          final retainedSession = sessions.firstWhere(
            (session) => session.state.playing || session.isLoading,
            orElse: () => sessions.first,
          );
          return <PlaybackSession>[retainedSession];
        });
    final activeSessionCount = context.select<AudioProvider, int>(
      (provider) => provider.activeSessions.length,
    );
    final hasNowPlaying = overlaySessions.isNotEmpty;
    if (activeSessionCount > 0 &&
        !_notificationPermissionCheckDone &&
        !_notificationPermissionCheckQueued) {
      _notificationPermissionCheckQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureNotificationPermission();
      });
    }
    final timerState = context.select<AudioProvider, _TimerPresentation>(
      (provider) => _TimerPresentation(
        duration: provider.timerDuration,
        remaining: provider.timerRemaining,
        active: provider.timerActive,
        mode: provider.timerMode,
      ),
    );
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= _desktopBreakpoint;
    final showTimerChip = !isDesktop && _currentIndex == 1;
    final mobileContentInset = isDesktop
        ? 0.0
        : _mobileContentInset(
            hasNowPlaying: hasNowPlaying,
            hasTimerChip: showTimerChip,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        extendBody: !isDesktop,
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _AmbientBackground(),
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
                  _buildMobileBottomDock(
                    context,
                    i18n: i18n,
                    timerState: timerState,
                    overlaySessions: overlaySessions,
                    showTimerChip: showTimerChip,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.surface,
            cs.surfaceContainer.withValues(alpha: 0.94),
            cs.surfaceContainerLow,
          ],
          stops: const [0, 0.5, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -96,
            top: -64,
            child: _GlowOrb(
              color: cs.primary.withValues(alpha: 0.08),
              size: 220,
            ),
          ),
          Positioned(
            right: -72,
            bottom: -86,
            child: _GlowOrb(
              color: cs.tertiary.withValues(alpha: 0.07),
              size: 196,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}

class _DesktopQuickAction extends StatelessWidget {
  const _DesktopQuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Feedback.forTap(context);
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: cs.onSecondaryContainer, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _MainDestination {
  const _MainDestination({
    required this.icon,
    required this.selectedIcon,
    required this.labelKey,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String labelKey;
}

class _TimerPresentation {
  const _TimerPresentation({
    required this.duration,
    required this.remaining,
    required this.active,
    required this.mode,
  });

  final Duration? duration;
  final Duration? remaining;
  final bool active;
  final TimerMode? mode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _TimerPresentation &&
        other.duration == duration &&
        other.remaining == remaining &&
        other.active == active &&
        other.mode == mode;
  }

  @override
  int get hashCode => Object.hash(duration, remaining, active, mode);
}

class _FloatingGlassPanel extends StatelessWidget {
  const _FloatingGlassPanel({
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.borderOpacity = 0.42,
    this.shadowOpacity = 0.22,
    this.showTopHighlight = true,
    this.primaryFillOpacity = 0.22,
    this.secondaryFillOpacity = 0.10,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double borderOpacity;
  final double shadowOpacity;
  final bool showTopHighlight;
  final double primaryFillOpacity;
  final double secondaryFillOpacity;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillAlpha = isDark ? 0.42 : 0.62;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.surfaceContainerLow.withValues(
                  alpha: (primaryFillOpacity * fillAlpha).clamp(0.0, 0.92),
                ),
                cs.surfaceContainer.withValues(
                  alpha: (secondaryFillOpacity * fillAlpha).clamp(0.0, 0.82),
                ),
              ],
            ),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: borderOpacity),
            ),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: shadowOpacity),
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (showTopHighlight)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(alpha: 0.12),
                            Colors.white.withValues(alpha: 0),
                          ],
                          stops: const [0, 0.24],
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockTimerChip extends StatelessWidget {
  const _DockTimerChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return _FloatingGlassPanel(
      radius: 20,
      borderOpacity: 0.72,
      shadowOpacity: 0.08,
      showTopHighlight: false,
      primaryFillOpacity: 1,
      secondaryFillOpacity: 0.84,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Feedback.forTap(context);
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.timer_rounded, size: 18, color: cs.onSurface),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TimerOverlaySheet extends StatelessWidget {
  const _TimerOverlaySheet({
    required this.isDesktop,
    required this.animation,
    required this.openDetail,
  });

  final bool isDesktop;
  final Animation<double> animation;
  final bool openDetail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxWidth = isDesktop ? 472.0 : 404.0;
    final outerPadding = EdgeInsets.fromLTRB(
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 176,
      isDesktop ? 28 : 16,
      isDesktop ? 28 : 132,
    );
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) {
          final progress = curved.value.clamp(0.0, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.scrim.withValues(
                            alpha: 0.08 + (0.14 * progress),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: progress,
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                child: FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.035),
                      end: Offset.zero,
                    ).animate(curved),
                    child: Padding(
                      padding: outerPadding,
                      child: Align(
                        alignment: isDesktop
                            ? Alignment.center
                            : Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          child: TimerTab(
                            showHeader: false,
                            useSafeArea: false,
                            compactOnly: true,
                            initialCompactDetail: openDetail,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
