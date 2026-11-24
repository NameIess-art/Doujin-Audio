import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_styles.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/widgets/app_transitions.dart';
import '../../features/player/presentation/playlist/session_detail_route.dart';
import 'main_screen.dart';
import 'main_tab_state_mixin.dart';
import 'routed_playback_dock_host.dart';

/// Owns page navigation only; library and playback state stay in their facades.
class WorkDetailNavigation extends ChangeNotifier {
  WorkDetailNavigation({required this.rootNavigatorKey}) {
    observer = _WorkDetailObserver(this);
    contentObserver = _WorkDetailObserver(this, content: true);
  }

  final GlobalKey<NavigatorState> rootNavigatorKey;
  final navigatorKey = GlobalKey<NavigatorState>();
  final contentNavigatorKey = GlobalKey<NavigatorState>();
  final menuDismiss = ValueNotifier<VoidCallback?>(null);
  late final NavigatorObserver observer;
  late final NavigatorObserver contentObserver;
  final List<Route<dynamic>> _routes = [];
  final List<Route<dynamic>> _contentRoutes = [];
  final Set<Route<dynamic>> _closing = {};
  final Set<Route<dynamic>> _contentClosing = {};
  final _detailCoversContent = ValueNotifier(false);
  final _isOpenNotifier = ValueNotifier(false);
  Animation<double>? _coveringAnimation;
  Object? _identity;
  Future<void>? _completion;
  bool _scheduled = false;
  bool _disposed = false;
  int _request = 0;

  bool get isOpen => _routes.length > 1 || _closing.isNotEmpty;
  ValueListenable<bool> get isOpenListenable => _isOpenNotifier;
  bool get isContentOpen =>
      _contentRoutes.length > 1 || _contentClosing.isNotEmpty;

  NavigatorState? preferredBackNavigator([BuildContext? focusContext]) {
    final detailNav = navigatorKey.currentState;
    final contentNav = contentNavigatorKey.currentState;
    final detailCanPop = detailNav?.canPop() ?? false;
    final contentCanPop = contentNav?.canPop() ?? false;
    if (!detailCanPop && !contentCanPop) return null;
    if (detailCanPop && contentCanPop) {
      final activeFocus =
          focusContext ?? FocusManager.instance.primaryFocus?.context;
      if (_isDescendantOfNavigator(activeFocus, contentNav)) {
        return contentNav;
      }
      if (_isDescendantOfNavigator(activeFocus, detailNav)) {
        return detailNav;
      }
    }
    if (detailCanPop) return detailNav;
    return contentNav;
  }

