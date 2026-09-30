part of 'playback_facade.dart';

extension PlaybackEffectsCoordinator on PlaybackFacade {
  Future<bool> setSessionVolume(
    String sessionId,
    double volume, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return false;
    }
    final nextVolume = volume.clamp(0.0, PlaybackFacade.maxSessionVolume);
    final generation = ++session.volumeCommandGeneration;
    final hasDeferredReload = _deferredVolumeReloadSessionIds.contains(
      session.id,
    );
    if ((session.volume - nextVolume).abs() < 0.001) {
      if ((session.pendingVolume != null || (persist && hasDeferredReload)) &&
          (session.loadedPath != null || session.effectivePlaying)) {
        session.pendingVolume = nextVolume;
        final response = await nativeRepository.setVolume(
          session.id,
          nextVolume,
          reloadSource: persist,
        );
        if (!isRegisteredSession(session) ||
            session.volumeCommandGeneration != generation) {
          return response.isOk;
        }
        if (response.isFailure) {
          session.pendingVolume = null;
          _logNativeCommandFailure(
            'setSessionVolume',
            response,
            sessionId: session.id,
          );
          return false;
        }
        final confirmedVolume = response.valueOrNull?.volume ?? nextVolume;
        session.pendingVolume = confirmedVolume;
        if ((session.volume - confirmedVolume).abs() >= 0.001) {
          session.volume = confirmedVolume;
          if (notify) _notifySessionStateChanged(session);
        }
      }
      if (persist) {
        _deferredVolumeReloadSessionIds.remove(session.id);
        await flushSessionStatePersistence(sessionId: session.id);
      }
      return true;
    }
    final previousVolume = session.volume;
    final previouslyDeferred = hasDeferredReload;
    session.volume = nextVolume;
    session.pendingVolume = nextVolume;
    if (persist) {
      _deferredVolumeReloadSessionIds.remove(session.id);
    } else {
      _deferredVolumeReloadSessionIds.add(session.id);
    }
    if (notify) {
      _notifySessionStateChanged(session);
    }
    if (session.loadedPath == null && !session.effectivePlaying) {
      session.pendingVolume = null;
      if (persist) await flushSessionStatePersistence(sessionId: session.id);
      return true;
    }
    final response = await nativeRepository.setVolume(
      session.id,
      nextVolume,
      reloadSource: persist,
    );
    if (!isRegisteredSession(session) ||
        session.volumeCommandGeneration != generation) {
      return response.isOk;
    }
    if (response.isFailure) {
      session.volume = previousVolume;
      session.pendingVolume = null;
      if (previouslyDeferred) {
        _deferredVolumeReloadSessionIds.add(session.id);
      } else {
        _deferredVolumeReloadSessionIds.remove(session.id);
      }
      if (notify) {
        _notifySessionStateChanged(session);
      }
      _logNativeCommandFailure(
        'setSessionVolume',
        response,
        sessionId: session.id,
      );
      return false;
    }
    final confirmedVolume = response.valueOrNull?.volume ?? nextVolume;
    session.pendingVolume = confirmedVolume;
    if ((session.volume - confirmedVolume).abs() >= 0.001) {
      session.volume = confirmedVolume;
      if (notify) _notifySessionStateChanged(session);
    }
    if (persist) await flushSessionStatePersistence(sessionId: session.id);
    return true;
  }

  Future<void> setSessionSpeed(
    String sessionId,
    double speed, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return;
    }
    final nextSpeed = nearestPlaybackSpeed(speed);
    if ((session.speed - nextSpeed).abs() < 0.001) {
      if (persist) await flushSessionStatePersistence(sessionId: session.id);
      return;
    }
    final previous = session.speed;
    final generation = ++session.speedCommandGeneration;
    session.speed = nextSpeed;
    session.pendingSpeed = nextSpeed;
    if (notify) _notifySessionSettingsChanged(session);
    if (session.loadedPath == null && !session.effectivePlaying) {
      session.pendingSpeed = null;
      if (persist) await flushSessionStatePersistence(sessionId: session.id);
      return;
    }
    final response = await nativeRepository.setSpeed(session.id, nextSpeed);
    if (!isRegisteredSession(session)) return;
    if (generation != session.speedCommandGeneration) return;
    if (response.isFailure) {
      session.pendingSpeed = null;
      session.speed = previous;
      AppLogService.warning(
        'PlaybackFacade.setSessionSpeed error: ${response.errorOrNull}',
      );
      if (notify) _notifySessionSettingsChanged(session);
      return;
    }
    final confirmedSpeed = response.valueOrNull?.speed ?? nextSpeed;
    session.pendingSpeed = confirmedSpeed;
    if ((session.speed - confirmedSpeed).abs() >= 0.001) {
      session.speed = confirmedSpeed;
      if (notify) _notifySessionSettingsChanged(session);
    }
    if (persist) await flushSessionStatePersistence(sessionId: session.id);
  }

  Future<bool> setSessionTemporarySpeed(String sessionId, double? speed) async {
    final session = _service.sessions[sessionId];
    if (session == null ||
        session.isDisposed ||
        !identical(_service.sessions[session.id], session)) {
      return false;
    }
    final normalizedSpeed = speed?.clamp(0.25, 3.0).toDouble();
    final response = await nativeRepository.setTemporarySpeed(
      session.id,
      normalizedSpeed,
    );
    if (response.isOk) return true;
    AppLogService.warning(
      'PlaybackFacade.setSessionTemporarySpeed error: '
      '${response.errorCodeOrNull} ${response.errorOrNull}',
    );
    return false;
  }

  double nearestPlaybackSpeed(double speed) {
    return PlaybackFacade.playbackSpeedOptions.reduce((best, candidate) {
      final bestDistance = (best - speed).abs();
      final candidateDistance = (candidate - speed).abs();
      return candidateDistance < bestDistance ? candidate : best;
    });
  }

  void clearDeferredVolumeReloads() {
    _deferredVolumeReloadSessionIds.clear();
  }

  Future<void> setSessionChannelSwap(String sessionId, bool enabled) {
    final session = _service.sessions[sessionId];
    if (session == null) return Future<void>.value();
    if (session.channelSwapEnabled == enabled) {
      return session.audioEffectsSyncFuture ??
          flushSessionStatePersistence(sessionId: session.id);
    }
    return _queueSessionAudioEffectsSync(
      session,
      audioEffects: session.audioEffects,
      channelSwapEnabled: enabled,
      errorLabel: 'setSessionChannelSwap',
    );
  }

  Future<void> setSessionSkipSilence(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(skipSilenceEnabled: enabled),
      errorLabel: 'setSessionSkipSilence',
    );
  }

  Future<void> setSessionNoiseReduction(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(noiseReductionEnabled: enabled),
      errorLabel: 'setSessionNoiseReduction',
    );
  }

  Future<void> setSessionVolumeNormalization(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(volumeNormalizationEnabled: enabled),
      errorLabel: 'setSessionVolumeNormalization',
    );
  }

  Future<void> setSessionPanning(String sessionId, double panning) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(panning: panning),
      errorLabel: 'setSessionPanning',
    );
  }

  Future<void> setSessionEqEnabled(String sessionId, bool enabled) {
    return _updateSessionAudioEffects(
      sessionId,
      (state) => state.copyWith(eqEnabled: enabled),
      errorLabel: 'setSessionEqEnabled',
    );
  }

  Future<void> setSessionEqBandLevel(
    String sessionId,
    int frequencyHz,
    double gainDb,
  ) {
    return _updateSessionAudioEffects(sessionId, (state) {
      final levels = Map<int, double>.of(state.eqBandLevels);
      levels[frequencyHz] = _clampEqGainForSession(sessionId, gainDb);
      return state.copyWith(
        eqEnabled: true,
        eqPresetId: null,
        eqBandLevels: levels,
      );
    }, errorLabel: 'setSessionEqBandLevel');
  }

  Future<void> applySessionEqPreset(String sessionId, EqPreset preset) {
    return _updateSessionAudioEffects(sessionId, (state) {
      final isFlatPreset = preset.bandLevels.isEmpty;
      return state.copyWith(
        eqEnabled: isFlatPreset ? state.eqEnabled : true,
        eqPresetId: preset.id,
        eqBandLevels: _mapPresetToSessionBands(sessionId, preset),
      );
    }, errorLabel: 'applySessionEqPreset');
  }

  Future<NativeResult<NativePlaybackSnapshot>> _syncSessionAudioEffects(
    PlaybackSession session,
    NativeAudioEffects audioEffects,
  ) async {
    final shouldKeepPlaying = session.effectivePlaying;
    final loadedPath = session.loadedPath;
    final needsPrepare =
        loadedPath == null ||
        !PathMatcher.equalsNormalized(loadedPath, session.currentTrackPath);
    if (needsPrepare && !shouldKeepPlaying) {
      return const NativeSuccess();
    }
    if (needsPrepare) {
      final commandPort = _commandPort;
      if (commandPort == null) {
        return const NativeFailure('Playback session preparation unavailable.');
      }
      await commandPort.prepareSession(
        session,
        nextPath: session.currentTrackPath,
        autoPlay: shouldKeepPlaying,
      );
      if (!_service.sessions.containsKey(session.id)) {
        return const NativeFailure(
          'Session removed before audio effects sync.',
        );
      }
      if (session.loadedPath == null) {
        return const NativeFailure(
          'Failed to prepare session before audio effects sync.',
        );
      }
    }
    var response = await nativeRepository.setAudioEffects(
      session.id,
      audioEffects,
    );
    if (response.isOk ||
        needsPrepare ||
        !_service.sessions.containsKey(session.id)) {
      return response;
    }

    session.loadedPath = null;
    final commandPort = _commandPort;
    if (commandPort == null) return response;
    await commandPort.prepareSession(
      session,
      nextPath: session.currentTrackPath,
      autoPlay: shouldKeepPlaying,
      showLoading: false,
    );
    if (session.loadedPath == null ||
        !_service.sessions.containsKey(session.id)) {
      return response;
    }
    response = await nativeRepository.setAudioEffects(session.id, audioEffects);
    return response;
  }

  Future<void> _updateSessionAudioEffects(
    String sessionId,
    AudioEffectsState Function(AudioEffectsState state) update, {
    required String errorLabel,
  }) {
    final session = _service.sessions[sessionId];
    if (session == null) return Future<void>.value();
    return _queueSessionAudioEffectsSync(
      session,
      audioEffects: update(session.audioEffects),
      channelSwapEnabled: session.channelSwapEnabled,
      errorLabel: errorLabel,
    );
  }

  Future<void> _queueSessionAudioEffectsSync(
    PlaybackSession session, {
    required AudioEffectsState audioEffects,
    required bool channelSwapEnabled,
    required String errorLabel,
  }) {
    if (!session.hasPendingAudioEffectsSync) {
      session.confirmedNativeAudioEffects = NativeAudioEffects(
        state: session.audioEffects,
        channelSwapEnabled: session.channelSwapEnabled,
      );
    }
    session
      ..pendingNativeAudioEffects = NativeAudioEffects(
        state: audioEffects,
        channelSwapEnabled: channelSwapEnabled,
      )
      ..audioEffects = audioEffects
      ..channelSwapEnabled = channelSwapEnabled
      ..audioEffectsSyncRevision += 1
      ..audioEffectsSyncErrorLabel = errorLabel;
    _notifySessionStateChanged(session);

    final activeDrain = session.audioEffectsSyncFuture;
    if (activeDrain != null) return activeDrain;

    final completer = Completer<void>();
    session.audioEffectsSyncFuture = completer.future;
    unawaited(() async {
      try {
        await _drainSessionAudioEffectsSync(session);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(session.audioEffectsSyncFuture, completer.future)) {
          session.audioEffectsSyncFuture = null;
        }
      }
    }());
    return completer.future;
  }

  Future<void> _drainSessionAudioEffectsSync(PlaybackSession session) async {
    while (identical(_service.sessions[session.id], session)) {
      final revision = session.audioEffectsSyncRevision;
      final desiredAudioEffects = session.pendingNativeAudioEffects;
      if (desiredAudioEffects == null) return;
      final errorLabel = session.audioEffectsSyncErrorLabel;

      final response = await _syncSessionAudioEffects(
        session,
        desiredAudioEffects,
      );
      if (!identical(_service.sessions[session.id], session)) return;

      if (response.isOk) {
        final snapshot = response.valueOrNull;
        session.confirmedNativeAudioEffects = NativeAudioEffects(
          state: _resolvedAudioEffects(
            snapshot,
            fallbackAudioEffects: desiredAudioEffects.state,
          ),
          channelSwapEnabled: snapshot?.hasChannelSwapPayload ?? false
              ? snapshot!.channelSwapEnabled
              : desiredAudioEffects.channelSwapEnabled,
        );
        if (snapshot != null) session.eqCapabilities = snapshot.eqCapabilities;
      } else {
        AppLogService.warning(
          'PlaybackFacade.$errorLabel error: '
          '${response.errorOrNull}',
        );
      }

      if (revision != session.audioEffectsSyncRevision) continue;
      final confirmed = session.confirmedNativeAudioEffects!;
      session
        ..audioEffects = confirmed.state
        ..channelSwapEnabled = confirmed.channelSwapEnabled;
      _notifySessionStateChanged(session);

      await flushSessionStatePersistence(sessionId: session.id);
      if (!identical(_service.sessions[session.id], session)) return;
      if (revision != session.audioEffectsSyncRevision) continue;
      session.pendingNativeAudioEffects = null;
      return;
    }
  }

  AudioEffectsState _resolvedAudioEffects(
    NativePlaybackSnapshot? snapshot, {
    required AudioEffectsState fallbackAudioEffects,
  }) {
    if (snapshot == null || !snapshot.hasAudioEffectsPayload) {
      return fallbackAudioEffects;
    }
    final shouldKeepFallback =
        fallbackAudioEffects != AudioEffectsState.flat &&
        snapshot.audioEffects == AudioEffectsState.flat;
    return shouldKeepFallback ? fallbackAudioEffects : snapshot.audioEffects;
  }

  Map<int, double> _mapPresetToSessionBands(String sessionId, EqPreset preset) {
    final session = _service.sessions[sessionId];
    final bands = session?.eqCapabilities.bands ?? const <EqBandInfo>[];
    if (bands.isEmpty) {
      return Map<int, double>.unmodifiable(preset.bandLevels);
    }
    final mapped = <int, double>{};
    for (final presetEntry in preset.bandLevels.entries) {
      final targetBand = bands.reduce((best, candidate) {
        final bestDistance = (best.frequencyHz - presetEntry.key).abs();
        final candidateDistance = (candidate.frequencyHz - presetEntry.key)
            .abs();
        return candidateDistance < bestDistance ? candidate : best;
      });
      mapped[targetBand.frequencyHz] = _clampEqGainForSession(
        sessionId,
        (mapped[targetBand.frequencyHz] ?? 0) + presetEntry.value,
      );
    }
    return Map<int, double>.unmodifiable(mapped);
  }

  double _clampEqGainForSession(String sessionId, double gainDb) {
    final capabilities = _service.sessions[sessionId]?.eqCapabilities;
    if (capabilities == null || !capabilities.supported) {
      return gainDb.clamp(-12.0, 12.0);
    }
    return gainDb.clamp(capabilities.minGainDb, capabilities.maxGainDb);
  }
}
