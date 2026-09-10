import '../../core/platform/windows_desktop_service.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/application/windows_playback_bridge.dart';
import 'app_runtime_lifecycle.dart';

/// Routes shell commands to the same owners used by the Flutter controls.
Future<void> attachWindowsRuntime({
  required AppRuntimeLifecycle runtime,
  required PlaybackFacade playback,
  required NotificationFacade notifications,
  required TimerFacade timer,
}) async {
  var exiting = false;
  await WindowsDesktopService.instance.attach((action) async {
    if (exiting) return;
    switch (action) {
      case 'exit':
        exiting = true;
        try {
          await playback.savePersistedState();
          await timer.saveRuntime();
          await runtime.dispose();
          await WindowsDesktopService.instance.exit();
        } catch (_) {
          exiting = false;
          rethrow;
        }
      case 'play':
        await notifications.playPrimarySession();
      case 'pause':
        await notifications.pausePrimarySession();
      case 'toggle':
        await notifications.togglePrimarySessionPlayPause();
      case 'next':
        await notifications.skipPrimarySessionToNext();
      case 'previous':
        await notifications.skipPrimarySessionToPrevious();
      case 'resume':
        await runtime.resumeForeground();
      case 'background':
        await runtime.enterBackground();
      case 'deviceDisconnected':
        await WindowsPlaybackBridge.instance.handleDeviceDisconnected();
    }
  });
}
