import '../../library/application/cover_image_cache_policy.dart';
import '../../library/application/library_facade.dart';
import '../../player/application/notification_facade.dart';
import '../../player/application/playback_facade.dart';
import '../../player/domain/audio_effects.dart';
import 'settings_repository.dart';
import 'settings_state.dart';
import 'app_cache_service.dart';

/// Applies settings whose changes require cross-service coordination.
final class SettingsCommandController {
  const SettingsCommandController({
    required SettingsRepository settings,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    LibraryFacade? library,
  }) : _settings = settings,
       _playback = playback,
       _notifications = notifications,
       _library = library;

  final SettingsRepository _settings;
  final PlaybackFacade _playback;
  final NotificationFacade _notifications;
  final LibraryFacade? _library;

  SettingsRepository get settings => _settings;

  Future<bool> setMultiThreadPlaybackEnabled(bool enabled) async {
    if (_settings.multiThreadPlaybackEnabled == enabled) return true;
    if (!enabled && !await _playback.pauseAllSessions()) return false;
    await _settings.setMultiThreadPlaybackEnabled(enabled);
    await _notifications.handlePlaybackModeChanged();
    return true;
  }

  Future<void> setCoverImageResolution(CoverImageResolution resolution) async {
    if (_settings.coverImageResolution == resolution) return;
    applyCoverImageCachePolicy(resolution, clear: true);
    await _settings.setCoverImageResolution(resolution);
  }

  Future<void> setPreferEmbeddedAudioCover(bool enabled) async {
    if (_settings.preferEmbeddedAudioCover == enabled) return;
    await _settings.setPreferEmbeddedAudioCover(enabled);
    _library?.invalidateCoverArtwork();
  }

  Future<void> setMaxCacheBytes(int bytes) async {
    final normalized = bytes <= 0
        ? AppCacheService.defaultMaxCacheBytes
        : bytes;
    if (_settings.maxCacheBytes == normalized) return;
    await AppCacheService.setMaxCacheBytes(normalized);
    await _settings.setMaxCacheBytes(normalized);
  }

  Future<void> setAudioDeviceDisconnectBehavior(
    AudioDeviceDisconnectBehavior behavior,
  ) async {
    if (_settings.audioDeviceDisconnectBehavior == behavior) return;
    await _settings.setAudioDeviceDisconnectBehavior(behavior);
    await syncNativePlaybackBehavior();
  }

  Future<void> setAudioFocusStrategy(AudioFocusStrategy strategy) async {
    if (_settings.audioFocusStrategy == strategy) return;
    await _settings.setAudioFocusStrategy(strategy);
    await syncNativePlaybackBehavior();
  }

  Future<void> setTransientAudioFocusLossBehavior(
    TransientAudioFocusLossBehavior behavior,
  ) async {
    if (_settings.transientAudioFocusLossBehavior == behavior) return;
    await _settings.setTransientAudioFocusLossBehavior(behavior);
    await syncNativePlaybackBehavior();
  }

  Future<void> setInterruptionResumeBehavior(
    InterruptionResumeBehavior behavior,
  ) async {
    if (_settings.interruptionResumeBehavior == behavior) return;
    await _settings.setInterruptionResumeBehavior(behavior);
    await syncNativePlaybackBehavior();
  }

  Future<void> setStartupPlaybackRestoreBehavior(
    StartupPlaybackRestoreBehavior behavior,
  ) async {
    if (_settings.startupPlaybackRestoreBehavior == behavior) return;
    await _settings.setStartupPlaybackRestoreBehavior(behavior);
    await syncNativePlaybackBehavior();
  }

  Future<void> syncNativePlaybackBehavior() async {
    await _playback.nativeRepository.setPlaybackBehavior(
      pauseOnAudioDeviceDisconnect:
          _settings.audioDeviceDisconnectBehavior ==
          AudioDeviceDisconnectBehavior.pause,
      requestAudioFocus:
          _settings.audioFocusStrategy == AudioFocusStrategy.standard,
      pauseOnTransientAudioFocusLoss:
          _settings.transientAudioFocusLossBehavior ==
          TransientAudioFocusLossBehavior.pause,
      resumeAfterTransientAudioFocusGain:
          _settings.interruptionResumeBehavior ==
          InterruptionResumeBehavior.resume,
      resumePlaybackOnStartupRestore:
          _settings.startupPlaybackRestoreBehavior ==
          StartupPlaybackRestoreBehavior.resume,
    );
  }

  Future<void> saveCustomEqPreset(
    String name,
    String sessionId, {
    DateTime? now,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;
    final session = _playback.sessionSnapshotById(sessionId);
    if (session == null) return;
    final timestamp = now ?? DateTime.now();
    _settings.customEqPresets = List<EqPreset>.unmodifiable(<EqPreset>[
      ..._settings.customEqPresets,
      EqPreset(
        id: 'custom_${timestamp.microsecondsSinceEpoch}',
        labelKey: trimmedName,
        bandLevels: Map<int, double>.unmodifiable(
          session.audioEffects.eqBandLevels,
        ),
      ),
    ]);
    _settings.syncSlice(isInitialized: _settings.slice.state.isInitialized);
    await _settings.persist();
  }
}