  static bool _isDescendantOfNavigator(
    BuildContext? descendant,
    NavigatorState? navigator,
  ) {
    if (descendant == null || !descendant.mounted || navigator == null) {
      return false;
    }
    final ancestorContext = navigator.context;
    if (identical(descendant, ancestorContext)) return true;
    var found = false;
    descendant.visitAncestorElements((element) {
      if (identical(element, ancestorContext)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  static Future<void> openFrom(
    BuildContext context,
    Object identity,
    PageRoute<void> Function(BuildContext context) buildRoute, {
    bool returnToMain = false,
  }) async {
    final navigator = Navigator.of(context);
    final origin = readAppRoute(context);
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    final openingOverPlayback = returnToMain && origin is SessionDetailRoute;
    if (openingOverPlayback) {
      // Restore the phone layout while playback detail still covers the main
      // page, so the incoming work page can slide in at its final size.
      await origin.prepareForExit();
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!navigator.mounted ||
        origin?.isCurrent == false ||
        (!openingOverPlayback && !context.mounted)) {
      return;
    }
    // Restoring portrait can replace the playback controls that opened this
    // page. The owning Navigator and the current route survive that reflow.
    final routeContext = openingOverPlayback ? navigator.context : context;
    if (navigation != null) {
      if (openingOverPlayback) {
        // Clear the main page's nested stacks while playback still covers them.
        final request = ++navigation._request;
        navigation.resetContent();
        navigation._removeSubpages(
          navigation.navigatorKey.currentState,
          navigation._routes,
        );
        if (defaultTargetPlatform == TargetPlatform.windows ||
            MediaQuery.orientationOf(routeContext) == Orientation.landscape) {
          navigator.popUntil((route) => route.isFirst);
          await origin.completed;
          if (!navigator.mounted ||
              navigation._disposed ||
              request != navigation._request) {
            return;
          }
          await navigation.open(identity, buildRoute, returnToMain: true);
          return;
        }
      } else if (returnToMain || navigation.canOpenInPane(context)) {
        await navigation.open(identity, buildRoute, returnToMain: returnToMain);
        return;
      }
    }
    final route = buildRoute(routeContext);
    if (returnToMain) {
      // The navigator keeps the previous page painted until the incoming
      // slide completes, then removes it without an exit animation.
      await navigator.pushAndRemoveUntil<void>(route, (route) => route.isFirst);
    } else {
      await navigator.push<void>(route);
    }
  }

  void resetContent() {
    menuDismiss.value?.call();
    _removeSubpages(contentNavigatorKey.currentState, _contentRoutes);
  }

  Future<void> openFromMain(
    PageRoute<void> Function(BuildContext context) buildRoute, {
    required bool keepDetailPane,
  }) async {
    final request = ++_request;
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    resetContent();
    if (!keepDetailPane) {
      _removeSubpages(navigatorKey.currentState, _routes);
    }
    // Dispose the previous search session before initializing the new one.
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed || request != _request) return;
    final navigator = contentNavigatorKey.currentState;
    if (navigator == null) return;
    final routeContext = navigator.context;
    if (!routeContext.mounted) return;
    await navigator.push<void>(buildRoute(routeContext));
  }

  void _removeSubpages(
    NavigatorState? navigator,
    List<Route<dynamic>> routes,
  ) {
    if (navigator == null) return;
    for (final route in routes.skip(1).toList().reversed) {
      navigator.removeRoute(route);
    }
  }

  bool canOpenInPane(BuildContext context) {
    final originNavigator = Navigator.of(context);
    // Pages on the root stack mute the main route's navigator tickers, so
    // their details must stay on that visible stack.
    return originNavigator == navigatorKey.currentState ||
        (originNavigator == contentNavigatorKey.currentState &&
            (WorkDetailNavigationScope.isLandscapeOf(context) ||
                readAppRoute(context)?.isFirst == true)) ||
        (originNavigator == rootNavigatorKey.currentState &&
            readAppRoute(context)?.isFirst == true);
  }

  void updateIdentity(Object current, Object next) {
    if (_identity == current) _identity = next;
  }

  Future<void> open(
    Object identity,
    PageRoute<void> Function(BuildContext context) buildRoute, {
    bool returnToMain = false,
  }) async {
    final request = ++_request;
    if (returnToMain) {
      rootNavigatorKey.currentState!.popUntil((route) => route.isFirst);
      resetContent();
      await WidgetsBinding.instance.endOfFrame;
    }
    if (_disposed || request != _request) return;
    if (_identity == identity && _routes.length > 1) {
      await _completion;
      return;
    }
    final navigator = navigatorKey.currentState!;
    _identity = identity;
    final routeContext = navigator.overlay!.context;
    if (!routeContext.mounted) return;
    final route = buildRoute(routeContext);
    _completion = navigator.pushAndRemoveUntil<void>(
      route,
      (route) => route.isFirst,
    );
    await _completion;
  }

  void _changed() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_disposed) return;
      if (!isOpen) {
        _identity = null;
        _completion = null;
      }
      _isOpenNotifier.value = isOpen;
      _syncDetailCoverage();
      notifyListeners();
    });
  }

  void _syncDetailCoverage() {
    PageRoute<dynamic>? cover;
    for (var index = _routes.length - 1; index > 0; index--) {
      final route = _routes[index];
      if (route is PageRoute<dynamic> && route.opaque) {
        cover = route;
        break;
      }
    }
    final animation = cover?.animation;
    if (animation != _coveringAnimation) {
      _coveringAnimation?.removeStatusListener(_onCoverStatusChanged);
      _coveringAnimation = animation;
      animation?.addStatusListener(_onCoverStatusChanged);
    }
    _detailCoversContent.value =
        cover != null &&
        (animation == null || animation.status == AnimationStatus.completed);
  }

  void _onCoverStatusChanged(AnimationStatus status) {
    scheduleMicrotask(() {
      if (!_disposed) _syncDetailCoverage();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _coveringAnimation?.removeStatusListener(_onCoverStatusChanged);
    _detailCoversContent.dispose();
    _isOpenNotifier.dispose();
    menuDismiss.value?.call();
    menuDismiss.value = null;
    menuDismiss.dispose();
    super.dispose();
  }
}

class _WorkDetailObserver extends NavigatorObserver {
  _WorkDetailObserver(this.navigation, {this.content = false});

  final WorkDetailNavigation navigation;
  final bool content;
  List<Route<dynamic>> get routes =>
      content ? navigation._contentRoutes : navigation._routes;
  Set<Route<dynamic>> get closing =>
      content ? navigation._contentClosing : navigation._closing;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    navigation._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    // Retain pane bounds and dock ownership until the exit has finished.
    if (route is TransitionRoute<dynamic>) {
      closing.add(route);
      unawaited(
        route.completed.then((_) {
          closing.remove(route);
          navigation._changed();
        }),
      );
    }
    navigation._changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    navigation._changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) routes[index] = newRoute;
    navigation._changed();
  }
}

