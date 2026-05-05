import 'dart:async';

import 'package:audio_service/audio_service.dart';

class PlaybackNotificationSnapshot {
  const PlaybackNotificationSnapshot({
    required this.queue,
    required this.queueIndex,
    required this.mediaItem,
    required this.playing,
    required this.processingState,
    required this.updatePosition,
    required this.bufferedPosition,
    required this.speed,
    required this.hasPrevious,
    required this.hasNext,
    this.showTransportControls = true,
  });

  final List<MediaItem> queue;
  final int queueIndex;
  final MediaItem mediaItem;
  final bool playing;
  final AudioProcessingState processingState;
  final Duration updatePosition;
  final Duration bufferedPosition;
  final double speed;
  final bool hasPrevious;
  final bool hasNext;
  final bool showTransportControls;
}

class PlaybackNotificationHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  static const String toggleSessionPlaybackAction = 'toggle_session_playback';
  static const String sessionSkipPreviousAction = 'session_skip_previous';
  static const String sessionSkipNextAction = 'session_skip_next';
  static const String dismissAllNotificationsAction =
      'dismiss_all_playback_notifications';
  static const String restorePlaybackNotificationsAction =
      'restore_playback_notifications';
  static const String sessionIdExtrasKey = 'sessionId';

  Future<void> Function()? _onPlay;
  Future<void> Function(String mediaId)? _onPlayFromMediaId;
  Future<void> Function()? _onPause;
  Future<void> Function()? _onStop;
  Future<void> Function()? _onSkipToNext;
  Future<void> Function()? _onSkipToPrevious;
  Future<void> Function(int index)? _onSkipToQueueItem;
  Future<void> Function(Duration position)? _onSeek;
  Future<void> Function()? _onTogglePlayPause;
  Future<void> Function(String sessionId)? _onToggleSessionPlayback;
  Future<void> Function(String sessionId)? _onSkipToPreviousSession;
  Future<void> Function(String sessionId)? _onSkipToNextSession;
  Future<void> Function()? _onNotificationDeleted;
  Future<void> Function()? _onRestoreNotifications;

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
    _onPlay = onPlay;
    _onPlayFromMediaId = onPlayFromMediaId;
    _onPause = onPause;
    _onStop = onStop;
    _onSkipToNext = onSkipToNext;
    _onSkipToPrevious = onSkipToPrevious;
    _onSkipToQueueItem = onSkipToQueueItem;
    _onSeek = onSeek;
    _onTogglePlayPause = onTogglePlayPause;
    _onToggleSessionPlayback = onToggleSessionPlayback;
    _onSkipToPreviousSession = onSkipToPreviousSession;
    _onSkipToNextSession = onSkipToNextSession;
    _onNotificationDeleted = onNotificationDeleted;
    _onRestoreNotifications = onRestoreNotifications;
  }

  void updateSnapshot(PlaybackNotificationSnapshot? snapshot) {
    if (snapshot == null) {
      queue.add(const <MediaItem>[]);
      mediaItem.add(null);
      playbackState.add(
        PlaybackState(
          controls: [MediaControl.play],
          systemActions: {MediaAction.play, MediaAction.pause},
          queueIndex: 0,
        ),
      );
      return;
    }

    final controls = snapshot.showTransportControls
        ? <MediaControl>[
            if (snapshot.hasPrevious) MediaControl.skipToPrevious,
            MediaControl(
              androidIcon: snapshot.playing
                  ? 'drawable/audio_service_pause'
                  : 'drawable/audio_service_play_arrow',
              label: snapshot.playing ? 'Pause' : 'Play',
              action: MediaAction.playPause,
            ),
            if (snapshot.hasNext) MediaControl.skipToNext,
          ]
        : const <MediaControl>[];
    final compactActionIndices = snapshot.showTransportControls
        ? <int>[
            if (snapshot.hasPrevious) 0,
            snapshot.hasPrevious ? 1 : 0,
            if (snapshot.hasNext) snapshot.hasPrevious ? 2 : 1,
          ]
        : const <int>[];

    queue.add(snapshot.queue);
    mediaItem.add(snapshot.mediaItem);
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: snapshot.showTransportControls
            ? const {
                MediaAction.play,
                MediaAction.pause,
                MediaAction.playPause,
                MediaAction.seek,
                MediaAction.seekForward,
                MediaAction.seekBackward,
                MediaAction.skipToNext,
                MediaAction.skipToPrevious,
              }
            : const <MediaAction>{},
        androidCompactActionIndices: compactActionIndices,
        processingState: snapshot.processingState,
        playing: snapshot.playing,
        updatePosition: snapshot.updatePosition,
        bufferedPosition: snapshot.bufferedPosition,
        speed: snapshot.speed,
        queueIndex: snapshot.queueIndex,
      ),
    );
  }

  @override
  Future<void> play() async {
    await _onPlay?.call();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    await _onPlayFromMediaId?.call(mediaId);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    await _onPlayFromMediaId?.call(mediaItem.id);
  }

  @override
  Future<void> pause() async {
    await _onPause?.call();
  }

  @override
  Future<void> stop() async {
    await _onStop?.call();
  }

  @override
  Future<void> skipToNext() async {
    await _onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onSkipToPrevious?.call();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _onSkipToQueueItem?.call(index);
  }

  @override
  Future<void> seek(Duration position) async {
    await _onSeek?.call(position);
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        await _onTogglePlayPause?.call();
        return;
      case MediaButton.next:
        await _onSkipToNext?.call();
        return;
      case MediaButton.previous:
        await _onSkipToPrevious?.call();
        return;
    }
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    final sessionId = extras?[sessionIdExtrasKey] as String?;
    switch (name) {
      case toggleSessionPlaybackAction:
        if (sessionId != null) {
          await _onToggleSessionPlayback?.call(sessionId);
        }
        return null;
      case sessionSkipPreviousAction:
        if (sessionId != null) {
          await _onSkipToPreviousSession?.call(sessionId);
        }
        return null;
      case sessionSkipNextAction:
        if (sessionId != null) {
          await _onSkipToNextSession?.call(sessionId);
        }
        return null;
      case dismissAllNotificationsAction:
        await _onNotificationDeleted?.call();
        return null;
      case restorePlaybackNotificationsAction:
        await _onRestoreNotifications?.call();
        return null;
      default:
        return super.customAction(name, extras);
    }
  }

  @override
  Future<void> onNotificationDeleted() async {
    await _onNotificationDeleted?.call();
  }
}
