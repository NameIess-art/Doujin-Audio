import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/settings/application/settings_repository.dart';
import 'app_persistence_coordinator.dart';
import 'app_runtime_lifecycle.dart';
import 'audio_runtime_coordinator.dart';
import 'audio_ui_warmup_coordinator.dart';
import 'playback_command_coordinator.dart';
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

  @override
  Future<void> start() => _runtime.start();

  @override
  Future<void> enterBackground() => _runtime.enterBackground();

  @override
  Future<void> resumeForeground() => _runtime.resumeForeground();

  @override
  Future<void> dispose() => _runtime.dispose();

  Future<void> _enterBackground() async {
    await _asmrDownloads?.pauseAllTasks();
    _playback.setBackgroundMode(true);
    _keepAlive.enterBackground();
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
    await _asmrDownloads?.pauseAllTasks();
    _persistence.dispose();
    _playback.cancelScheduledPersistence();
    _library.cancelPendingScanProgressNotification();
    await _warmup.shutdown();
    await _keepAlive.shutdown();
    if (!_bindingsDisposed) {
      _bindingsDisposed = true;
      for (final binding in _bindings.reversed) {
        await binding.dispose();
      }
    }
    _asmrDownloads?.dispose();
    await _library.dispose();
    await _playback.dispose();
    await _timer.dispose();
    await _notifications.dispose();
    await _settings.dispose();
  }
}
