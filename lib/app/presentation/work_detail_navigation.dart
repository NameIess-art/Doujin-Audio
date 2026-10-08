import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ui/ui_interaction_coordinator.dart';
import 'main_screen.dart';
import 'routed_playback_dock_host.dart';

/// Owns page navigation only; library and playback state stay in their facades.
class WorkDetailNavigation extends ChangeNotifier {
  WorkDetailNavigation({required this.rootNavigatorKey}) {
    observer = _WorkDetailObserver(this);
  }

  final GlobalKey<NavigatorState> rootNavigatorKey;
  final navigatorKey = GlobalKey<NavigatorState>();
  final menuDismiss = ValueNotifier<VoidCallback?>(null);
  late final NavigatorObserver observer;
  final List<Route<dynamic>> _routes = [];
  final Set<Route<dynamic>> _closing = {};
  Object? _identity;
  Future<void>? _completion;
  bool _scheduled = false;
  bool _disposed = false;
  int _request = 0;

  bool get isOpen => _routes.length > 1 || _closing.isNotEmpty;

  bool canOpenInPane(BuildContext context) {
    final originNavigator = Navigator.of(context);
    // Root pages such as search cover the main route and mute its navigator's
    // tickers. Their details must stay on the visible root stack.
    return originNavigator == navigatorKey.currentState ||
        (originNavigator == rootNavigatorKey.currentState &&
            ModalRoute.of(context)?.isFirst == true);
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
  _WorkDetailObserver(this.navigation);

  final WorkDetailNavigation navigation;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    navigation._routes.add(route);
    navigation._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    navigation._routes.remove(route);
    // Keep the pane's bounds stable until the last page has painted its exit.
    if (route is TransitionRoute<dynamic>) {
      navigation._closing.add(route);
      unawaited(
        route.completed.then((_) {
          navigation._closing.remove(route);
          navigation._changed();
        }),
      );
    }
    navigation._changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    navigation._routes.remove(route);
    navigation._changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : navigation._routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) navigation._routes[index] = newRoute;
    navigation._changed();
  }
}

class WorkDetailNavigationScope extends InheritedWidget {
  const WorkDetailNavigationScope({
    super.key,
    required this.navigation,
    required super.child,
  });

  final WorkDetailNavigation navigation;

  static WorkDetailNavigation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WorkDetailNavigationScope>()
      ?.navigation;

  @override
  bool updateShouldNotify(WorkDetailNavigationScope oldWidget) =>
      navigation != oldWidget.navigation;
}

class WorkDetailPane extends StatefulWidget {
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
  State<WorkDetailPane> createState() => _WorkDetailPaneState();
}

class _WorkDetailPaneState extends State<WorkDetailPane> {
  final _interactionObserver = UiInteractionNavigatorObserver();

  @override
  void dispose() {
    _interactionObserver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    if (navigation == null) return widget.child;
    return ListenableBuilder(
      listenable: Listenable.merge([navigation, navigation.menuDismiss]),
      child: widget.child,
      builder: (context, child) {
        // The main body fills this MediaQuery. Update route metrics before
        // layout, so resizing cannot rebuild navigator overlays during layout.
        final mediaQuery = MediaQuery.of(context);
        final size = mediaQuery.size;
        final contentWidth = (size.width - widget.sidebarWidth).clamp(
          0.0,
          size.width,
        );
        final paneWidth = widget.isLandscape
            ? (contentWidth - 1).clamp(0.0, contentWidth) / 2
            : size.width;
        return PopScope<Object?>(
          canPop: !navigation.isOpen && navigation.menuDismiss.value == null,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop ||
                !UiInteractionCoordinator.instance.navigationAllowed.value) {
              return;
            }
            final dismissMenu = navigation.menuDismiss.value;
            if (dismissMenu != null) {
              dismissMenu();
            } else {
              unawaited(navigation.navigatorKey.currentState!.maybePop());
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
                  offstage: !navigation.isOpen || !widget.isLandscape,
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
                  child: MediaQuery(
                    data: mediaQuery.copyWith(
                      size: Size(paneWidth, size.height),
                      padding: mediaQuery.padding.copyWith(left: 0),
                      viewPadding: mediaQuery.viewPadding.copyWith(left: 0),
                    ),
                    child: ClipRect(
                      key: const ValueKey('work_detail_pane'),
                      child: RoutedPlaybackDockHost(
                        navigatorKey: navigation.navigatorKey,
                        playbackNavigatorKey: navigation.rootNavigatorKey,
                        geometry: widget.geometry,
                        enabled: !widget.isLandscape,
                        menuDismiss: navigation.menuDismiss,
                        backgroundColor: widget.isLandscape
                            ? null
                            : Colors.transparent,
                        builder: (context, observer, geometry, wrapNavigator) =>
                            wrapNavigator(
                              context,
                              Navigator(
                                key: navigation.navigatorKey,
                                observers: [
                                  navigation.observer,
                                  observer,
                                  _interactionObserver,
                                ],
                                onGenerateRoute: (_) => MaterialPageRoute<void>(
                                  builder: (_) => const SizedBox.shrink(),
                                ),
                              ),
                            ),
                      ),
                    ),
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