class WorkDetailNavigationScope extends InheritedWidget {
  const WorkDetailNavigationScope({
    super.key,
    required this.navigation,
    this.isLandscape = false,
    required super.child,
  });

  final WorkDetailNavigation navigation;
  final bool isLandscape;

  static bool isLandscapeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WorkDetailNavigationScope>()
          ?.isLandscape ??
      false;

  static WorkDetailNavigation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WorkDetailNavigationScope>()
      ?.navigation;

  @override
  bool updateShouldNotify(WorkDetailNavigationScope oldWidget) =>
      navigation != oldWidget.navigation ||
      isLandscape != oldWidget.isLandscape;
}

class MainContentNavigator extends StatefulWidget {
  const MainContentNavigator({
    super.key,
    required this.navigation,
    required this.isLandscape,
    required this.child,
    this.geometry,
    this.navigatorKey,
    this.observer,
    this.backgroundColor,
  });

  final WorkDetailNavigation navigation;
  final bool isLandscape;
  final Widget child;
  final PlaybackDockGeometryController? geometry;
  final GlobalKey<NavigatorState>? navigatorKey;
  final NavigatorObserver? observer;
  final Color? backgroundColor;

  @override
  State<MainContentNavigator> createState() => _MainContentNavigatorState();
}

class _MainContentNavigatorState extends State<MainContentNavigator> {
  final _interactionObserver = UiInteractionNavigatorObserver();

  @override
  void dispose() {
    _interactionObserver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkDetailNavigationScope(
    navigation: widget.navigation,
    isLandscape: widget.isLandscape,
    child: ClipRect(
      child: RoutedPlaybackDockHost(
        navigatorKey:
            widget.navigatorKey ?? widget.navigation.contentNavigatorKey,
        playbackNavigatorKey: widget.navigation.rootNavigatorKey,
        geometry: widget.geometry,
        enabled: !widget.isLandscape,
        menuDismiss: widget.navigation.menuDismiss,
        backgroundColor: widget.backgroundColor,
        builder: (context, observer, geometry, wrapNavigator) => wrapNavigator(
          context,
          Navigator(
            key: widget.navigatorKey ?? widget.navigation.contentNavigatorKey,
            observers: [
              widget.observer ?? widget.navigation.contentObserver,
              observer,
              _interactionObserver,
            ],
            pages: [
              MaterialPage<void>(
                key: const ValueKey('main_content_home'),
                child: widget.child,
              ),
            ],
            onDidRemovePage: (_) {},
          ),
        ),
      ),
    ),
  );
}

class WorkDetailPane extends StatelessWidget {
  static const mainWidthFraction = 5 / 8;
  static const detailWidthFraction = 3 / 8;

  static double detailPaneWidthFor(double contentWidth) {
    final available = (contentWidth - 1).clamp(0.0, contentWidth);
    final proportional = available * detailWidthFraction;
    if (available < 600) return proportional;
    final minUsable = math.min(340.0, available * 0.48);
    return math.max(proportional, minUsable).clamp(0.0, available);
  }

  static double mainPaneWidthFor(double contentWidth) {
    final available = (contentWidth - 1).clamp(0.0, contentWidth);
    return (available - detailPaneWidthFor(contentWidth)).clamp(0.0, available);
  }

