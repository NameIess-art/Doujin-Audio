import '../../core/widgets/mobile_overlay_inset.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_runtime_providers.dart';
import '../presentation/app_presentation_providers.dart';
import '../presentation/main_screen.dart';
import '../../features/library/presentation/work_detail_page.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../features/player/presentation/playlist_tab.dart';
import '../theme/app_styles.dart';

typedef RoutedPlaybackDockAppBuilder =
    Widget Function(
      BuildContext context,
      NavigatorObserver observer,
      PlaybackDockGeometryController geometry,
      Widget Function(BuildContext context, Widget child) wrapNavigator,
    );

class RoutedPlaybackDockHost extends ConsumerStatefulWidget {
  const RoutedPlaybackDockHost({
    super.key,
    required this.navigatorKey,
    required this.builder,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final RoutedPlaybackDockAppBuilder builder;

  @override
  ConsumerState<RoutedPlaybackDockHost> createState() =>
      _RoutedPlaybackDockHostState();
}

class _RoutedPlaybackDockHostState
    extends ConsumerState<RoutedPlaybackDockHost> {
  final _menuOverlayKey = GlobalKey<OverlayState>();
  final ValueNotifier<int> _routeRevision = ValueNotifier(0);
  late final _RootPageRouteObserver _routeObserver;
  late final PlaybackDockGeometryController _playbackDockGeometry;
  OverlayEntry? _routedPlaybackDockEntry;
  PageRoute<dynamic>? _routedPlaybackDockRoute;
  bool _routedPlaybackDockSyncScheduled = false;
  @override
  void initState() {
    super.initState();
    _routeObserver = _RootPageRouteObserver(_routeRevision);
    // Keep the dock below newly pushed routes before their first frame.
    _routeRevision.addListener(_syncRoutedPlaybackDock);
    _playbackDockGeometry = PlaybackDockGeometryController();
  }

  @override
  void dispose() {
    _routedPlaybackDockEntry?.remove();
    _routedPlaybackDockEntry?.dispose();
    _routeObserver.dispose();
    _playbackDockGeometry.dispose();
    _routeRevision.removeListener(_syncRoutedPlaybackDock);
    _routeRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    _routeObserver,
    _playbackDockGeometry,
    _wrapNavigator,
  );

  void _scheduleRoutedPlaybackDockSync() {
    _routedPlaybackDockEntry?.markNeedsBuild();
    if (_routedPlaybackDockSyncScheduled) return;
    _routedPlaybackDockSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routedPlaybackDockSyncScheduled = false;
      if (mounted) _syncRoutedPlaybackDock();
    });
  }

  void _syncRoutedPlaybackDock() {
    if (_routeObserver.suppressDockForSessionDetail) return;
    final workDetailRoute = _routeObserver.lastRouteNamed(workDetailRouteName);
    if (workDetailRoute == null) {
      final departingRoute = _routedPlaybackDockRoute;
      if (departingRoute != null) {
        final isDismissed =
            departingRoute.animation?.status == AnimationStatus.dismissed ||
            !_routeObserver.isWorkDetailDeparting;
        if (isDismissed) {
          _removeRoutedPlaybackDock();
          return;
        }
        _routedPlaybackDockEntry?.markNeedsBuild();
        unawaited(
          departingRoute.completed.then((_) {
            if (!mounted ||
                _routedPlaybackDockRoute != departingRoute ||
                _routeObserver.containsRouteNamed(workDetailRouteName)) {
              return;
            }
            _removeRoutedPlaybackDock();
            setState(() {});
          }),
        );
      } else {
        _removeRoutedPlaybackDock();
      }
      return;
    }
    if (_routedPlaybackDockRoute == workDetailRoute &&
        _routedPlaybackDockEntry != null) {
      final overlay = widget.navigatorKey.currentState?.overlay;
      final entry = _routedPlaybackDockEntry!;
      if (overlay != null && entry.mounted) {
        final orderedEntries = <OverlayEntry>[];
        for (final route in _routeObserver.routes) {
          orderedEntries.addAll(route.overlayEntries);
          if (identical(route, workDetailRoute)) orderedEntries.add(entry);
        }
        for (final route in _routeObserver._departingWorkDetailRoutes) {
          orderedEntries.addAll(route.overlayEntries);
          if (identical(route, workDetailRoute)) orderedEntries.add(entry);
        }
        overlay.rearrange(orderedEntries);
      }
      return;
    }

    _removeRoutedPlaybackDock();
    final overlay = widget.navigatorKey.currentState?.overlay;
    if (overlay == null || workDetailRoute.overlayEntries.isEmpty) {
      _scheduleRoutedPlaybackDockSync();
      return;
    }
    final entry = OverlayEntry(
      maintainState: true,
      builder: _buildRoutedPlaybackDockOverlay,
    );
    _routedPlaybackDockRoute = workDetailRoute;
    _routedPlaybackDockEntry = entry;
    overlay.insert(entry, above: workDetailRoute.overlayEntries.last);
  }

