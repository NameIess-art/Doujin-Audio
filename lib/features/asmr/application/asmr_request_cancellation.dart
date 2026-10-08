import 'dart:async';

final class AsmrRequestCancellationToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const AsmrRequestCancelled();
  }

  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  Future<T> waitFor<T>(Future<T> future) async {
    final result = Completer<T>();
    final removeListener = addListener(() {
      if (!result.isCompleted) {
        result.completeError(const AsmrRequestCancelled());
      }
    });
    // Keep observing the underlying task after cancellation so its eventual
    // error is consumed even when SQLite or compute cannot be interrupted.
    unawaited(
      future.then<void>(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        },
      ),
    );
    try {
      return await result.future;
    } finally {
      removeListener();
    }
  }

  Future<void> delay(Duration duration) async {
    throwIfCancelled();
    final completed = Completer<void>();
    final timer = Timer(duration, completed.complete);
    try {
      await waitFor(completed.future);
    } finally {
      timer.cancel();
    }
  }
}

final class AsmrRequestCancelled implements Exception {
  const AsmrRequestCancelled();
}
