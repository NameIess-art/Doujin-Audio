import 'dart:async';

class WarmupScheduler {
  WarmupScheduler({this.maxConcurrent = 1, this.maxQueueSize = 12});

  final int maxConcurrent;
  final int maxQueueSize;

  final List<_QueuedWarmupTask> _pending = <_QueuedWarmupTask>[];
  final Set<String> _queuedKeys = <String>{};
  final Set<String> _activeKeys = <String>{};
  Timer? _cooldownTimer;
  Completer<void>? _idleCompleter;

  int _currentGeneration = 0;
  bool _isCoolingDown = false;
  bool _isPaused = false;
  bool _isShutDown = false;

  int get currentGeneration => _currentGeneration;
  int get pendingCount => _pending.length;
  int get activeCount => _activeKeys.length;
  bool get isPaused => _isPaused;
  bool get isIdle => _pending.isEmpty && _activeKeys.isEmpty && !_isCoolingDown;

  Future<void> get idle {
    if (isIdle) return Future<void>.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  void setPaused(bool value) {
    if (_isShutDown) return;
    if (_isPaused == value) return;
    _isPaused = value;
    if (!value) _pump();
  }

  void beginGeneration(int generation, {Duration cooldown = Duration.zero}) {
    if (_isShutDown) return;
    _currentGeneration = generation;
    _dropStalePending();
    _cooldownTimer?.cancel();
    _isCoolingDown = cooldown > Duration.zero;
    if (_isCoolingDown) {
      _markBusy();
      _cooldownTimer = Timer(cooldown, () {
        _cooldownTimer = null;
        _isCoolingDown = false;
        _pump();
        _completeIdleIfNeeded();
      });
    }
    _pump();
  }

  bool schedule({
    required String key,
    required int priority,
    required int generation,
    String? group,
    required Future<void> Function() task,
  }) {
    if (_isShutDown) return false;
    if (generation != _currentGeneration) return false;
    if (_queuedKeys.contains(key) || _activeKeys.contains(key)) return false;

    final queuedTask = _QueuedWarmupTask(
      key: key,
      priority: priority,
      generation: generation,
      group: group,
      task: task,
    );

    if (_pending.length >= maxQueueSize) {
      final worstTask = _pending.isEmpty
          ? null
          : _pending.reduce(
              (left, right) => left.priority >= right.priority ? left : right,
            );
      if (worstTask == null || worstTask.priority <= priority) {
        return false;
      }
      _pending.remove(worstTask);
      _queuedKeys.remove(worstTask.key);
    }

    _pending.add(queuedTask);
    _markBusy();
    _pending.sort((left, right) => left.priority.compareTo(right.priority));
    _queuedKeys.add(key);
    _pump();
    return true;
  }

  void clear() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _isCoolingDown = false;
    _pending.clear();
    _queuedKeys.clear();
    _completeIdleIfNeeded();
  }

  Future<void> shutdown() {
    _isShutDown = true;
    clear();
    return idle;
  }

  void clearGroup(String group) {
    _pending.removeWhere((task) {
      if (task.group != group) return false;
      _queuedKeys.remove(task.key);
      return true;
    });
  }

  void _dropStalePending() {
    _pending.removeWhere((task) {
      if (task.generation == _currentGeneration) {
        return false;
      }
      _queuedKeys.remove(task.key);
      return true;
    });
  }

  void _pump() {
    if (_isShutDown || _isCoolingDown || _isPaused) return;
    while (_activeKeys.length < maxConcurrent && _pending.isNotEmpty) {
      final nextTask = _pending.removeAt(0);
      _queuedKeys.remove(nextTask.key);
      if (nextTask.generation != _currentGeneration) {
        continue;
      }
      _activeKeys.add(nextTask.key);
      unawaited(_runTask(nextTask));
    }
  }

  Future<void> _runTask(_QueuedWarmupTask task) async {
    try {
      if (task.generation == _currentGeneration) {
        await task.task();
      }
    } finally {
      _activeKeys.remove(task.key);
      _pump();
      _completeIdleIfNeeded();
    }
  }

  void _markBusy() {
    if (_idleCompleter?.isCompleted ?? false) {
      _idleCompleter = null;
    }
  }

  void _completeIdleIfNeeded() {
    if (!isIdle) return;
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

class _QueuedWarmupTask {
  const _QueuedWarmupTask({
    required this.key,
    required this.priority,
    required this.generation,
    this.group,
    required this.task,
  });

  final String key;
  final int priority;
  final int generation;
  final String? group;
  final Future<void> Function() task;
}
