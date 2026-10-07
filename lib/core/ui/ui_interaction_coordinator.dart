import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'warmup_scheduler.dart';

class UiInteractionCoordinator extends ChangeNotifier {
  UiInteractionCoordinator({
    this.idleDelay = const Duration(milliseconds: 160),
    this.frameBudget = const Duration(milliseconds: 4),
    this.interactionFrameBudget = const Duration(milliseconds: 1),
  }) : _backgroundScheduler = WarmupScheduler(maxQueueSize: 48);

  static final UiInteractionCoordinator instance = UiInteractionCoordinator();

  final Duration idleDelay;
  final Duration frameBudget;
  final Duration interactionFrameBudget;
  final WarmupScheduler _backgroundScheduler;
  final Set<Object> _activeSources = <Object>{};
  final Set<Object> _navigationSources = <Object>{};
  final Set<Object> _visualUpdateSources = <Object>{};
  final ValueNotifier<bool> _navigationAllowed = ValueNotifier(true);
  final Map<Object, Timer> _idleTimers = <Object, Timer>{};
  final Map<String, _PendingCommit> _pendingCommits =
      <String, _PendingCommit>{};
  final Map<String, Timer> _throttleTimers = <String, Timer>{};
  final Map<String, VoidCallback> _throttledCommits = <String, VoidCallback>{};
  bool _frameScheduled = false;
  int _generation = 0;

  bool get isInteracting => _activeSources.isNotEmpty;
  bool get isVisualUpdateDeferred =>
      _navigationSources.isNotEmpty || _visualUpdateSources.isNotEmpty;
  ValueListenable<bool> get navigationAllowed => _navigationAllowed;
  int get generation => _generation;
  int get pendingCommitCount => _pendingCommits.length;

  int beginGeneration() {
    _generation++;
    _backgroundScheduler.beginGeneration(_generation);
    _dropStaleCommits();
    return _generation;
  }

  void beginNavigation(Object source) {
    _navigationSources.add(source);
    _navigationAllowed.value = false;
    beginInteraction(source);
  }

  void endNavigation(Object source) {
    _navigationSources.remove(source);
    _navigationAllowed.value = _navigationSources.isEmpty;
    endInteraction(source);
    _scheduleCommitFrame();
  }

  void cancelNavigation(Object source) {
    _navigationSources.remove(source);
    _navigationAllowed.value = _navigationSources.isEmpty;
    cancelInteraction(source);
    _scheduleCommitFrame();
  }

  void beginInteraction(Object source, {bool deferVisualUpdates = false}) {
    _idleTimers.remove(source)?.cancel();
    final added = _activeSources.add(source);
    final visualProtectionAdded =
        deferVisualUpdates && _visualUpdateSources.add(source);
    if (!added && !visualProtectionAdded) return;
    _backgroundScheduler.setPaused(true);
    notifyListeners();
  }

  void endInteraction(Object source) {
    if (!_activeSources.contains(source)) return;
    _idleTimers.remove(source)?.cancel();
    if (idleDelay <= Duration.zero) {
      _releaseInteraction(source);
      return;
    }
    _idleTimers[source] = Timer(idleDelay, () {
      _idleTimers.remove(source);
      _releaseInteraction(source);
    });
  }

  void cancelInteraction(Object source) {
    _idleTimers.remove(source)?.cancel();
    _releaseInteraction(source);
  }

  bool scheduleAfterIdle({
    required String key,
    required int generation,
    required int priority,
    String? group,
    required Future<void> Function() task,
  }) {
    if (generation != _generation) return false;
    _backgroundScheduler.setPaused(isInteracting);
    return _backgroundScheduler.schedule(
      key: key,
      priority: priority,
      generation: generation,
      group: group,
      task: task,
    );
  }

  void scheduleCommit({
    required String key,
    int? generation,
    int priority = 100,
    bool allowDuringInteraction = false,
    bool allowDuringScroll = false,
    required VoidCallback commit,
  }) {
    _pendingCommits[key] = _PendingCommit(
      key: key,
      generation: generation,
      priority: priority,
      allowDuringInteraction: allowDuringInteraction,
      allowDuringScroll: allowDuringScroll,
      commit: commit,
    );
    _scheduleCommitFrame();
  }

  void cancelCommit(String key) {
    _pendingCommits.remove(key);
  }

  void scheduleThrottledCommit({
    required String key,
    Duration interval = const Duration(milliseconds: 72),
    required VoidCallback commit,
  }) {
    if (!_throttleTimers.containsKey(key)) {
      commit();
      _armThrottleTimer(key, interval);
      return;
    }
    _throttledCommits[key] = commit;
  }

  void cancelThrottledCommit(String key) {
    _throttleTimers.remove(key)?.cancel();
    _throttledCommits.remove(key);
  }

  void _armThrottleTimer(String key, Duration interval) {
    _throttleTimers[key] = Timer(interval, () {
      _throttleTimers.remove(key);
      final pending = _throttledCommits.remove(key);
      if (pending == null) return;
      pending();
      _armThrottleTimer(key, interval);
    });
  }

