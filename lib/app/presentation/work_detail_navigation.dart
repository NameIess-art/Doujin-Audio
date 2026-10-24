import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/widgets/app_transitions.dart';
import 'main_screen.dart';
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
  Object? _identity;
  Future<void>? _completion;
  bool _scheduled = false;
  bool _disposed = false;
  int _request = 0;

  bool get isOpen => _routes.length > 1 || _closing.isNotEmpty;
  bool get isContentOpen =>
      _contentRoutes.length > 1 || _contentClosing.isNotEmpty;

  static Future<void> openFrom(
    BuildContext context,
    Object identity,
    PageRoute<void> Function(BuildContext context) buildRoute, {
    bool returnToMain = false,
  }) async {
    final navigator = Navigator.of(context);
    final origin = readAppRoute(context);
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted || !navigator.mounted || origin?.isCurrent == false) {
      return;
    }
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    if (navigation != null &&
        (returnToMain || navigation.canOpenInPane(context))) {
      await navigation.open(identity, buildRoute, returnToMain: returnToMain);
      return;
    }
    final route = buildRoute(context);
    if (returnToMain) {
      await navigator.pushAndRemoveUntil<void>(route, (route) => route.isFirst);
    } else {
      await navigator.push<void>(route);
    }
  }

  void resetContent() {
    menuDismiss.value?.call();
    final navigator = contentNavigatorKey.currentState;
    if (navigator == null) return;
    for (final route in _contentRoutes.skip(1).toList().reversed) {
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
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
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
    return ListenableBuilder(
      listenable: Listenable.merge([navigation, navigation.menuDismiss]),
      child: child,
      builder: (context, child) {
        // The main body fills this MediaQuery. Update route metrics before
        // layout, so resizing cannot rebuild navigator overlays during layout.
        final size = MediaQuery.sizeOf(context);
        final contentWidth = (size.width - sidebarWidth).clamp(0.0, size.width);
        final paneWidth = isLandscape
            ? (contentWidth - 1).clamp(0.0, contentWidth) / 2
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
        return PopScope<Object?>(
          canPop:
              !navigation.isOpen &&
              !navigation.isContentOpen &&
              navigation.menuDismiss.value == null,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop ||
                !UiInteractionCoordinator.instance.navigationAllowed.value) {
              return;
            }
            final dismissMenu = navigation.menuDismiss.value;
            if (dismissMenu != null) {
              dismissMenu();
            } else {
              final navigator = navigation.isOpen
                  ? navigation.navigatorKey.currentState
                  : navigation.contentNavigatorKey.currentState;
              unawaited(navigator?.maybePop());
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              child!,
              Positioned(
                right: paneWidth,
                top: 0,
                bottom: 0,
                width: 1,
                child: Offstage(
                  offstage: !navigation.isOpen || !isLandscape,
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              Positioned(
                key: const ValueKey('work_detail_pane_bounds'),
                right: 0,
                top: 0,
                bottom: 0,
                width: paneWidth,
                child: Offstage(
                  offstage: !navigation.isOpen,
                  child: Builder(
                    builder: (context) {
                      final mediaQuery = MediaQuery.of(context);
                      return MediaQuery(
                        data: mediaQuery.copyWith(
                          size: Size(paneWidth, size.height),
                          padding: mediaQuery.padding.copyWith(left: 0),
                          viewPadding: mediaQuery.viewPadding.copyWith(left: 0),
                        ),
                        child: detailNavigator,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
