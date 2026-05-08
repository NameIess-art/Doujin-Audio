import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../services/platform_channels.dart';

class KeepAliveDelegate {
  KeepAliveDelegate();

  static const MethodChannel _powerChannel = MethodChannel(PowerChannel.name);

  bool _keepCpuAwake = false;
  bool _hasPlayback = false;
  bool _hasTimer = false;
  bool _usesUnifiedNotifications = false;
  bool _keepsForegroundService = false;

  bool get isActive => _keepCpuAwake;

  void sync({
    required bool hasActivePlayback,
    required bool hasActiveTimer,
    required bool usesUnifiedPlaybackNotifications,
    required bool keepForegroundServiceAlive,
  }) {
    if (_keepCpuAwake == keepForegroundServiceAlive &&
        _hasPlayback == hasActivePlayback &&
        _hasTimer == hasActiveTimer &&
        _usesUnifiedNotifications == usesUnifiedPlaybackNotifications &&
        _keepsForegroundService == keepForegroundServiceAlive) {
      return;
    }
    _keepCpuAwake = keepForegroundServiceAlive;
    _hasPlayback = hasActivePlayback;
    _hasTimer = hasActiveTimer;
    _usesUnifiedNotifications = usesUnifiedPlaybackNotifications;
    _keepsForegroundService = keepForegroundServiceAlive;
    unawaited(_sendToPlatform());
  }

  void syncImmediate({
    required bool hasActivePlayback,
    required bool hasActiveTimer,
    required bool usesUnifiedPlaybackNotifications,
    required bool keepForegroundServiceAlive,
  }) {
    _keepCpuAwake = keepForegroundServiceAlive;
    _hasPlayback = hasActivePlayback;
    _hasTimer = hasActiveTimer;
    _usesUnifiedNotifications = usesUnifiedPlaybackNotifications;
    _keepsForegroundService = keepForegroundServiceAlive;
    unawaited(_sendToPlatform());
  }

  Future<void> _sendToPlatform() async {
    try {
      await _powerChannel.invokeMethod<void>(PowerMethod.setKeepCpuAwake, {
        'enabled': _keepCpuAwake,
        'hasActivePlayback': _hasPlayback,
        'hasActiveTimer': _hasTimer,
        'usesUnifiedPlaybackNotifications': _usesUnifiedNotifications,
        'keepForegroundServiceAlive': _keepsForegroundService,
      });
    } on MissingPluginException {
      // Non-Android platforms don't expose this channel.
    } catch (e) {
      debugPrint('KeepAliveDelegate: _setKeepCpuAwake error: $e');
    }
  }

  Future<void> deactivateAll() async {
    _keepCpuAwake = false;
    _hasPlayback = false;
    _hasTimer = false;
    _usesUnifiedNotifications = false;
    _keepsForegroundService = false;
    await _sendToPlatform();
    await _deactivateAudioSession();
  }

  Future<bool> activateAudioSession() async {
    try {
      final audioSession = await AudioSession.instance;
      return await audioSession.setActive(true);
    } catch (e) {
      debugPrint('KeepAliveDelegate: activateAudioSession error: $e');
      return true;
    }
  }

  Future<void> deactivateAudioSession() async {
    try {
      final audioSession = await AudioSession.instance;
      await audioSession.setActive(false);
    } catch (e) {
      debugPrint('KeepAliveDelegate: deactivateAudioSession error: $e');
    }
  }

  Future<void> _deactivateAudioSession() => deactivateAudioSession();
}
