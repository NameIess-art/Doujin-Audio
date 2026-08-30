import 'dart:async';

typedef UndoableRemovalPrepare = FutureOr<bool> Function();
typedef UndoableRemovalCallback = FutureOr<void> Function();

final class UndoableRemovalKey {
  const UndoableRemovalKey(this.namespace, this.id);

  final String namespace;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is UndoableRemovalKey &&
      other.namespace == namespace &&
      other.id == id;

  @override
  int get hashCode => Object.hash(namespace, id);
}

final class UndoableRemovalAction {
  const UndoableRemovalAction({
    required this.key,
    required this.commit,
    required this.undo,
    this.prepare,
  });

  final UndoableRemovalKey key;
  final UndoableRemovalPrepare? prepare;
  final UndoableRemovalCallback commit;
  final UndoableRemovalCallback undo;
}

final class UndoableRemovalState {
  const UndoableRemovalState({
    this.hiddenKeys = const <UndoableRemovalKey>{},
    this.pendingCount = 0,
    this.committingCount = 0,
    this.batchRevision = 0,
  });

  final Set<UndoableRemovalKey> hiddenKeys;
  final int pendingCount;
  final int committingCount;
  final int batchRevision;

  bool isHidden(UndoableRemovalKey key) => hiddenKeys.contains(key);
  bool get hasPending => pendingCount > 0;
}

final class UndoableRemovalService {
  UndoableRemovalService();

  static final UndoableRemovalService instance = UndoableRemovalService();

  final Map<UndoableRemovalKey, UndoableRemovalAction> _pending = {};
  final Set<UndoableRemovalKey> _preparing = {};
  final Set<UndoableRemovalKey> _committing = {};
  final StreamController<UndoableRemovalState> _changes =
      StreamController<UndoableRemovalState>.broadcast(sync: true);
  UndoableRemovalState _state = const UndoableRemovalState();
  Future<void> _operationTail = Future<void>.value();
  bool _disposed = false;

  UndoableRemovalState get state => _state;
  Stream<UndoableRemovalState> get changes => _changes.stream;

  Future<bool> stage(UndoableRemovalAction action) async {
    if (_disposed || _state.isHidden(action.key)) return false;
    _preparing.add(action.key);
    _emit();
    try {
      if (await action.prepare?.call() == false) {
        _preparing.remove(action.key);
        _emit();
        return false;
      }
    } catch (_) {
      _preparing.remove(action.key);
      _emit();
      return false;
    }
    _preparing.remove(action.key);
    if (_disposed) {
      await action.undo();
      return false;
    }
    _pending[action.key] = action;
    _emit(batchChanged: true);
    return true;
  }

  Future<int> undoPending() => _serialize(() async {
    if (_pending.isEmpty) return 0;
    final actions = _pending.values.toList(growable: false).reversed.toList();
    _pending.clear();
    _emit(batchChanged: true);
    var failures = 0;
    for (final action in actions) {
      try {
        await action.undo();
      } catch (_) {
        failures++;
      }
    }
    return failures;
  });

  Future<int> commitPending() => _serialize(() async {
    if (_pending.isEmpty) return 0;
    final actions = _pending.values.toList(growable: false);
    _pending.clear();
    _committing.addAll(actions.map((action) => action.key));
    _emit(batchChanged: true);
    var failures = 0;
    for (final action in actions) {
      try {
        await action.commit();
      } catch (_) {
        failures++;
        try {
          await action.undo();
        } catch (_) {
          // The original failure remains authoritative.
        }
      } finally {
        _committing.remove(action.key);
        _emit();
      }
    }
    return failures;
  });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _emit({bool batchChanged = false}) {
    if (_disposed) return;
    _state = UndoableRemovalState(
      hiddenKeys: Set<UndoableRemovalKey>.unmodifiable(<UndoableRemovalKey>{
        ..._preparing,
        ..._pending.keys,
        ..._committing,
      }),
      pendingCount: _pending.length,
      committingCount: _committing.length,
      batchRevision: _state.batchRevision + (batchChanged ? 1 : 0),
    );
    _changes.add(_state);
  }

  void resetForTest() {
    _pending.clear();
    _preparing.clear();
    _committing.clear();
    _state = const UndoableRemovalState();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    _preparing.clear();
    _committing.clear();
    await _changes.close();
  }
}
