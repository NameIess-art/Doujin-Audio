import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_playback_bridge.dart';
import 'playback_notification_handler.dart';
import 'platform_channels.dart';

class PlaybackNotificationService {
  static const MethodChannel _notificationsChannel = MethodChannel(
    NotificationsChannel.name,
  );

  final PlaybackNotificationHandler _handler;
  bool _enabled = true;

  PlaybackNotificationService(this._handler);

  PlaybackNotificationHandler get handler => _handler;
  bool get enabled => _enabled;

  void bindCallbacks({
    Future<void> Function()? onPlay,
    Future<void> Function(String mediaId)? onPlayFromMediaId,
    Future<void> Function()? onPause,
    Future<void> Function()? onStop,
    Future<void> Function()? onSkipToNext,
    Future<void> Function()? onSkipToPrevious,
    Future<void> Function(int index)? onSkipToQueueItem,
    Future<void> Function(Duration position)? onSeek,
    Future<void> Function()? onTogglePlayPause,
    Future<void> Function(String sessionId)? onToggleSessionPlayback,
    Future<void> Function(String sessionId)? onSkipToPreviousSession,
    Future<void> Function(String sessionId)? onSkipToNextSession,
    Future<void> Function()? onNotificationDeleted,
    Future<void> Function()? onRestoreNotifications,
  }) {
    _handler.bindCallbacks(
      onPlay: onPlay,
      onPlayFromMediaId: onPlayFromMediaId,
      onPause: onPause,
      onStop: onStop,
      onSkipToNext: onSkipToNext,
      onSkipToPrevious: onSkipToPrevious,
      onSkipToQueueItem: onSkipToQueueItem,
      onSeek: onSeek,
      onTogglePlayPause: onTogglePlayPause,
      onToggleSessionPlayback: onToggleSessionPlayback,
      onSkipToPreviousSession: onSkipToPreviousSession,
      onSkipToNextSession: onSkipToNextSession,
      onNotificationDeleted: onNotificationDeleted,
      onRestoreNotifications: onRestoreNotifications,
    );
  }

  void updateSnapshot(PlaybackNotificationSnapshot? snapshot) {
    if (!_enabled) return;
    _handler.updateSnapshot(snapshot);
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    if (!enabled) {
      _handler.playbackState.add(PlaybackState(queueIndex: 0));
      _handler.mediaItem.add(null);
      _handler.queue.add(const []);
      await AudioService.stopService();
      await _clearUnifiedNotifications();
    }
    _enabled = enabled;
    if (enabled) {
      await NativePlaybackBridge.instance.setForegroundEnabled(true);
    }
  }

  Future<void> clearUnifiedNotifications() async {
    await _clearUnifiedNotifications();
  }

  Future<void> syncUnifiedNotifications(Map<String, dynamic> payload) async {
    if (!_enabled) return;
    try {
      await _notificationsChannel
          .invokeMethod<void>(
            NotificationsMethod.syncUnifiedPlaybackNotifications,
            payload,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => debugPrint(
              'PlaybackNotificationService.syncUnifiedNotifications timed out',
            ),
          );
    } on MissingPluginException {
      // Channel not available on this platform.
    } catch (e) {
      debugPrint(
        'PlaybackNotificationService.syncUnifiedNotifications error: $e',
      );
    }
  }

  Future<void> _clearUnifiedNotifications() async {
    try {
      await _notificationsChannel
          .invokeMethod<void>(
            NotificationsMethod.clearUnifiedPlaybackNotifications,
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => debugPrint(
              'PlaybackNotificationService._clearUnifiedNotifications timed out',
            ),
          );
    } on MissingPluginException {
      // Channel not available on this platform.
    } catch (e) {
      debugPrint(
        'PlaybackNotificationService._clearUnifiedNotifications error: $e',
      );
    }
  }
}