  const WorkDetailPane({
    super.key,
    required this.child,
    required this.isLandscape,
    required this.sidebarWidth,
    this.geometry,
  });

  final Widget child;
  final bool isLandscape;
  final double sidebarWidth;
  final PlaybackDockGeometryController? geometry;

  @override
  Widget build(BuildContext context) {
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    if (navigation == null) return child;
    final roundCorners =
        isLandscape && defaultTargetPlatform != TargetPlatform.windows;
    return ListenableBuilder(
      listenable: navigation,
      child: child,
      builder: (context, child) {
        final isOpen = navigation.isOpen;
        // The main body fills this MediaQuery. Update route metrics before
        // layout, so resizing cannot rebuild navigator overlays during layout.
        final size = isOpen || isLandscape
            ? MediaQuery.sizeOf(context)
            : Size.zero;
        final contentWidth = (size.width - sidebarWidth).clamp(0.0, size.width);
        final paneWidth = isLandscape
            ? detailPaneWidthFor(contentWidth)
            : size.width;
        final detailNavigator = MainContentNavigator(
          key: const ValueKey('work_detail_pane'),
          navigation: navigation,
          navigatorKey: navigation.navigatorKey,
          observer: navigation.observer,
          isLandscape: isLandscape,
          geometry: geometry,
          backgroundColor: isLandscape ? null : Colors.transparent,
          child: const SizedBox.shrink(),
        );
        // This PopScope owns both nested stacks. A child returning to its
        // first route must not tell Android to exit while the other stack
        // still has a page; only the owning route should publish back state.
        final stack = NotificationListener<NavigationNotification>(
          onNotification: (_) => true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: navigation._detailCoversContent,
                child: child,
                builder: (context, covered, child) {
                  // The source page remains visible while a full-width route
                  // slides in or out. A side-by-side pane never covers it.
                  final obscured = !isLandscape && covered;
                  return MainTabVisibility(
                    covered: obscured,
                    child: TickerMode(
                      enabled: !obscured,
                      child: ExcludeFocus(
                        excluding: obscured,
                        child: ExcludeSemantics(
                          excluding: obscured,
                          child: IgnorePointer(
                            ignoring: obscured,
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              Positioned(
                key: const ValueKey('work_detail_pane_bounds'),
                right: 0,
                top: 0,
                bottom: 0,
                width: paneWidth,
                child: Offstage(
                  offstage: !isOpen,
                  child: Builder(
                    builder: (context) {
                      // Avoid subscribing to broad MediaQuery changes while the
                      // detail pane is closed and offstage, while keeping the
                      // MediaQuery wrapper in place so detailNavigator stays
                      // mounted across open/close transitions.
                      final mediaQuery = isOpen
                          ? MediaQuery.of(context)
                          : (context
                                    .getInheritedWidgetOfExactType<MediaQuery>()
                                    ?.data ??
                                const MediaQueryData());
                      return MediaQuery(
                        data: mediaQuery.copyWith(
                          size: Size(paneWidth, size.height),
                          padding: mediaQuery.padding.copyWith(left: 0),
                          viewPadding: mediaQuery.viewPadding.copyWith(left: 0),
                        ),
                        child: ColoredBox(
                          color: isLandscape
                              ? landscapeNavigationBackground(
                                  Theme.of(context).colorScheme,
                                )
                              : Colors.transparent,
                          child: ClipRRect(
                            key: const ValueKey('work_detail_pane_clip'),
                            borderRadius: roundCorners
                                ? BorderRadius.circular(AppRadius.section)
                                : BorderRadius.zero,
                            child: detailNavigator,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (isLandscape)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: navigation._coveringAnimation ??
                          (navigation.isOpen
                              ? kAlwaysCompleteAnimation
                              : kAlwaysDismissedAnimation),
                      builder: (context, _) {
                        final anim = navigation._coveringAnimation;
                        final rawProgress = !navigation.isOpen
                            ? 0.0
                            : (anim == null
                                  ? 1.0
                                  : kAppSpringCurve.transform(
                                      anim.value.clamp(0.0, 1.0),
                                    ));
                        return CustomPaint(
                          key: const ValueKey('content_pane_outline'),
                          painter: _ContentPaneOutlinePainter(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            sidebarWidth: sidebarWidth,
                            detailWidth: navigation.isOpen ? paneWidth : 0,
                            dividerOpacity: rawProgress,
                            roundCorners: roundCorners,
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
        return ValueListenableBuilder<VoidCallback?>(
          valueListenable: navigation.menuDismiss,
          child: stack,
          builder: (context, dismissMenu, stackChild) => PopScope<Object?>(
            canPop:
                !navigation.isOpen &&
                !navigation.isContentOpen &&
                dismissMenu == null,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop ||
                  !UiInteractionCoordinator.instance.navigationAllowed.value) {
                return;
              }
              if (dismissMenu != null) {
                dismissMenu();
              } else {
                final navigator = navigation.preferredBackNavigator();
                unawaited(navigator?.maybePop());
              }
            },
            child: stackChild!,
          ),
        );
      },
    );
  }
}

class _ContentPaneOutlinePainter extends CustomPainter {
  const _ContentPaneOutlinePainter({
    required this.color,
    required this.sidebarWidth,
    required this.detailWidth,
    this.dividerOpacity = 1.0,
    required this.roundCorners,
  });

  final Color color;
  final double sidebarWidth;
  final double detailWidth;
  final double dividerOpacity;
  final bool roundCorners;

  @override
  void paint(Canvas canvas, Size size) {
    final left = sidebarWidth + 0.5;
    final right = size.width - 0.5;
    if (right <= left || size.height <= 1) return;
    const top = 0.5;
    final bottom = size.height - 0.5;
    final radius = math.min(AppRadius.section, (bottom - top) / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (!roundCorners) {
      // Windows content meets the title bar and navigation without an outline.
      canvas.drawPath(
        Path()
          ..moveTo(left, bottom)
          ..lineTo(right, bottom)
          ..lineTo(right, top),
        paint,
      );
      if (detailWidth > 0 && dividerOpacity > 0) {
        final divider = right - detailWidth;
        final dividerPaint = Paint()
          ..color = color.withValues(alpha: color.a * dividerOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        canvas.drawLine(
          Offset(divider, top),
          Offset(divider, bottom),
          dividerPaint,
        );
      }
      return;
    }

    void drawSide(double x, {required bool leftSide, bool vertical = true}) {
      final endX = x + (leftSide ? radius : -radius);
      final path = Path()
        ..moveTo(endX, top)
        ..arcToPoint(
          Offset(x, top + radius),
          radius: Radius.circular(radius),
          clockwise: !leftSide,
        );
      if (vertical) {
        path.lineTo(x, bottom - radius);
      } else {
        path.moveTo(x, bottom - radius);
      }
      path.arcToPoint(
        Offset(endX, bottom),
        radius: Radius.circular(radius),
        clockwise: !leftSide,
      );
      canvas.drawPath(path, paint);
    }

    void drawHorizontalEdges(double start, double end) {
      if (end - start <= radius * 2) return;
      canvas.drawLine(
        Offset(start + radius, top),
        Offset(end - radius, top),
        paint,
      );
      canvas.drawLine(
        Offset(start + radius, bottom),
        Offset(end - radius, bottom),
        paint,
      );
    }

    drawSide(left, leftSide: true);
    drawSide(right, leftSide: false);
    if (detailWidth > 0) {
      final divider = size.width - detailWidth - 0.5;
      drawHorizontalEdges(left, divider);
      drawHorizontalEdges(divider, right);
      drawSide(divider, leftSide: false, vertical: false);
      drawSide(divider, leftSide: true, vertical: false);
      // Both inner corner pairs join the same one-pixel separator.
      canvas.drawLine(
        Offset(divider, top + radius),
        Offset(divider, bottom - radius),
        paint,
      );
    } else {
      drawHorizontalEdges(left, right);
    }
  }

  @override
  bool shouldRepaint(_ContentPaneOutlinePainter oldDelegate) =>
      color != oldDelegate.color ||
      sidebarWidth != oldDelegate.sidebarWidth ||
      detailWidth != oldDelegate.detailWidth ||
      dividerOpacity != oldDelegate.dividerOpacity ||
      roundCorners != oldDelegate.roundCorners;
}
