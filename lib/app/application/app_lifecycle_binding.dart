import 'dart:async';
import '../../core/network/app_network.dart';
import '../../core/logging/app_log_service.dart';

import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/library/application/cover_image_cache_policy.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../core/cache/app_cache_service.dart';
import '../../features/settings/application/settings_repository.dart';
import 'app_persistence_coordinator.dart';
import 'app_runtime_lifecycle.dart';
import 'audio_runtime_coordinator.dart';
import 'audio_ui_warmup_coordinator.dart';
import '../../features/player/application/playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';
import 'runtime_binding.dart';
import '../../features/player/application/listening_activity_service.dart';

final class AppLifecycleBinding implements RuntimeBinding, AppRuntimeLifecycle {
  AppLifecycleBinding._({
    required AppPersistenceCoordinator persistence,
    required LibraryFacade library,
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required SettingsRepository settings,
    required AudioUiWarmupCoordinator warmup,
    required PlaybackKeepAliveCoordinator keepAlive,
    required PlaybackCommandCoordinator playbackCommands,
    AsmrDownloadManager? asmrDownloads,
    required List<RuntimeBinding> bindings,
    Future<void> Function()? disposeWorkTexts,
    ListeningActivityService? listeningActivity,
    Future<void> Function()? initializeSecondaryData,
    Future<void> Function()? initializeListeningHistory,
    void Function()? disposeSecondaryData,
  }) : _persistence = persistence,
       _library = library,
       _playback = playback,
       _timer = timer,
       _notifications = notifications,
       _settings = settings,
       _warmup = warmup,
       _keepAlive = keepAlive,
       _playbackCommands = playbackCommands,
       _asmrDownloads = asmrDownloads,
       _disposeWorkTexts = disposeWorkTexts,
       _listeningActivity = listeningActivity,
       _initializeSecondaryData = initializeSecondaryData,
       _initializeListeningHistory = initializeListeningHistory,
       _disposeSecondaryData = disposeSecondaryData,
       _bindings = List<RuntimeBinding>.unmodifiable(bindings) {
    _runtime = AudioRuntimeCoordinator(
      snapshots: playback.nativeRepository.snapshots,
      progressUpdates: playback.nativeRepository.progressUpdates,
      startListening: playback.nativeRepository.startListening,
      stopListening: playback.nativeRepository.stopListening,
      onSnapshot: playbackCommands.handleNativeSnapshot,
      onProgress: playback.applyNativeProgress,
      onStart: () => AppLogService.measureAsync(
        'app_core_initialization',
        persistence.loadPersistedState,
      ),
      onEnterBackground: _enterBackground,
      onResumeForeground: _resumeForeground,
      onDispose: _disposeRuntime,
      onMemoryPressure: _handleMemoryPressure,
    );
  }

  static AppLifecycleBinding attach({
    required AppPersistenceCoordinator persistence,
    required LibraryFacade library,
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required SettingsRepository settings,
    required AudioUiWarmupCoordinator warmup,
    required PlaybackKeepAliveCoordinator keepAlive,
    required PlaybackCommandCoordinator playbackCommands,
    AsmrDownloadManager? asmrDownloads,
    required List<RuntimeBinding> bindings,
    Future<void> Function()? disposeWorkTexts,
    ListeningActivityService? listeningActivity,
    Future<void> Function()? initializeSecondaryData,
    Future<void> Function()? initializeListeningHistory,
    void Function()? disposeSecondaryData,
  }) {
    return AppLifecycleBinding._(
      persistence: persistence,
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      settings: settings,
      warmup: warmup,
      keepAlive: keepAlive,
      playbackCommands: playbackCommands,
      asmrDownloads: asmrDownloads,
      bindings: bindings,
      disposeWorkTexts: disposeWorkTexts,
      listeningActivity: listeningActivity,
      initializeSecondaryData: initializeSecondaryData,
      initializeListeningHistory: initializeListeningHistory,
      disposeSecondaryData: disposeSecondaryData,
    );
  }

  final AppPersistenceCoordinator _persistence;
  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final TimerFacade _timer;
  final NotificationFacade _notifications;
  final SettingsRepository _settings;
  final AudioUiWarmupCoordinator _warmup;
  final PlaybackKeepAliveCoordinator _keepAlive;
  final PlaybackCommandCoordinator _playbackCommands;
  final AsmrDownloadManager? _asmrDownloads;
  final List<RuntimeBinding> _bindings;
  final ListeningActivityService? _listeningActivity;
  final Future<void> Function()? _initializeSecondaryData;
  final Future<void> Function()? _initializeListeningHistory;
  final void Function()? _disposeSecondaryData;
  Future<void>? _secondaryInitialization;
  Future<void>? _listeningInitialization;
  bool _secondaryInitialized = false;
  bool _historyInitialized = false;
  bool _closing = false;
  late final AudioRuntimeCoordinator _runtime;
  bool _bindingsDisposed = false;
  Future<void>? _disposeFuture;
  final Future<void> Function()? _disposeWorkTexts;

