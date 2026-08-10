import 'dart:async';

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
  final Map<Object, Timer> _idleTimers = <Object, Timer>{};
  final Map<String, _PendingCommit> _pendingCommits =
      <String, _PendingCommit>{};
  final Map<String, Timer> _throttleTimers = <String, Timer>{};
  final Map<String, VoidCallback> _throttledCommits = <String, VoidCallback>{};
  bool _frameScheduled = false;
  int _generation = 0;

  bool get isInteracting => _activeSources.isNotEmpty;
  int get generation => _generation;
  int get pendingCommitCount => _pendingCommits.length;

  int beginGeneration() {
    _generation++;
    _backgroundScheduler.beginGeneration(_generation);
    _dropStaleCommits();
    return _generation;
  }

  void beginInteraction(Object source) {
    _idleTimers.remove(source)?.cancel();
    if (!_activeSources.add(source)) return;
    _backgroundScheduler.setPaused(true);
    notifyListeners();
  }

  void endInteraction(Object source) {
    if (!_activeSources.contains(source)) return;
    _idleTimers.remove(source)?.cancel();
    if (idleDelay <= Duration.zero) {
      if (_activeSources.remove(source)) _resumeIfIdle();
      return;
    }
    _idleTimers[source] = Timer(idleDelay, () {
      _idleTimers.remove(source);
      if (_activeSources.remove(source)) _resumeIfIdle();
    });
  }

  void cancelInteraction(Object source) {
    _idleTimers.remove(source)?.cancel();
    if (_activeSources.remove(source)) _resumeIfIdle();
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
    required VoidCallback commit,
  }) {
    _pendingCommits[key] = _PendingCommit(
      key: key,
      generation: generation,
      priority: priority,
      allowDuringInteraction: allowDuringInteraction,
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

  void _resumeIfIdle() {
    if (isInteracting) return;
    _backgroundScheduler.setPaused(false);
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
      if (isInteracting && !pending.allowDuringInteraction) continue;
      if (!identical(_pendingCommits[pending.key], pending)) continue;
      _pendingCommits.remove(pending.key);
      pending.commit();
      committedAny = true;
    }
    if (_hasRunnableCommits) _scheduleCommitFrame();
  }

  bool get _hasRunnableCommits =>
      _pendingCommits.isNotEmpty &&
      (!isInteracting ||
          _pendingCommits.values.any(
            (commit) => commit.allowDuringInteraction,
          ));

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
    _backgroundScheduler.setPaused(false);
    flushPendingCommitsForTest();
  }

  @visibleForTesting
  void resetForTest() {
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _activeSources.clear();
    _backgroundScheduler.setPaused(false);
    _backgroundScheduler.clear();
    _pendingCommits.clear();
    for (final timer in _throttleTimers.values) {
      timer.cancel();
    }
    _throttleTimers.clear();
    _throttledCommits.clear();
    _frameScheduled = false;
  }

  @override
  void dispose() {
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _backgroundScheduler.clear();
    _pendingCommits.clear();
    for (final timer in _throttleTimers.values) {
      timer.cancel();
    }
    _throttleTimers.clear();
    _throttledCommits.clear();
    super.dispose();
  }
}

class _PendingCommit {
  const _PendingCommit({
    required this.key,
    required this.generation,
    required this.priority,
    required this.allowDuringInteraction,
    required this.commit,
  });

  final String key;
  final int? generation;
  final int priority;
  final bool allowDuringInteraction;
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
  Route<dynamic>? _gestureRoute;

  void _trackTransition(
    Route<dynamic>? route, {
    required Set<AnimationStatus> terminalStatuses,
  }) {
    if (route is! TransitionRoute<dynamic>) {
      _coordinator.beginInteraction(_nonTransitionInteractionSource);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _coordinator.endInteraction(_nonTransitionInteractionSource),
      );
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    _releaseRoute(route);
    final interaction = _RouteInteraction();
    _routeInteractions[route] = interaction;
    _coordinator.beginInteraction(interaction.source);
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
        _coordinator.beginInteraction(interaction.source);
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
    _coordinator.endInteraction(interaction.source);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    _trackTransition(
      route,
      terminalStatuses: const <AnimationStatus>{AnimationStatus.completed},
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackTransition(
      route,
      terminalStatuses: const <AnimationStatus>{AnimationStatus.dismissed},
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
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
    if (route is TransitionRoute<dynamic>) _releaseRoute(route);
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _gestureRoute = route;
    _coordinator.beginInteraction(_gestureInteractionSource);
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
    _coordinator.endInteraction(_gestureInteractionSource);
  }

  @visibleForTesting
  void resetForTest() {
    for (final entry in _routeInteractions.entries) {
      final listener = entry.value.listener;
      if (listener != null) {
        entry.key.animation?.removeStatusListener(listener);
      }
      _coordinator.cancelInteraction(entry.value.source);
    }
    _routeInteractions.clear();
    _gestureRoute = null;
    _coordinator.cancelInteraction(_nonTransitionInteractionSource);
    _coordinator.cancelInteraction(_gestureInteractionSource);
  }
}

class _RouteInteraction {
  final Object source = Object();
  AnimationStatusListener? listener;
  int terminalGeneration = 0;
}
