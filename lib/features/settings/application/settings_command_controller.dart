import 'package:flutter/painting.dart';

import '../../library/application/cover_image_cache_policy.dart';
import '../../library/application/library_facade.dart';
import '../../player/application/playback_facade.dart';
import '../../player/domain/audio_effects.dart';
import 'settings_repository.dart';
import 'settings_state.dart';
import '../../../core/cache/app_cache_service.dart';

/// Applies settings whose changes require cross-service coordination.
final class SettingsCommandController {
  const SettingsCommandController({
    required SettingsRepository settings,
    required PlaybackFacade playback,
    LibraryFacade? library,
    Future<int> Function()? clearApplicationCacheFiles,
  }) : _settings = settings,
       _playback = playback,
       _library = library,
       _clearApplicationCacheFiles =
           clearApplicationCacheFiles ?? AppCacheService.clearAllCaches;

  final SettingsRepository _settings;
  final PlaybackFacade _playback;
  final LibraryFacade? _library;
  final Future<int> Function() _clearApplicationCacheFiles;

  SettingsRepository get settings => _settings;

  Future<void> togglePlaylistSessionsPinned(Iterable<String> sessionIds) =>
      _settings.togglePlaylistSessionsPinned(sessionIds);

  Future<void> setCoverImageResolution(CoverImageResolution resolution) =>
      _settings.setCoverImageResolution(
        resolution,
        afterSave: () async =>
            applyCoverImageCachePolicy(resolution, clear: true),
      );

  Future<void> setPreferEmbeddedCover(bool enabled) =>
      _settings.setPreferEmbeddedCover(
        enabled,
        afterSave: () async => _library?.invalidateCoverArtwork(),
      );

  Future<void> setMaxCacheBytes(int bytes) async {
    final normalized = bytes <= 0
        ? AppCacheService.defaultMaxCacheBytes
        : bytes;
    await _settings.setMaxCacheBytes(
      normalized,
      afterSave: () => AppCacheService.setMaxCacheBytes(normalized),
    );
  }

  Future<int> clearApplicationCache() async {
    final deletedBytes = await _clearApplicationCacheFiles();
    await _library?.coverArtworkCacheService.clearPersistentCache();
    applyCoverImageCachePolicy(_settings.coverImageResolution, clear: true);
    PaintingBinding.instance.imageCache.clearLiveImages();
    _library?.invalidateCoverArtwork();
    return deletedBytes;
  }

  Future<void> setAudioDeviceDisconnectBehavior(
    AudioDeviceDisconnectBehavior behavior,
  ) => _settings.setAudioDeviceDisconnectBehavior(
    behavior,
    afterSave: syncNativePlaybackBehavior,
  );

  Future<void> setAudioFocusStrategy(AudioFocusStrategy strategy) => _settings
      .setAudioFocusStrategy(strategy, afterSave: syncNativePlaybackBehavior);

  Future<void> setTransientAudioFocusLossBehavior(
    TransientAudioFocusLossBehavior behavior,
  ) => _settings.setTransientAudioFocusLossBehavior(
    behavior,
    afterSave: syncNativePlaybackBehavior,
  );

  Future<void> setInterruptionResumeBehavior(
    InterruptionResumeBehavior behavior,
  ) => _settings.setInterruptionResumeBehavior(
    behavior,
    afterSave: syncNativePlaybackBehavior,
  );

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
    await _settings.saveCustomEqPreset(
      EqPreset(
        id: 'custom_${timestamp.microsecondsSinceEpoch}',
        labelKey: trimmedName,
        bandLevels: Map<int, double>.unmodifiable(
          session.audioEffects.eqBandLevels,
        ),
      ),
    );
  }

  Future<void> deleteCustomEqPreset(String presetId) =>
      _settings.deleteCustomEqPreset(
        presetId,
        resetSessions: () async {
          final referencingSessionIds = _playback.sessions.values
              .where((session) => session.audioEffects.eqPresetId == presetId)
              .map((session) => session.id)
              .toList(growable: false);
          for (final sessionId in referencingSessionIds) {
            await _playback.applySessionEqPreset(
              sessionId,
              builtInEqPresets.first,
            );
          }
          return !_playback.sessions.values.any(
            (session) => session.audioEffects.eqPresetId == presetId,
          );
        },
      );
}