  void _removeRoutedPlaybackDock() {
    final entry = _routedPlaybackDockEntry;
    _routedPlaybackDockEntry = null;
    _routedPlaybackDockRoute = null;
    entry?.remove();
    entry?.dispose();
  }

  Widget _buildRoutedPlaybackDockOverlay(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final supportsRoutedDock =
        mediaQuery.size.width >= 300 && mediaQuery.size.height >= 300;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ValueListenableBuilder<int>(
        valueListenable: _routeRevision,
        builder: (context, _, _) {
          final routeActive = _routeObserver.containsRouteNamed(
            workDetailRouteName,
          );
          final routeAboveWorkDetail = _routeObserver.hasRouteAboveNamed(
            workDetailRouteName,
          );
          final routeDeparting = _routeObserver.isWorkDetailDeparting;
          return Consumer(
            builder: (context, ref, _) => Opacity(
              opacity: _routeObserver.suppressDockForSessionDetail ? 0 : 1,
              child: _RoutedPlaybackDock(
                active:
                    routeActive &&
                    supportsRoutedDock &&
                    ref.watch(
                      mainOverlayUiProvider.select(
                        (state) => state.overlaySessions.isNotEmpty,
                      ),
                    ),
                covered: routeAboveWorkDetail,
                departing: routeDeparting,
                navigatorKey: widget.navigatorKey,
                currentRoute: _routeObserver.topRoute,
                geometry: _playbackDockGeometry,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _wrapNavigator(BuildContext context, Widget child) {
    final mediaQuery = MediaQuery.of(context);
    final hasOverlaySessions = ref.watch(
      mainOverlayUiProvider.select((state) => state.overlaySessions.isNotEmpty),
    );
    return ValueListenableBuilder<int>(
      valueListenable: _routeRevision,
      child: child,
      builder: (context, revision, navigatorChild) {
        final isWorkDetailRoute =
            _routeObserver.topRoute?.settings.name == workDetailRouteName ||
            _routeObserver.isWorkDetailDeparting;
        final supportsRoutedDock =
            mediaQuery.size.width >= 300 && mediaQuery.size.height >= 300;
        final reserveWorkDetailDockInset =
            isWorkDetailRoute && supportsRoutedDock && hasOverlaySessions;
        final routeDockInset = reserveWorkDetailDockInset
            ? kActiveSessionCarouselDockHeight +
                  kMobileDockBottomMargin +
                  6 +
                  mediaQuery.padding.bottom
            : 0.0;
        return MobileOverlayInset(
          bottomInset: routeDockInset,
          menuOverlayKey: _menuOverlayKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: navigatorChild!,
              ),
              Overlay(key: _menuOverlayKey),
            ],
          ),
        );
      },
    );
  }
}

class _RootPageRouteObserver extends NavigatorObserver {
  _RootPageRouteObserver(this.revision);

  final ValueNotifier<int> revision;
  final List<PageRoute<dynamic>> _routes = <PageRoute<dynamic>>[];
  final Map<PageRoute<dynamic>, (Animation<double>, AnimationStatusListener)>
  _routeAnimationListeners = {};
  final Set<PageRoute<dynamic>> _departingRoutes = {};
  final Set<PageRoute<dynamic>> _departingWorkDetailRoutes = {};
  // A popup makes Navigator move the work detail dock above the detail page.
  bool _suppressDockForSessionDetail = false;
  bool _syncScheduled = false;
  bool _disposed = false;

  PageRoute<dynamic>? get topRoute => _routes.lastOrNull;
  List<PageRoute<dynamic>> get routes => List.unmodifiable(_routes);
  bool get suppressDockForSessionDetail => _suppressDockForSessionDetail;
  bool get isWorkDetailDeparting => _departingWorkDetailRoutes.isNotEmpty;

  PageRoute<dynamic>? lastRouteNamed(String name) {
    for (var index = _routes.length - 1; index >= 0; index--) {
      final route = _routes[index];
      if (route.settings.name == name) return route;
    }
    if (name == workDetailRouteName && _departingWorkDetailRoutes.isNotEmpty) {
      return _departingWorkDetailRoutes.last;
    }
    return null;
  }

  bool containsRouteNamed(String name) =>
      _routes.any((route) => route.settings.name == name) ||
      (name == workDetailRouteName && _departingWorkDetailRoutes.isNotEmpty);

  bool hasRouteAboveNamed(String name) {
    final routeIndex = _routes.lastIndexWhere(
      (route) => route.settings.name == name,
    );
    if (routeIndex < 0) {
      return (name == workDetailRouteName &&
              _departingWorkDetailRoutes.isNotEmpty) ||
          _departingRoutes.isNotEmpty;
    }
    return routeIndex < _routes.length - 1 ||
        _departingRoutes.isNotEmpty ||
        (name != workDetailRouteName && _departingWorkDetailRoutes.isNotEmpty);
  }

  void _sync() {
    if (_syncScheduled || _disposed) return;
    _syncScheduled = true;
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (!_disposed) revision.value++;
    });
  }

  void _syncImmediately() {
    if (!_disposed) revision.value++;
  }

  void dispose() {
    _disposed = true;
    for (final listener in _routeAnimationListeners.values) {
      listener.$1.removeStatusListener(listener.$2);
    }
    _routeAnimationListeners.clear();
    _departingRoutes.clear();
    _departingWorkDetailRoutes.clear();
  }

  void _trackAnimation(PageRoute<dynamic> route) {
    final animation = route.animation;
    if (animation == null || _routeAnimationListeners.containsKey(route)) {
      return;
    }
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (status == AnimationStatus.dismissed) {
          _departingRoutes.remove(route);
          _departingWorkDetailRoutes.remove(route);
        }
        _sync();
      }
    }

