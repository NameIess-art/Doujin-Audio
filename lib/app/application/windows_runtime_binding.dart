import '../../core/platform/windows_desktop_service.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import 'app_runtime_lifecycle.dart';

/// Routes shell commands to the same owners used by the Flutter controls.
Future<void> attachWindowsRuntime({
  required AppRuntimeLifecycle runtime,
  required PlaybackFacade playback,
  required NotificationFacade notifications,
  required TimerFacade timer,
}) async {
  Future<void>? shutdown;
  var endingSession = false;
  var pausedByTaskbar = <String>{};
  Future<void> saveAndDispose({required bool closeWindow}) async {
    await playback.savePersistedState();
    await timer.saveRuntime();
    await runtime.dispose();
    // Windows needs the channel reply before WM_ENDSESSION returns.
    if (closeWindow && !endingSession) {
      await WindowsDesktopService.instance.exit();
    }
  }

  await WindowsDesktopService.instance.attach((action) async {
    if (action == 'endSession') endingSession = true;
    if (shutdown != null && action != 'exit' && action != 'endSession') return;
    switch (action) {
      case 'exit':
      case 'endSession':
        final pending = shutdown ??= saveAndDispose(
          closeWindow: action == 'exit',
        );
        try {
          await pending;
        } catch (_) {
          if (identical(shutdown, pending)) shutdown = null;
          rethrow;
        }
      case 'play':
        await notifications.playPrimarySession();
      case 'pause':
        await notifications.pausePrimarySession();
      case 'toggle':
        await notifications.togglePrimarySessionPlayPause();
      case 'taskbarToggle':
        final playing = playback.sessions.values
            .where((session) => session.playbackRequested)
            .map((session) => session.id)
            .toSet();
        if (playing.isNotEmpty) {
          if (await playback.pauseAllSessions()) pausedByTaskbar = playing;
        } else if (pausedByTaskbar.isNotEmpty) {
          final resumeIds = pausedByTaskbar;
          pausedByTaskbar = <String>{};
          for (final id in resumeIds) {
            final session = playback.sessionById(id);
            if (session != null && !session.playbackRequested) {
              await playback.toggleSessionPlayPause(id);
            }
          }
        } else {
          await notifications.playPrimarySession();
        }
      case 'next':
        await notifications.skipPrimarySessionToNext();
      case 'previous':
        await notifications.skipPrimarySessionToPrevious();
      case 'resume':
        await runtime.resumeForeground();
      case 'background':
        await runtime.enterBackground();
      case 'deviceDisconnected':
        await playback.nativeRepository.handleDeviceDisconnected();
    }
  });
}
