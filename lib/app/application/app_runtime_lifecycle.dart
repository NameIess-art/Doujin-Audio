abstract interface class AppRuntimeLifecycle {
  Future<void> start();

  Future<void> enterBackground();

  Future<void> resumeForeground();

  Future<void> dispose();

  Future<void> handleMemoryPressure() => Future<void>.value();
}