    _routeAnimationListeners[route] = (animation, listener);
    animation.addStatusListener(listener);
  }

  void _untrackAnimation(PageRoute<dynamic> route) {
    final listener = _routeAnimationListeners.remove(route);
    listener?.$1.removeStatusListener(listener.$2);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route case final PageRoute<dynamic> pageRoute) {
      _routes.add(pageRoute);
      _trackAnimation(pageRoute);
      _sync();
    } else if (route is PopupRoute<dynamic> &&
        topRoute is SessionDetailRoute &&
        containsRouteNamed(workDetailRouteName)) {
      _suppressDockForSessionDetail = true;
      _sync();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute<dynamic> && _suppressDockForSessionDetail) {
      unawaited(
        route.completed.then((_) {
          if (_disposed || topRoute is! SessionDetailRoute) return;
          _suppressDockForSessionDetail = false;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _syncImmediately(),
          );
        }),
      );
    }
    if (route is PageRoute<dynamic>) {
      if (route is SessionDetailRoute) {
        _suppressDockForSessionDetail = false;
      }
      final isWorkDetail = route.settings.name == workDetailRouteName;
      final workDetailIndex = _routes.lastIndexWhere(
        (candidate) => candidate.settings.name == workDetailRouteName,
      );
      if (isWorkDetail && route.reverseTransitionDuration > Duration.zero) {
        _departingWorkDetailRoutes.add(route);
      } else if (workDetailIndex >= 0 &&
          _routes.indexOf(route) > workDetailIndex &&
          route.reverseTransitionDuration > Duration.zero) {
        _departingRoutes.add(route);
      }
      _routes.remove(route);
      _sync();
      unawaited(
        route.completed.then((_) {
          _departingRoutes.remove(route);
          _departingWorkDetailRoutes.remove(route);
          _untrackAnimation(route);
          _syncImmediately();
        }),
      );
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      if (route is SessionDetailRoute) {
        _suppressDockForSessionDetail = false;
      }
      _routes.remove(route);
      _departingRoutes.remove(route);
      _departingWorkDetailRoutes.remove(route);
      _untrackAnimation(route);
      _sync();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is SessionDetailRoute) {
      _suppressDockForSessionDetail = false;
    }
    if (oldRoute is PageRoute<dynamic>) {
      _untrackAnimation(oldRoute);
      _departingRoutes.remove(oldRoute);
      _departingWorkDetailRoutes.remove(oldRoute);
      final index = _routes.indexOf(oldRoute);
      if (index >= 0) {
        if (newRoute is PageRoute<dynamic>) {
          _routes[index] = newRoute;
          _trackAnimation(newRoute);
        } else {
          _routes.removeAt(index);
        }
      }
    } else if (newRoute is PageRoute<dynamic>) {
      _routes.add(newRoute);
      _trackAnimation(newRoute);
    }
    _sync();
  }
}

