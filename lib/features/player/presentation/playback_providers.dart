import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/audio_state_services.dart';
import '../application/notification_facade.dart';
import '../application/playback_facade.dart';
import '../application/playback_session.dart';
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

final activeSessionDetailIdsProvider =
    NotifierProvider<ActiveSessionDetailIdsNotifier, List<String>>(
      ActiveSessionDetailIdsNotifier.new,
    );

class ActiveSessionDetailIdsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void push(String sessionId) {
    if (state.isNotEmpty && state.last == sessionId) return;
    state = [...state, sessionId];
  }

  void pop(String sessionId) {
    if (!state.contains(sessionId)) return;
    final updated = List<String>.from(state)..remove(sessionId);
    state = updated;
  }
}

final activeVisibleSessionCardIdProvider =
    NotifierProvider<ActiveVisibleSessionCardIdNotifier, String?>(
      ActiveVisibleSessionCardIdNotifier.new,
    );

class ActiveVisibleSessionCardIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setVisible(String? sessionId) {
    if (state != sessionId) {
      state = sessionId;
    }
  }
}

final focusedPlaybackSessionProvider = Provider<PlaybackSession?>((ref) {
  final detailSessionIds = ref.watch(activeSessionDetailIdsProvider);
  final playback = ref.watch(playbackFacadeProvider);
  final activeDetailId = detailSessionIds.lastOrNull;
  if (activeDetailId != null) {
    final session = playback.sessionById(activeDetailId);
    if (session != null) return session;
  }

  final cardSessionId = ref.watch(activeVisibleSessionCardIdProvider);
  if (cardSessionId != null) {
    final session = playback.sessionById(cardSessionId);
    if (session != null) return session;
  }

  return null;
});
