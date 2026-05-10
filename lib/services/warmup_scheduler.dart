import 'dart:async';

class WarmupScheduler {
  WarmupScheduler({this.maxConcurrent = 2, this.maxQueueSize = 12});

  final int maxConcurrent;
  final int maxQueueSize;

  final List<_QueuedWarmupTask> _pending = <_QueuedWarmupTask>[];
  final Set<String> _queuedKeys = <String>{};
  final Set<String> _activeKeys = <String>{};

  int _currentGeneration = 0;

  int get currentGeneration => _currentGeneration;
  int get pendingCount => _pending.length;
  int get activeCount => _activeKeys.length;

  void beginGeneration(int generation) {
    _currentGeneration = generation;
    _dropStalePending();
    _pump();
  }

  bool schedule({
    required String key,
    required int priority,
    required int generation,
    required Future<void> Function() task,
  }) {
    if (generation != _currentGeneration) return false;
    if (_queuedKeys.contains(key) || _activeKeys.contains(key)) return false;

    final queuedTask = _QueuedWarmupTask(
      key: key,
      priority: priority,
      generation: generation,
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
    _pending.sort((left, right) => left.priority.compareTo(right.priority));
    _queuedKeys.add(key);
    _pump();
    return true;
  }

  void clear() {
    _pending.clear();
    _queuedKeys.clear();
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
    }
  }
}

class _QueuedWarmupTask {
  const _QueuedWarmupTask({
    required this.key,
    required this.priority,
    required this.generation,
    required this.task,
  });

  final String key;
  final int priority;
  final int generation;
  final Future<void> Function() task;
}
