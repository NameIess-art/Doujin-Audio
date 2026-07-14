import '../../../core/platform/power_platform_service.dart';
import 'audio_state_services.dart';

/// Owns timer state and timer-related platform power coordination.
final class TimerFacade {
  TimerFacade({required this.service, required this.powerPlatformService});

  factory TimerFacade.create({
    TimerService? service,
    PowerPlatformService? powerPlatformService,
  }) {
    return TimerFacade(
      service: service ?? TimerService(),
      powerPlatformService: powerPlatformService ?? PowerPlatformService(),
    );
  }

  final TimerService service;
  final PowerPlatformService powerPlatformService;

  TimerStateSliceData get state => service.slice.state;
  Stream<TimerStateSliceData> get states => service.slice.stream;

  bool keepAliveHasPlayback = false;
  bool keepAliveHasTimer = false;
  bool keepAliveUsesUnifiedNotifications = false;
  bool keepAliveKeepsForegroundService = false;

  Future<void> dispose() => service.dispose();
}
