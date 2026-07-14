import 'audio_state_services.dart';
import 'playback_notification_service.dart';

/// Owns notification synchronization state and the notification gateway.
final class NotificationFacade {
  NotificationFacade({required this.service, required this.stateService});

  factory NotificationFacade.create({
    required PlaybackNotificationService service,
    NotificationCoordinatorService? stateService,
  }) {
    return NotificationFacade(
      service: service,
      stateService: stateService ?? NotificationCoordinatorService(),
    );
  }

  final PlaybackNotificationService service;
  final NotificationCoordinatorService stateService;

  NotificationState get state => stateService.slice.state;
  Stream<NotificationState> get states => stateService.slice.stream;

  Future<void> dispose() => stateService.dispose();
}
