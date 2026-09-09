import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/audio_state_services.dart';
import '../application/notification_facade.dart';
import '../application/playback_facade.dart';
import '../application/playback_subtitle_service.dart';
import '../application/subtitle_overlay_controller.dart';
import '../application/timer_facade.dart';

final playbackFacadeProvider = Provider<PlaybackFacade>((ref) {
  throw UnimplementedError(
    'playbackFacadeProvider must be overridden in ProviderScope.',
  );
});

final playbackSubtitleServiceProvider = Provider<PlaybackSubtitleService>((
  ref,
) {
  throw UnimplementedError(
    'playbackSubtitleServiceProvider must be overridden in ProviderScope.',
  );
});

final subtitleOverlayControllerProvider = Provider<SubtitleOverlayController>((
  ref,
) {
  final controller = SubtitleOverlayController();
  ref.onDispose(controller.dispose);
  return controller;
});

final timerFacadeProvider = Provider<TimerFacade>((ref) {
  throw UnimplementedError(
    'timerFacadeProvider must be overridden in ProviderScope.',
  );
});

final notificationFacadeProvider = Provider<NotificationFacade>((ref) {
  throw UnimplementedError(
    'notificationFacadeProvider must be overridden in ProviderScope.',
  );
});

final playbackStateProvider = StreamProvider<PlaybackStateSliceData>((ref) {
  return ref.watch(playbackFacadeProvider).states;
});

final timerStateProvider = StreamProvider<TimerStateSliceData>((ref) {
  return ref.watch(timerFacadeProvider).states;
});
