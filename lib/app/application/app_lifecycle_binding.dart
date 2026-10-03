import 'dart:async';

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
       _bindings = List<RuntimeBinding>.unmodifiable(bindings) {
    _runtime = AudioRuntimeCoordinator(
      snapshots: playback.nativeRepository.snapshots,
      progressUpdates: playback.nativeRepository.progressUpdates,
      startListening: playback.nativeRepository.startListening,
      stopListening: playback.nativeRepository.stopListening,
      onSnapshot: playbackCommands.handleNativeSnapshot,
      onProgress: playback.applyNativeProgress,
      onStart: persistence.loadPersistedState,
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
  late final AudioRuntimeCoordinator _runtime;
  bool _bindingsDisposed = false;
  Future<void>? _disposeFuture;
  final Future<void> Function()? _disposeWorkTexts;

  @override
  Future<void> start() => _runtime.start();

  @override
  Future<void> enterBackground() => _runtime.enterBackground();

  @override
  Future<void> resumeForeground() => _runtime.resumeForeground();

  @override
  Future<void> handleMemoryPressure() => _runtime.handleMemoryPressure();

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    try {
      await _asmrDownloads?.pauseAllTasks();
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
  }

  Future<void> _resumeForeground() async {
    _playback.setBackgroundMode(false);
    _keepAlive.resumeForeground();
    await _playbackCommands.reconcileNativeRuntime();
    _notifications.resyncAfterForegroundResume();
    await _timer.syncRuntimeFromNative();
    _timer.retryOverdueAutoResume();
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

    await attempt(_playback.flushSessionStatePersistence);
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
    await attempt(_library.dispose);
    await attempt(_playback.dispose);
    await attempt(_playbackCommands.dispose);
    await attempt(_timer.dispose);
    await attempt(_notifications.dispose);
    await attempt(_settings.dispose);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}
