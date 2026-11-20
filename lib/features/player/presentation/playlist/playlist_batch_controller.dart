import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/application/audio_path_coordinator.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/audio_state_services.dart';
import '../../application/playback_facade.dart';
import '../../domain/playback_queue.dart';
import 'playlist_shared_helpers.dart';

/// Orchestrates multi-selection batch actions on the playlist.
abstract final class PlaylistBatchActions {
  static Future<void> playSelected({
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    final playback = ref.read(playbackFacadeProvider);
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final sessionIds = selectedSessionIds.toList(growable: false);
    for (final id in sessionIds) {
      final cardState = ref.read(playlistSessionCardStateProvider(id));
      if (cardState != null && !cardState.isPlaying) {
        await playback.toggleSessionPlayPause(id);
      }
    }
  }

  static Future<void> pauseSelected({
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    final playback = ref.read(playbackFacadeProvider);
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final sessionIds = selectedSessionIds.toList(growable: false);
    for (final id in sessionIds) {
      final cardState = ref.read(playlistSessionCardStateProvider(id));
      if (cardState != null && cardState.isPlaying) {
        await playback.toggleSessionPlayPause(id);
      }
    }
  }

  static List<String> pinnableSessionIds(
    Iterable<PlaybackDirectoryEntry> entries,
    Set<String> selectedSessionIds,
  ) => [
    for (final entry in entries)
      if (!entry.isTemporary && selectedSessionIds.contains(entry.id)) entry.id,
  ];

  static Future<void> pinSelected({
    required BuildContext context,
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final sessionIds = selectedSessionIds.toList(growable: false);
    await saveSettingsWithFeedback(
      context,
      () => ref
          .read(settingsCommandControllerProvider)
          .togglePlaylistSessionsPinned(sessionIds),
    );
  }

  static Future<void> removeSelected({
    required BuildContext context,
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.destructive),
    );
    final toRemove = selectedSessionIds.toList(growable: false);
    await stagePlaybackSessionRemovals(context, ref, toRemove);
  }

  static Future<void> createPlaybackQueue({
    required WidgetRef ref,
    required List<PlaybackDirectoryEntry> visibleEntries,
    required Set<String> selectedSessionIds,
    required PlaybackFacade playback,
    required AudioPathCoordinator paths,
    required VoidCallback onQueueAdded,
  }) async {
    final selectedIds = Set<String>.of(selectedSessionIds);
    if (!hasSelectedPlaybackQueueSource(
      playback: playback,
      paths: paths,
      selectedSessionIds: selectedIds,
    )) {
      return;
    }

    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final context = ref.context;
    final entries = <PlaybackQueueEntry>[];
    for (final entry in visibleEntries) {
      if (!selectedIds.contains(entry.id)) continue;
      if (entry.queueName != null) {
        if (await playback.ensureSessionQueueLoaded(entry.id)) {
          final queue = playback.sessionById(entry.id)?.playbackQueue;
          if (queue != null) {
            entries.addAll(
              queue.entries.where((entry) => entry.tracks.isNotEmpty),
            );
          }
        }
        continue;
      }
      final path = playback.sessionById(entry.id)?.currentTrackPath;
      if (path == null) continue;
      final track = paths.sessionTrackForPath(entry.id, path);
      if (track == null) continue;
      final tracks = track.isSingle
          ? [track]
          : paths.tracksInSameWork(track.path);
      if (tracks.isEmpty) continue;
      entries.add(
        PlaybackQueueEntry(
          id: '',
          kind: track.isSingle
              ? PlaybackQueueEntryKind.track
              : PlaybackQueueEntryKind.work,
          title: track.isSingle
              ? track.displayName
              : paths.workTitleForTrack(track),
          tracks: tracks,
          workRootPath: track.isSingle
              ? null
              : paths.workRootForTrack(track.path),
        ),
      );
    }
    if (entries.isEmpty || !context.mounted) return;
    final queueCount = playback.sessions.values
        .where((session) => session.isPlaybackQueue)
        .length;
    final queue = playback.createPlaybackQueue(
      i18n.tr('default_playback_queue_name', {
        'number': (queueCount + 1).toString(),
      }),
    );
    onQueueAdded();
    await playback.addPlaybackQueueEntries(queue.id, entries);
  }

  static bool hasSelectedPlaybackQueueSource({
    required PlaybackFacade playback,
    required AudioPathCoordinator paths,
    required Set<String> selectedSessionIds,
  }) {
    for (final id in selectedSessionIds) {
      final session = playback.sessionById(id);
      if (session == null) continue;
      final queue = session.playbackQueue;
      if (queue != null
          ? queue.hasTracks
          : session.currentTrackPath.isNotEmpty &&
                paths.sessionTrackForPath(id, session.currentTrackPath) !=
                    null) {
        return true;
      }
    }
    return false;
  }
}