  void _dropStaleCommits() {
    _pendingCommits.removeWhere(
      (_, commit) =>
          commit.generation != null && commit.generation != _generation,
    );
  }

  void _releaseInteraction(Object source) {
    if (!_activeSources.remove(source)) return;
    _visualUpdateSources.remove(source);
    _backgroundScheduler.setPaused(isInteracting);
    // Cover queries and scroll commits must resume when first-frame protection
    // ends, even if a separate scroll interaction remains active.
    notifyListeners();
    _scheduleCommitFrame();
  }

  void _scheduleCommitFrame() {
    if (_frameScheduled || !_hasRunnableCommits) return;
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      _flushCommitFrame();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _flushCommitFrame() {
    _dropStaleCommits();
    final commits = _pendingCommits.values.toList(growable: false)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final stopwatch = Stopwatch()..start();
    final budget = isInteracting ? interactionFrameBudget : frameBudget;
    var committedAny = false;
    for (final pending in commits) {
      if (committedAny && stopwatch.elapsed >= budget) break;
      if (!_canRunCommit(pending)) continue;
      if (!identical(_pendingCommits[pending.key], pending)) continue;
      _pendingCommits.remove(pending.key);
      pending.commit();
      committedAny = true;
    }
    if (_hasRunnableCommits) _scheduleCommitFrame();
  }

  bool _canRunCommit(_PendingCommit commit) =>
      !isInteracting ||
      commit.allowDuringInteraction ||
      (commit.allowDuringScroll && !isVisualUpdateDeferred);

  bool get _hasRunnableCommits => _pendingCommits.values.any(_canRunCommit);

  @visibleForTesting
  void flushPendingCommitsForTest() {
    _frameScheduled = false;
    _flushCommitFrame();
  }

  @visibleForTesting
  void finishInteractionsForTest() {
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _activeSources.clear();
    _navigationSources.clear();
    _visualUpdateSources.clear();
    _navigationAllowed.value = true;
    _backgroundScheduler.setPaused(false);
    notifyListeners();
    flushPendingCommitsForTest();
  }

  @visibleForTesting
  void resetForTest() {
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _activeSources.clear();
    _navigationSources.clear();
    _visualUpdateSources.clear();
    _navigationAllowed.value = true;
    _backgroundScheduler.setPaused(false);
    _backgroundScheduler.clear();
    _pendingCommits.clear();
    for (final timer in _throttleTimers.values) {
      timer.cancel();
    }
    _throttleTimers.clear();
    _throttledCommits.clear();
    _frameScheduled = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _activeSources.clear();
    _navigationSources.clear();
    _visualUpdateSources.clear();
    _backgroundScheduler.clear();
    _pendingCommits.clear();
    for (final timer in _throttleTimers.values) {
      timer.cancel();
    }
    _throttleTimers.clear();
    _throttledCommits.clear();
    _navigationAllowed.dispose();
    super.dispose();
  }
}

class _PendingCommit {
  const _PendingCommit({
    required this.key,
    required this.generation,
    required this.priority,
    required this.allowDuringInteraction,
    required this.allowDuringScroll,
    required this.commit,
  });

  final String key;
  final int? generation;
  final int priority;
  final bool allowDuringInteraction;
  final bool allowDuringScroll;
  final VoidCallback commit;
}

class UiInteractionNavigatorObserver extends NavigatorObserver {
  UiInteractionNavigatorObserver({UiInteractionCoordinator? coordinator})
    : _coordinator = coordinator ?? UiInteractionCoordinator.instance;

  static final UiInteractionNavigatorObserver instance =
      UiInteractionNavigatorObserver();

  final UiInteractionCoordinator _coordinator;
  final Object _nonTransitionInteractionSource = Object();
  final Object _gestureInteractionSource = Object();
  final Map<TransitionRoute<dynamic>, _RouteInteraction> _routeInteractions =
      <TransitionRoute<dynamic>, _RouteInteraction>{};
  final Set<ModalRoute<dynamic>> _popRoutes = <ModalRoute<dynamic>>{};
  late final _NavigationPopEntry _popEntry = _NavigationPopEntry(
    _coordinator.navigationAllowed,
  );
  Route<dynamic>? _gestureRoute;

  void _registerPopRoute(Route<dynamic>? route) {
    if (route is ModalRoute<dynamic> && _popRoutes.add(route)) {
      route.registerPopEntry(_popEntry);
      unawaited(
        route.completed.then((_) {
          _releaseRoute(route);
          _unregisterPopRoute(route);
        }),
      );
    }
  }

  void _unregisterPopRoute(Route<dynamic>? route) {
    if (route is ModalRoute<dynamic> && _popRoutes.remove(route)) {
      route.unregisterPopEntry(_popEntry);
    }
  }

