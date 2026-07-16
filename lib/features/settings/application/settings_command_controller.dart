import '../../library/application/cover_image_cache_policy.dart';
import '../../player/application/notification_facade.dart';
import '../../player/application/playback_facade.dart';
import '../../player/application/playback_session.dart';
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
  }) : _settings = settings,
       _playback = playback,
       _notifications = notifications;

  final SettingsRepository _settings;
  final PlaybackFacade _playback;
  final NotificationFacade _notifications;

  SettingsRepository get settings => _settings;

  Future<void> setMultiThreadPlaybackEnabled(bool enabled) async {
    if (_settings.multiThreadPlaybackEnabled == enabled) return;
    await _settings.setMultiThreadPlaybackEnabled(enabled);
    if (!enabled) {
      await _playback.pauseAllSessions();
    }
    await _notifications.handlePlaybackModeChanged();
  }

  Future<void> setCoverImageResolution(CoverImageResolution resolution) async {
    if (_settings.coverImageResolution == resolution) return;
    applyCoverImageCachePolicy(resolution, clear: true);
    await _settings.setCoverImageResolution(resolution);
  }

  Future<void> setMaxCacheBytes(int bytes) async {
    final normalized = bytes <= 0
        ? AppCacheService.defaultMaxCacheBytes
        : bytes;
    if (_settings.maxCacheBytes == normalized) return;
    await AppCacheService.setMaxCacheBytes(normalized);
    await _settings.setMaxCacheBytes(normalized);
  }

  Future<void> saveCustomEqPreset(
    String name,
    PlaybackSession session, {
    DateTime? now,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;
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
