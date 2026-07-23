import '../../core/ui/ui_interaction_coordinator.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/presentation/library_cover_ui_controller.dart';
import '../../features/player/application/notification_facade.dart';
import '../application/audio_ui_warmup_coordinator.dart';

final class AppInteractionEffectsController {
  AppInteractionEffectsController({
    required LibraryFacade library,
    required LibraryCoverUiController libraryCovers,
    required NotificationFacade notifications,
    required AudioUiWarmupCoordinator warmup,
    UiInteractionCoordinator? interactionCoordinator,
  }) : _library = library,
       _libraryCovers = libraryCovers,
       _notifications = notifications,
       _warmup = warmup,
       _interaction =
           interactionCoordinator ?? UiInteractionCoordinator.instance {
    _interaction.addListener(_syncInteractionState);
    _syncInteractionState();
  }

  final LibraryFacade _library;
  final LibraryCoverUiController _libraryCovers;
  final NotificationFacade _notifications;
  final AudioUiWarmupCoordinator _warmup;
  final UiInteractionCoordinator _interaction;
  bool _disposed = false;

  void _syncInteractionState() {
    if (_disposed) return;
    final paused = _interaction.isInteracting;
    _library.setInteractionPaused(paused);
    _libraryCovers.setInteractionPaused(paused);
    _notifications.setSynchronizationPaused(paused);
    _warmup.setInteractionPaused(paused);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _interaction.removeListener(_syncInteractionState);
    _library.setInteractionPaused(false);
    _libraryCovers.setInteractionPaused(false);
    _notifications.setSynchronizationPaused(false);
    _warmup.setInteractionPaused(false);
  }
}
