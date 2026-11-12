import '../../core/widgets/app_search_page.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/mobile_overlay_inset.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/ui_interaction_coordinator.dart';
import '../state/app_runtime_providers.dart';
import '../presentation/app_presentation_providers.dart';
import '../presentation/main_screen.dart';
import '../../features/library/presentation/work_detail_page.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../features/player/presentation/playlist_tab.dart';
import '../../core/widgets/library_like_cards.dart';
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
    this.playbackNavigatorKey,
    this.geometry,
    this.enabled = true,
    this.menuDismiss,
    this.backgroundColor,
    this.onTopPageChanged,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final RoutedPlaybackDockAppBuilder builder;
  final GlobalKey<NavigatorState>? playbackNavigatorKey;
  final PlaybackDockGeometryController? geometry;
  final bool enabled;
  final ValueNotifier<VoidCallback?>? menuDismiss;
  final Color? backgroundColor;
  final ValueChanged<PageRoute<dynamic>?>? onTopPageChanged;

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
    _routeObserver = _RootPageRouteObserver(
      _routeRevision,
      (route) => widget.onTopPageChanged?.call(route),
    );
    _routeRevision.addListener(_syncRoutedPlaybackDock);
    _playbackDockGeometry = widget.geometry ?? PlaybackDockGeometryController();
  }

  @override
  void didUpdateWidget(RoutedPlaybackDockHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        _scheduleRoutedPlaybackDockSync();
      } else {
        _removeRoutedPlaybackDock();
      }
    }
  }

  @override
  void dispose() {
    _removeRoutedPlaybackDock();
    _routeObserver.dispose();
    if (widget.geometry == null) _playbackDockGeometry.dispose();
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
    if (!widget.enabled) {
      _removeRoutedPlaybackDock();
      return;
    }
    final workDetailRoute = _routeObserver.lastRouteNamed(workDetailRouteName);
    if (workDetailRoute == null) {
      _removeRoutedPlaybackDock();
      return;
    }
    if (_routedPlaybackDockRoute == workDetailRoute &&
        _routedPlaybackDockEntry != null) {
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
    final pageEntry = workDetailRoute.overlayEntries.last;
    // Navigator keeps a route's entries together during rebuilds and pops.
    // Owning the dock here leaves every covering page above it until disposal.
    workDetailRoute.overlayEntries.add(entry);
    _routedPlaybackDockRoute = workDetailRoute;
    _routedPlaybackDockEntry = entry;
    _playbackDockGeometry.setRoutedDockActive(this, true);
    overlay.insert(entry, above: pageEntry);
  }

  void _removeRoutedPlaybackDock() {
    _playbackDockGeometry.setRoutedDockActive(this, false);
    final entry = _routedPlaybackDockEntry;
    final route = _routedPlaybackDockRoute;
    _routedPlaybackDockEntry = null;
    _routedPlaybackDockRoute = null;
    // Popped/removed routes let Navigator remove and dispose their entries.
    if (entry == null || route == null || !route.isActive) return;
    if (route.overlayEntries.remove(entry)) {
      entry.remove();
      entry.dispose();
    }
  }

  Widget _buildRoutedPlaybackDockOverlay(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final supportsRoutedDock = size.width >= 300 && size.height >= 300;
    return Positioned.fill(
      child: RepaintBoundary(
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
            final workDetail = _routedPlaybackDockRoute;
            final openedFromPlayback =
                workDetail != null &&
                identical(workDetail, _routeObserver.workDetailFromPlayback);
            final fixedDockVisible = openedFromPlayback
                ? !routeDeparting &&
                      !workDetail.offstage &&
                      workDetail.animation?.status == AnimationStatus.completed
                : null;
            return Consumer(
              builder: (context, ref, _) => _RoutedPlaybackDock(
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
                navigatorKey:
                    widget.playbackNavigatorKey ?? widget.navigatorKey,
                currentRoute: _routeObserver.topRoute,
                workDetailAnimation: workDetail?.animation,
                fixedDockVisible: fixedDockVisible,
                fadeWithWorkDetail:
                    workDetail != null &&
                    identical(workDetail, _routeObserver.workDetailFromSearch),
                geometry: _playbackDockGeometry,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _wrapNavigator(BuildContext context, Widget child) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
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
        final supportsRoutedDock = size.width >= 300 && size.height >= 300;
        final reserveWorkDetailDockInset =
            widget.enabled &&
            isWorkDetailRoute &&
            supportsRoutedDock &&
            hasOverlaySessions;
        final routeDockInset = reserveWorkDetailDockInset
            ? kActiveSessionCarouselDockHeight +
                  kMobileDockBottomMargin +
                  6 +
                  padding.bottom
            : 0.0;
        return MobileOverlayInset(
          bottomInset: routeDockInset,
          menuOverlayKey: _menuOverlayKey,
          menuDismiss: widget.menuDismiss,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color:
                    widget.backgroundColor ??
                    Theme.of(context).colorScheme.surface,
                child: AppPageTransitionHost(
                  enabled: !_routeObserver.hasPopups,
                  child: navigatorChild!,
                ),
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
  _RootPageRouteObserver(this.revision, this.onTopPageChanged);

  final ValueNotifier<int> revision;
  final ValueChanged<PageRoute<dynamic>?> onTopPageChanged;
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];
  final Map<
    TransitionRoute<dynamic>,
    (Animation<double>, AnimationStatusListener)
  >
  _routeAnimationListeners = {};
  final Set<PageRoute<dynamic>> _departingRoutes = {};
  final Set<PageRoute<dynamic>> _departingWorkDetailRoutes = {};
  PageRoute<dynamic>? workDetailFromPlayback;
  PageRoute<dynamic>? workDetailFromSearch;
  bool get hasPopups => _routes.any((route) => route is PopupRoute<dynamic>);
  bool _syncScheduled = false;
  bool _disposed = false;

  PageRoute<dynamic>? get topRoute =>
      _routes.whereType<PageRoute<dynamic>>().lastOrNull;
  bool get isWorkDetailDeparting => _departingWorkDetailRoutes.isNotEmpty;

  PageRoute<dynamic>? lastRouteNamed(String name) {
    for (var index = _routes.length - 1; index >= 0; index--) {
      final route = _routes[index];
      if (route is PageRoute<dynamic> && route.settings.name == name) {
        return route;
      }
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
      if (!_disposed) {
        onTopPageChanged(topRoute);
        revision.value++;
      }
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

  void _trackAnimation(TransitionRoute<dynamic> route) {
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
          if (route is PopupRoute<dynamic> && !route.isActive) {
            // completed waits for overlay disposal; stop tracking the popup
            // as soon as Navigator finalizes it instead.
            _routes.remove(route);
          }
          onTopPageChanged(topRoute);
          _syncImmediately();
          return;
        }
        _sync();
      }
    }

    _routeAnimationListeners[route] = (animation, listener);
    animation.addStatusListener(listener);
  }

  void _untrackAnimation(TransitionRoute<dynamic> route) {
    final listener = _routeAnimationListeners.remove(route);
    listener?.$1.removeStatusListener(listener.$2);
    if (identical(route, workDetailFromPlayback)) {
      workDetailFromPlayback = null;
    }
    if (identical(route, workDetailFromSearch)) {
      workDetailFromSearch = null;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute<dynamic>) {
      _routes.add(route);
      _trackAnimation(route);
      _sync();
      unawaited(
        route.completed.then((_) {
          if (_disposed) return;
          _routes.remove(route);
          _untrackAnimation(route);
          _syncImmediately();
        }),
      );
    }
    if (route case final PageRoute<dynamic> pageRoute) {
      // A stack reset can already exclude playback from previousRoute.
      if (pageRoute.settings.name == workDetailRouteName) {
        if (topRoute is SessionDetailRoute) {
          workDetailFromPlayback = pageRoute;
        } else if (topRoute?.settings.name == appSearchRouteName) {
          workDetailFromSearch = pageRoute;
        }
      }
      _routes.add(pageRoute);
      _trackAnimation(pageRoute);
      _sync();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute<dynamic>) {
      if (route.animation?.status == AnimationStatus.dismissed) {
        _routes.remove(route);
      }
      _sync();
    }
    if (route is PageRoute<dynamic>) {
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
    if (route is PopupRoute<dynamic>) {
      _routes.remove(route);
      _untrackAnimation(route);
      _sync();
    }
    if (route is PageRoute<dynamic>) {
      _routes.remove(route);
      _departingRoutes.remove(route);
      _departingWorkDetailRoutes.remove(route);
      _untrackAnimation(route);
      _sync();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is TransitionRoute<dynamic>) {
      _untrackAnimation(oldRoute);
      _departingRoutes.remove(oldRoute);
      _departingWorkDetailRoutes.remove(oldRoute);
      final index = _routes.indexOf(oldRoute);
      if (index >= 0) {
        if (newRoute is TransitionRoute<dynamic>) {
          _routes[index] = newRoute;
          _trackAnimation(newRoute);
        } else {
          _routes.removeAt(index);
        }
      }
    } else if (newRoute is TransitionRoute<dynamic>) {
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
    required this.workDetailAnimation,
    required this.fixedDockVisible,
    required this.fadeWithWorkDetail,
    required this.geometry,
    this.departing = false,
  });

  final bool active;
  final bool covered;
  final bool departing;
  final GlobalKey<NavigatorState> navigatorKey;
  final Route<dynamic>? currentRoute;
  final Animation<double>? workDetailAnimation;
  // Other entrances retain the motion from the main playback dock.
  final bool? fixedDockVisible;
  final bool fadeWithWorkDetail;
  final PlaybackDockGeometryController geometry;

  @override
  ConsumerState<_RoutedPlaybackDock> createState() =>
      _RoutedPlaybackDockState();
}

class _RoutedPlaybackDockState extends ConsumerState<_RoutedPlaybackDock> {
  static const _duration = kAppFadeDuration;
  Timer? _hideTimer;
  late bool _visible = widget.active;
  bool _expanded = false;
  bool _raisedDockEntered = false;
  late bool _fixedDockShown = widget.active && widget.fixedDockVisible == true;
  (Size, Rect)? _returnGeometry;

  @override
  void initState() {
    super.initState();
    widget.geometry.addListener(_handleGeometryChanged);
    if (widget.active) _scheduleExpansion();
  }

  void _handleGeometryChanged() {
    if (mounted &&
        _visible &&
        !UiInteractionCoordinator.instance.isInteracting) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _RoutedPlaybackDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.geometry != widget.geometry) {
      oldWidget.geometry.removeListener(_handleGeometryChanged);
      widget.geometry.addListener(_handleGeometryChanged);
    }
    if (widget.departing != oldWidget.departing) {
      _returnGeometry = null;
      if (widget.departing) _expanded = false;
    }
    if (!widget.active || widget.fixedDockVisible == null) {
      _fixedDockShown = false;
    } else if (widget.fixedDockVisible == true) {
      _fixedDockShown = true;
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
    _visible = false;
  }

  void _scheduleExpansion() {
    if (widget.fixedDockVisible != null || widget.fadeWithWorkDetail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) setState(() => _expanded = true);
    });
  }

  Rect _returnTarget(Rect target, Size viewport) {
    if (!widget.departing) return target;
    // Main-page layout reports can arrive while it is being revealed. Keep
    // one landing point for this exit instead of extending/restarting motion.
    if (_returnGeometry?.$1 != viewport) {
      _returnGeometry = (viewport, target);
    }
    return _returnGeometry!.$2;
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
    if (!widget.active || !_visible || !supported || sessions.isEmpty) {
      return const SizedBox.shrink();
    }
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    final hasFixedEntrance = widget.fixedDockVisible != null;
    final fixedAtBottom =
        widget.fadeWithWorkDetail || (hasFixedEntrance && !widget.departing);
    final searchAnimation = widget.fadeWithWorkDetail
        ? widget.workDetailAnimation
        : null;
    final ignoreInput =
        widget.covered ||
        (searchAnimation != null && !searchAnimation.isCompleted);
    Widget reveal(Widget dock) {
      if (searchAnimation != null && duration != Duration.zero) {
        return FadeTransition(
          opacity: searchAnimation.drive(CurveTween(curve: kAppFadeCurve)),
          child: dock,
        );
      }
      if (!hasFixedEntrance) return dock;
      return AppDeferredFade(
        visible: _fixedDockShown,
        fadeInDuration: widget.departing ? Duration.zero : _duration,
        child: dock,
      );
    }

    final padding = MediaQuery.paddingOf(context);
    final bottom = padding.bottom > kMobileDockBottomMargin
        ? padding.bottom
        : kMobileDockBottomMargin;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);

    final isRaised = widget.geometry.mainDockRaised;
    final dockBorderRadius = isRaised
        ? const BorderRadius.only(
            topLeft: Radius.circular(LibraryLikeCardMetrics.cardRadius),
            bottomLeft: Radius.circular(LibraryLikeCardMetrics.cardRadius),
            topRight: Radius.circular(kActiveSessionCarouselDockHeight / 2),
            bottomRight: Radius.circular(kActiveSessionCarouselDockHeight / 2),
          )
        : BorderRadius.circular(kActiveSessionCarouselDockHeight / 2);

    Widget carousel({double? contentWidth}) => ActiveSessionCarousel(
      sessions: sessions,
      i18n: i18n,
      expandedDockWidth: contentWidth,
      isPlaybackRaised: isRaised,
      viewportFraction: 1,
      presentation: ActiveSessionCarouselPresentation.embedded,
      isRoutedDock: true,
      onOpenSession: (sessionId, coverOrigin) {
        if (widget.currentRoute is SessionDetailRoute) return;
        widget.navigatorKey.currentState?.push(
          buildSessionDetailRoute(
            sessionId: sessionId,
            coverOrigin: coverOrigin,
          ),
        );
      },
    );

    Widget dockContent() => AppDockPanel(
      showTopHighlight: false,
      child: ClipRRect(borderRadius: dockBorderRadius, child: carousel()),
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
      final Rect dockRect;
      if (fixedAtBottom) {
        dockRect = expandedRect.shift(
          Offset(0, size.height - bottom - expandedRect.bottom),
        );
      } else {
        dockRect =
            (_expanded && !widget.departing) ||
                !widget.geometry.mainDockCollapsed
            ? expandedRect
            : sourceRect;
      }
      final bounds = _returnTarget(dockRect, size);
      final dock = SizedBox(
        width: size.width,
        height: size.height,
        child: IgnorePointer(
          key: const ValueKey<String>('routed_playback_dock_interaction'),
          ignoring: ignoreInput,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedPositioned(
                duration: fixedAtBottom ? Duration.zero : duration,
                curve: Curves.easeOutCubic,
                left: bounds.left,
                top: bounds.top,
                width: bounds.width,
                height: bounds.height,
                child: SizedBox.expand(
                  key: const ValueKey<String>('routed_playback_dock_width'),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    child: ClipRRect(
                      key: const ValueKey<String>('routed_playback_dock'),
                      borderRadius: BorderRadius.circular(
                        kActiveSessionCarouselDockHeight / 2,
                      ),
                      child: !widget.geometry.mainDockCollapsed
                          ? RepaintBoundary(child: dockContent())
                          : OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: expandedRect.width,
                              maxWidth: expandedRect.width,
                              minHeight: kActiveSessionCarouselDockHeight,
                              maxHeight: kActiveSessionCarouselDockHeight,
                              child: RepaintBoundary(child: dockContent()),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      return reveal(dock);
    }

    final usableWidth = size.width - padding.horizontal - AppSpacing.sm * 2;
    final width = usableWidth.clamp(0.0, 430.0) * 0.96;
    final target = Rect.fromLTWH(
      padding.left + (size.width - padding.horizontal - width) / 2,
      size.height - bottom - kActiveSessionCarouselDockHeight,
      width,
      kActiveSessionCarouselDockHeight,
    );
    final source = _returnTarget(
      widget.geometry.mainDockRect ??
          Rect.fromLTWH(
            target.left,
            target.top,
            kActiveSessionCarouselDockHeight,
            target.height,
          ),
      size,
    );
    final animation = fixedAtBottom
        ? kAlwaysCompleteAnimation
        : widget.workDetailAnimation ??
              (widget.departing
                  ? kAlwaysDismissedAnimation
                  : kAlwaysCompleteAnimation);
    final portraitContentWidth = widget.geometry.mainDockCollapsed
        ? null
        : width;
    final dock = IgnorePointer(
      key: const ValueKey<String>('routed_playback_dock_interaction'),
      ignoring: ignoreInput,
      child: AnimatedBuilder(
        animation: animation,
        child: RepaintBoundary(
          child: isRaised
              ? carousel(contentWidth: portraitContentWidth)
              : AppDockPanel(
                  showTopHighlight: false,
                  child: carousel(contentWidth: portraitContentWidth),
                ),
        ),
        builder: (context, child) {
          final curve = isRaised ? Curves.easeInOutCubic : Curves.easeOutCubic;
          final progress = MediaQuery.disableAnimationsOf(context)
              ? 1.0
              : curve.transform(animation.value);
          if (!fixedAtBottom &&
              isRaised &&
              !widget.departing &&
              animation.status != AnimationStatus.reverse) {
            _raisedDockEntered = progress == 1;
          }
          // A completed detail page returns with the upward motion. An
          // interrupted entry retraces the fold from its current frame.
          final folding =
              !fixedAtBottom &&
              isRaised &&
              !(widget.departing && (_raisedDockEntered || _fixedDockShown));
          final bounds = Rect.lerp(source, target, progress)!;
          // Narrow the visible height around the row boundary while keeping
          // the cover and controls laid out at their normal size.
          final inset = folding
              ? bounds.height * progress * (1 - progress)
              : 0.0;
          final rect = Rect.fromLTRB(
            bounds.left,
            bounds.top + inset,
            bounds.right,
            bounds.bottom - inset,
          );
          Widget content = child!;
          if (widget.geometry.mainDockCollapsed) {
            // Reveal a stable carousel from the left of the compact card.
            content = OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: target.width,
              maxWidth: target.width,
              child: content,
            );
          } else if (isRaised) {
            // The home panel is already behind the card as it lands.
            // Fade only the extra surface to keep the cover visible.
            content = Stack(
              fit: StackFit.expand,
              children: [
                Opacity(
                  opacity: const Interval(
                    0,
                    0.25,
                    curve: Curves.easeInOut,
                  ).transform(progress),
                  child: const AppDockPanel(
                    showTopHighlight: false,
                    child: SizedBox.expand(),
                  ),
                ),
                content,
              ],
            );
          }
          if (isRaised) {
            // Keep the carousel mounted as the clipping edge changes.
            content = OverflowBox(
              alignment: folding
                  ? Alignment.lerp(
                      Alignment.bottomCenter,
                      Alignment.topCenter,
                      progress,
                    )!
                  : Alignment.topCenter,
              minHeight: target.height,
              maxHeight: target.height,
              child: content,
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: target.height + bottom,
                child: const Listener(behavior: HitTestBehavior.opaque),
              ),
              Positioned.fromRect(
                rect: rect,
                child: SizedBox.expand(
                  key: const ValueKey<String>('routed_playback_dock_width'),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    child: ClipRRect(
                      key: const ValueKey<String>('routed_playback_dock'),
                      borderRadius: dockBorderRadius,
                      child: content,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return reveal(dock);
  }
}
