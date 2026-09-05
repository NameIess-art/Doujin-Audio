import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/settings/application/settings_repository.dart';
import 'playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';
import 'runtime_binding.dart';

final class NotificationRuntimeBinding implements RuntimeBinding {
  NotificationRuntimeBinding._(this._notifications);

  static final Expando<NotificationRuntimeBinding> _attached =
      Expando<NotificationRuntimeBinding>();

  static NotificationRuntimeBinding attach({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    required SettingsRepository settings,
    required PlaybackCommandCoordinator playbackCommands,
    required PlaybackKeepAliveCoordinator keepAlive,
    required PlaybackSubtitleService subtitles,
    required void Function() syncPlaybackState,
  }) {
    final existing = _attached[notifications];
    if (existing != null && !existing._disposed) return existing;
    notifications.attachRuntime(
      undismissNotifications: playback.nativeRepository.undismissNotifications,
      onNotificationsRestored: () {
        notifications.syncPlaybackState(immediateUnifiedSync: true);
        syncPlaybackState();
      },
    );
    notifications.attachActions(
      playback: playback,
      resolveSession: notifications.resolveNotificationSession,
      resolveActionSession: () => notifications.notificationActionSession,
      resumeSession: (session) => playbackCommands.startSession(
        session,
        shouldStartTriggerCountdown: false,
      ),
      multiThreadPlaybackEnabled: () => settings.multiThreadPlaybackEnabled,
      setFocusSessionId: notifications.setFocusedSession,
      notify: syncPlaybackState,
      syncKeepAlive: keepAlive.sync,
      hasPlaybackToKeepAlive: () => keepAlive.hasPlaybackToKeepAlive,
      clearUnifiedNotifications:
          notifications.clearUnifiedNotificationsOnPlatform,
      preferredSessionId: () => playbackCommands.preferredSingleSessionId,
      notifyNotificationChanged: syncPlaybackState,
    );
    notifications.attachSynchronization(
      playbackCommands: playbackCommands,
      subtitles: subtitles,
      trackByPath: playbackCommands.trackByPath,
      coverArtworkCacheService: library.coverArtworkCacheService,
      notificationsEnabled: () => settings.notificationsEnabled,
    );
    final binding = NotificationRuntimeBinding._(notifications);
    _attached[notifications] = binding;
    return binding;
  }

  final NotificationFacade _notifications;
  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _notifications.detachRuntime();
    _attached[_notifications] = null;
  }
}