  @override
  Future<void> start() => _closing
      ? Future<void>.error(StateError('App runtime is closing'))
      : _runtime.start();

  @override
  Future<void> initializeSecondaryData() {
    if (_closing || _secondaryInitialized) return Future<void>.value();
    final active = _secondaryInitialization;
    if (active != null) return active;
    late final Future<void> attempt;
    attempt = _initializeSecondary().whenComplete(() {
      if (identical(_secondaryInitialization, attempt)) {
        _secondaryInitialization = null;
      }
    });
    return _secondaryInitialization = attempt;
  }

  Future<void> _initializeSecondary() async {
    await start();
    if (_closing || !_persistence.hasLoadedState) return;
    await AppLogService.measureAsync('app_secondary_initialization', () async {
      // A failed download restore must not prevent history or account loading.
      await Future.wait<void>([
        if (_asmrDownloads != null) _asmrDownloads.initialize(),
        if (_initializeSecondaryData != null) _initializeSecondaryData(),
        _initializeListening(),
      ]);
    });
    if (!_closing) _secondaryInitialized = true;
  }

  Future<void> _initializeListening() =>
      _listeningInitialization ??= _initializeListeningOnce().whenComplete(
        () => _listeningInitialization = null,
      );

  Future<void> _initializeListeningOnce() async {
    try {
      if (!_historyInitialized) {
        await _initializeListeningHistory?.call();
        _historyInitialized = true;
      }
    } finally {
      // A failed legacy migration must not disable durable usage imports.
      if (!_closing) await _listeningActivity?.start();
    }
  }

  @override
  Future<void> enterBackground() {
    if (_closing) return Future<void>.value();
    _library.setBackgroundMode(true);
    return _runtime.enterBackground();
  }

  @override
  Future<void> resumeForeground() {
    if (_closing) return Future<void>.value();
    _library.setBackgroundMode(false);
    return _runtime.resumeForeground();
  }

  @override
  Future<void> handleMemoryPressure() => _runtime.handleMemoryPressure();

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _closing = true;
    _persistence.invalidatePendingLoad();
    try {
      await _asmrDownloads?.shutdown();
    } finally {
      await _runtime.dispose();
    }
  }

  void _handleMemoryPressure() {
    trimCoverImageCacheOnMemoryPressure();
    _library.trimMemory();
    AppCacheService.scheduleEnforce();
  }

  Future<void> _enterBackground() async {
    _playback.setBackgroundMode(true);
    _keepAlive.enterBackground();
    await _playback.flushSessionStatePersistence();
    _refreshListeningActivity();
  }

  Future<void> _resumeForeground() async {
    _playback.setBackgroundMode(false);
    _keepAlive.resumeForeground();
    await _playbackCommands.reconcileNativeRuntime();
    _notifications.resyncAfterForegroundResume();
    await _timer.syncRuntimeFromNative();
    _timer.retryOverdueAutoResume();
    _refreshListeningActivity();
  }

  void _refreshListeningActivity() {
    if (_closing) return;
    final refresh = _historyInitialized
        ? _listeningActivity?.refresh()
        : _initializeListening();
    unawaited(
      refresh?.catchError((Object error, StackTrace stack) {
        AppLogService.error(
          'listening_activity_import_failed',
          error: error,
          stackTrace: stack,
        );
      }),
    );
  }

  Future<void> _disposeRuntime() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    for (final pending in [
      _secondaryInitialization,
      _listeningInitialization,
    ]) {
      if (pending == null) continue;
      try {
        await pending;
      } catch (_) {
        // The initializer reports its failure. Drain it before closing owners.
      }
    }

    if (_persistence.hasLoadedState) {
      await attempt(_playback.flushSessionStatePersistence);
      if (_historyInitialized) {
        await attempt(() => _listeningActivity?.refresh());
      }
    }
    await attempt(() => _listeningActivity?.dispose());
    if (_disposeWorkTexts != null) await attempt(_disposeWorkTexts);
    await attempt(_persistence.dispose);
    await attempt(_playback.cancelScheduledPersistence);
    await attempt(_library.cancelPendingScanProgressNotification);
    await attempt(_warmup.shutdown);
    await attempt(_keepAlive.shutdown);
    if (!_bindingsDisposed) {
      _bindingsDisposed = true;
      for (final binding in _bindings.reversed) {
        await attempt(binding.dispose);
      }
    }
    await attempt(() => _asmrDownloads?.shutdown());
    if (_disposeSecondaryData != null) await attempt(_disposeSecondaryData);
    await attempt(_library.dispose);
    await attempt(_playback.dispose);
    await attempt(_playbackCommands.dispose);
    await attempt(_timer.dispose);
    await attempt(_notifications.dispose);
    await attempt(_settings.dispose);
    await attempt(AppNetwork.instance.close);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}
