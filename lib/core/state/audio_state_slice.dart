import 'dart:async';

final class AudioStateSlice<T> {
  AudioStateSlice(this._state, {bool sync = false})
    : _controller = StreamController<T>.broadcast(sync: sync);

  T _state;
  final StreamController<T> _controller;

  T get state => _state;

  bool get hasListeners => _controller.hasListener;

  Stream<T> get stream => Stream<T>.multi((output) {
    final subscription = _controller.stream.listen(
      output.addSync,
      onError: output.addErrorSync,
      onDone: output.closeSync,
    );
    output.onCancel = subscription.cancel;
    output.addSync(_state);
  }, isBroadcast: true);

  void update(T next) {
    if (next == _state) return;
    _state = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }

  Future<void> dispose() => _controller.close();
}
