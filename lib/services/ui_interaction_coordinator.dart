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
    for (final pending in commits) {
      if (stopwatch.elapsed >= budget) break;
      if (isInteracting && !pending.allowDuringInteraction) continue;
      if (!identical(_pendingCommits[pending.key], pending)) continue;
      _pendingCommits.remove(pending.key);
      pending.commit();
    }
    if (_hasRunnableCommits) _scheduleCommitFrame();
  }

  bool get _hasRunnableCommits =>
      _pendingCommits.isNotEmpty &&
      (!isInteracting ||
          _pendingCommits.values.any(
            (commit) => commit.allowDuringInteraction,
          ));

  @override
  void dispose() {
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _backgroundScheduler.clear();
    _pendingCommits.clear();
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
  UiInteractionNavigatorObserver._();

  static final UiInteractionNavigatorObserver instance =
      UiInteractionNavigatorObserver._();

  final Object _interactionSource = Object();
  Timer? _transitionTimer;

  void _trackTransition(Route<dynamic>? route) {
    final coordinator = UiInteractionCoordinator.instance;
    coordinator.beginInteraction(_interactionSource);
    _transitionTimer?.cancel();
    final duration = route is TransitionRoute<dynamic>
        ? route.transitionDuration
        : const Duration(milliseconds: 300);
    _transitionTimer = Timer(
      duration,
      () => coordinator.endInteraction(_interactionSource),
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    _trackTransition(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackTransition(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _trackTransition(newRoute ?? oldRoute);
  }
}