class _RoutedPlaybackDock extends ConsumerStatefulWidget {
  const _RoutedPlaybackDock({
    required this.active,
    required this.covered,
    required this.navigatorKey,
    required this.currentRoute,
    required this.geometry,
    this.departing = false,
  });

  final bool active;
  final bool covered;
  final bool departing;
  final GlobalKey<NavigatorState> navigatorKey;
  final Route<dynamic>? currentRoute;
  final PlaybackDockGeometryController geometry;

  @override
  ConsumerState<_RoutedPlaybackDock> createState() =>
      _RoutedPlaybackDockState();
}

class _RoutedPlaybackDockState extends ConsumerState<_RoutedPlaybackDock> {
  static const _duration = Duration(milliseconds: 280);
  Timer? _hideTimer;
  late bool _visible = widget.active;
  bool _expanded = false;
  final GlobalKey _dockBoundsKey = GlobalKey();
  double? _dockRight;

  @override
  void initState() {
    super.initState();
    widget.geometry.addListener(_handleGeometryChanged);
    if (widget.active) _scheduleExpansion();
  }

  void _handleGeometryChanged() {
    if (mounted && _visible) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _RoutedPlaybackDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.geometry != widget.geometry) {
      oldWidget.geometry.removeListener(_handleGeometryChanged);
      widget.geometry.addListener(_handleGeometryChanged);
    }
    if (widget.departing != oldWidget.departing && widget.departing) {
      _expanded = false;
    }
    if (widget.active == oldWidget.active) return;
    _hideTimer?.cancel();
    if (widget.active) {
      _visible = true;
      _expanded = false;
      _scheduleExpansion();
      return;
    }
    _expanded = false;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    _hideTimer = Timer(duration, () {
      if (mounted && !widget.active) setState(() => _visible = false);
    });
  }

  void _scheduleExpansion() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) setState(() => _expanded = true);
    });
  }

  void _reportDockBounds() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box =
          _dockBoundsKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final right = box.localToGlobal(Offset.zero).dx + box.size.width;
      if (_dockRight == right) return;
      setState(() => _dockRight = right);
    });
  }

  double _transitionWidth(double maxWidth) {
    final mainCover = widget.geometry.mainCoverRect;
    final dockRight = _dockRight ?? widget.geometry.mainDockRight;
    if (mainCover == null || dockRight == null) {
      return kActiveSessionCarouselDockHeight;
    }
    const coverCenterInset = kActiveSessionCarouselDockHeight / 2;
    return (dockRight - mainCover.center.dx + coverCenterInset).clamp(
      kActiveSessionCarouselDockHeight,
      maxWidth,
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.geometry.removeListener(_handleGeometryChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(
      mainOverlayUiProvider.select((state) => state.overlaySessions),
    );
    final size = MediaQuery.sizeOf(context);
    final isLandscapeDock =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape ||
        size.width >= 980;
    final supported = size.width >= 300 && size.height >= 300;
    if (!_visible || !supported || sessions.isEmpty) {
      return const SizedBox.shrink();
    }
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    final i18n = ref.read(appLanguageProviderInstanceProvider);

    Widget dockContent() => AppDockGlassPanel(
      key: const ValueKey<String>('routed_playback_dock'),
      shadowOpacity: 0.12,
      showTopHighlight: false,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          kActiveSessionCarouselDockHeight / 2,
        ),
        child: ActiveSessionCarousel(
          sessions: sessions,
          i18n: i18n,
          viewportFraction: 1,
          presentation: ActiveSessionCarouselPresentation.embedded,
          onOpenSession: (sessionId) {
            if (widget.currentRoute is SessionDetailRoute) return;
            widget.navigatorKey.currentState?.push(
              buildSessionDetailRoute(sessionId: sessionId),
            );
          },
        ),
      ),
    );

    if (isLandscapeDock) {
      final fallbackWidth = (size.width - 16).clamp(0.0, 244.0);
      final sourceRect =
          widget.geometry.mainDockRect ??
          Rect.fromLTWH(
            8,
            size.height - kActiveSessionCarouselDockHeight - 8,
            kActiveSessionCarouselDockHeight,
            kActiveSessionCarouselDockHeight,
          );
      final expandedRect =
          widget.geometry.mainExpandedDockRect ??
          Rect.fromLTWH(
            sourceRect.left,
            sourceRect.top,
            fallbackWidth,
            kActiveSessionCarouselDockHeight,
          );
      final dockRect =
          (_expanded && !widget.departing) || !widget.geometry.mainDockCollapsed
              ? expandedRect
              : sourceRect;
      return SizedBox(
        width: size.width,
        height: size.height,
        child: IgnorePointer(
          key: const ValueKey<String>('routed_playback_dock_interaction'),
          ignoring: !widget.active || widget.covered,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedPositioned(
                duration: duration,
                curve: Curves.easeOutCubic,
                left: dockRect.left,
                top: dockRect.top,
                width: dockRect.width,
                height: dockRect.height,
                child: SizedBox.expand(
                  key: const ValueKey<String>('routed_playback_dock_width'),
                  child: dockContent(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return IgnorePointer(
      key: const ValueKey<String>('routed_playback_dock_interaction'),
      ignoring: !widget.active || widget.covered,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: kMobileDockBottomMargin),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: FractionallySizedBox(
                widthFactor: 0.96,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _reportDockBounds();
                    return Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        key: const ValueKey<String>(
                          'routed_playback_dock_width',
                        ),
                        child: AnimatedContainer(
                          key: _dockBoundsKey,
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          width: (_expanded && !widget.departing)
                              ? constraints.maxWidth
                              : _transitionWidth(constraints.maxWidth),
                          height: kActiveSessionCarouselDockHeight,
                          child: dockContent(),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
