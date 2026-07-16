import 'dart:async';

final class AudioStateSlice<T> {
  AudioStateSlice(this._state);

  T _state;
  final StreamController<T> _controller = StreamController<T>.broadcast();

  T get state => _state;

  Stream<T> get stream async* {
    yield _state;
    yield* _controller.stream;
  }

  void update(T next) {
    if (next == _state) return;
    _state = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }

  Future<void> dispose() => _controller.close();
}
