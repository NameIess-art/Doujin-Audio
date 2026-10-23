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
  Completer<void>? _capacityCompleter;

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

  Future<void> get capacityAvailable {
    if (_isShutDown || _pending.length < maxQueueSize) {
      return Future<void>.value();
    }
    return (_capacityCompleter ??= Completer<void>()).future;
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
    int Function()? priorityResolver,
    required int generation,
    void Function()? onDiscard,
    required Future<void> Function() task,
  }) {
    if (_isShutDown) return false;
    if (generation != _currentGeneration) return false;
    if (_queuedKeys.contains(key) || _activeKeys.contains(key)) return false;

    final queuedTask = _QueuedWarmupTask(
      key: key,
      priority: priority,
      priorityResolver: priorityResolver,
      generation: generation,
      onDiscard: onDiscard,
      task: task,
    );

    if (_pending.length >= maxQueueSize) {
      if (_pending.isEmpty) return false;
      var worstIndex = 0;
      var worstPriority = _pending.first.effectivePriority;
      for (var index = 1; index < _pending.length; index++) {
        final priority = _pending[index].effectivePriority;
        if (priority > worstPriority) {
          worstIndex = index;
          worstPriority = priority;
        }
      }
      if (worstPriority <= queuedTask.effectivePriority) return false;
      final worstTask = _pending.removeAt(worstIndex);
      _queuedKeys.remove(worstTask.key);
      worstTask.onDiscard?.call();
    }

    _pending.add(queuedTask);
    _markBusy();
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
    _completeCapacityIfAvailable();
    _completeIdleIfNeeded();
  }

  Future<void> shutdown() {
    _isShutDown = true;
    clear();
    return idle;
  }

  void _dropStalePending() {
    _pending.removeWhere((task) {
      if (task.generation == _currentGeneration) {
        return false;
      }
      _queuedKeys.remove(task.key);
      return true;
    });
    _completeCapacityIfAvailable();
  }

  void _pump() {
    if (_isShutDown || _isCoolingDown || _isPaused) return;
    while (_activeKeys.length < maxConcurrent && _pending.isNotEmpty) {
      var nextIndex = 0;
      var nextPriority = _pending.first.effectivePriority;
      for (var index = 1; index < _pending.length; index++) {
        final priority = _pending[index].effectivePriority;
        if (priority < nextPriority) {
          nextIndex = index;
          nextPriority = priority;
        }
      }
      final nextTask = _pending.removeAt(nextIndex);
      _queuedKeys.remove(nextTask.key);
      _completeCapacityIfAvailable();
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

  void _completeCapacityIfAvailable() {
    if (!_isShutDown && _pending.length >= maxQueueSize) return;
    final completer = _capacityCompleter;
    _capacityCompleter = null;
    completer?.complete();
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
    this.priorityResolver,
    required this.generation,
    this.onDiscard,
    required this.task,
  });

  final String key;
  final int priority;
  final int Function()? priorityResolver;
  final int generation;
  final void Function()? onDiscard;
  final Future<void> Function() task;

  int get effectivePriority => priorityResolver?.call() ?? priority;
}