  void _trackTransition(
    Route<dynamic>? route, {
    required Set<AnimationStatus> terminalStatuses,
  }) {
    if (route is! TransitionRoute<dynamic>) {
      _coordinator.beginNavigation(_nonTransitionInteractionSource);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _coordinator.endNavigation(_nonTransitionInteractionSource),
      );
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    _releaseRoute(route);
    final interaction = _RouteInteraction();
    _routeInteractions[route] = interaction;
    _coordinator.beginNavigation(interaction.source);
    _attachRouteAnimation(
      route,
      interaction,
      terminalStatuses: terminalStatuses,
    );
  }

  void _attachRouteAnimation(
    TransitionRoute<dynamic> route,
    _RouteInteraction interaction, {
    required Set<AnimationStatus> terminalStatuses,
  }) {
    if (!identical(_routeInteractions[route], interaction)) return;
    final animation = route.animation;
    if (animation == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!identical(_routeInteractions[route], interaction)) return;
        if (route.animation == null) {
          _releaseRoute(route);
          return;
        }
        _attachRouteAnimation(
          route,
          interaction,
          terminalStatuses: terminalStatuses,
        );
      });
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    if (route.transitionDuration == Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _releaseRoute(route));
      SchedulerBinding.instance.scheduleFrame();
      return;
    }

    late final AnimationStatusListener listener;
    listener = (status) {
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        interaction.terminalGeneration++;
        _coordinator.beginNavigation(interaction.source);
        return;
      }
      if (terminalStatuses.contains(status)) {
        _scheduleStableRouteRelease(route, interaction, status);
      }
    };
    interaction.listener = listener;
    animation.addStatusListener(listener);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_routeInteractions[route], interaction)) return;
      // A route popped before its first layout can retain ModalRoute's
      // offstage proxy status (completed), even though its controller stopped.
      if (!route.isActive && !animation.isAnimating) {
        _releaseRoute(route);
        return;
      }
      final status = animation.status;
      if (terminalStatuses.contains(status)) {
        _scheduleStableRouteRelease(route, interaction, status);
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _scheduleStableRouteRelease(
    TransitionRoute<dynamic> route,
    _RouteInteraction interaction,
    AnimationStatus terminalStatus,
  ) {
    final generation = ++interaction.terminalGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_routeInteractions[route], interaction) ||
          interaction.terminalGeneration != generation ||
          route.animation?.status != terminalStatus) {
        return;
      }
      _releaseRoute(route);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _releaseRoute(TransitionRoute<dynamic> route) {
    final interaction = _routeInteractions.remove(route);
    if (interaction == null) return;
    final listener = interaction.listener;
    if (listener != null) route.animation?.removeStatusListener(listener);
    _coordinator.endNavigation(interaction.source);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _registerPopRoute(route);
    if (previousRoute == null) return;
    _trackTransition(
      route,
      terminalStatuses: const <AnimationStatus>{AnimationStatus.completed},
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _unregisterPopRoute(route);
    _trackTransition(
      route,
      terminalStatuses: const <AnimationStatus>{AnimationStatus.dismissed},
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _unregisterPopRoute(oldRoute);
    _registerPopRoute(newRoute);
    if (oldRoute is TransitionRoute<dynamic>) _releaseRoute(oldRoute);
    if (newRoute != null) {
      _trackTransition(
        newRoute,
        terminalStatuses: const <AnimationStatus>{AnimationStatus.completed},
      );
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _unregisterPopRoute(route);
    if (route is TransitionRoute<dynamic>) _releaseRoute(route);
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _gestureRoute = route;
    _coordinator.beginNavigation(_gestureInteractionSource);
  }

  @override
  void didStopUserGesture() {
    final route = _gestureRoute;
    _gestureRoute = null;
    if (route != null) {
      _trackTransition(
        route,
        terminalStatuses: const <AnimationStatus>{
          AnimationStatus.completed,
          AnimationStatus.dismissed,
        },
      );
    }
    _coordinator.endNavigation(_gestureInteractionSource);
  }

  @visibleForTesting
  void resetForTest() {
    for (final route in _popRoutes) {
      route.unregisterPopEntry(_popEntry);
    }
    _popRoutes.clear();
    for (final entry in _routeInteractions.entries) {
      final listener = entry.value.listener;
      if (listener != null) {
        entry.key.animation?.removeStatusListener(listener);
      }
      _coordinator.cancelNavigation(entry.value.source);
    }
    _routeInteractions.clear();
    _gestureRoute = null;
    _coordinator.cancelNavigation(_nonTransitionInteractionSource);
    _coordinator.cancelNavigation(_gestureInteractionSource);
  }
}

class _NavigationPopEntry extends PopEntry<dynamic> {
  _NavigationPopEntry(this.canPopNotifier);

  @override
  final ValueListenable<bool> canPopNotifier;
}

class _RouteInteraction {
  final Object source = Object();
  AnimationStatusListener? listener;
  int terminalGeneration = 0;
}
