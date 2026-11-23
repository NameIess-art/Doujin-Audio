abstract interface class AppRuntimeLifecycle {
  Future<void> start();

  Future<void> initializeSecondaryData();

  Future<void> enterBackground();

  Future<void> resumeForeground();

  Future<void> dispose({bool fastShutdown = false});

  Future<void> handleMemoryPressure() => Future<void>.value();
}
