import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/application/audio_path_coordinator.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/playback_facade.dart';
import '../../domain/playback_queue.dart';
import '../playlist_view_models.dart';
import 'playlist_shared_helpers.dart';

/// Orchestrates multi-selection batch actions on the playlist.
abstract final class PlaylistBatchActions {
  static Future<void> playSelected({
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    final multiThreadEnabled =
        ref.read(settingsStateProvider).value?.multiThreadPlaybackEnabled ??
        false;
    if (!multiThreadEnabled && selectedSessionIds.length > 1) return;

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

  static Future<void> pinSelected({
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final sessionIds = selectedSessionIds.toList(growable: false);
    await ref
        .read(settingsCommandControllerProvider)
        .togglePlaylistSessionsPinned(sessionIds);
  }

  static Future<void> removeSelected({
    required BuildContext context,
    required WidgetRef ref,
    required Iterable<String> selectedSessionIds,
  }) async {
    if (selectedSessionIds.isEmpty) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final toRemove = selectedSessionIds.toList(growable: false);
    await stagePlaybackSessionRemovals(context, ref, toRemove);
  }

  static Future<void> createPlaybackQueue({
    required WidgetRef ref,
    required List<PlaylistStructureEntry> visibleEntries,
    required Set<String> selectedSessionIds,
    required PlaybackFacade playback,
    required AudioPathCoordinator paths,
    required VoidCallback onQueueAdded,
  }) async {
    if (!hasSelectedPlaybackQueueSource(
      visibleEntries: visibleEntries,
      paths: paths,
      selectedSessionIds: selectedSessionIds,
    )) {
      return;
    }

    final queueCount = playback.sessions.values
        .where((session) => session.isPlaybackQueue)
        .length;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final queue = playback.createPlaybackQueue(
      i18n.tr('default_playback_queue_name', {
        'number': (queueCount + 1).toString(),
      }),
    );
    onQueueAdded();
    final coordinator = ref.read(playbackQueueCoordinatorProvider);
    for (final entry in visibleEntries) {
      if (!selectedSessionIds.contains(entry.sessionId)) continue;
      if (entry.isPlaybackQueue) {
        for (final sourceEntry
            in entry.session.playbackQueue?.entries ??
                const <PlaybackQueueEntry>[]) {
          if (sourceEntry.tracks.isEmpty) continue;
          if (sourceEntry.kind == PlaybackQueueEntryKind.work) {
            for (final track in sourceEntry.tracks.take(4)) {
              unawaited(
                ref
                    .read(libraryFacadeProvider)
                    .playbackCoverPathFutureForTrack(track),
              );
            }
            await playback.addWorkToPlaybackQueue(
              queue.id,
              title: sourceEntry.title,
              tracks: sourceEntry.tracks,
              workRootPath: sourceEntry.workRootPath,
            );
          } else {
            for (final track in sourceEntry.tracks) {
              await coordinator.addTrack(queue.id, track);
            }
          }
        }
        continue;
      }
      final track = paths.sessionTrackForPath(
        entry.session.id,
        entry.trackPath,
      );
      if (track != null) {
        await coordinator.addWork(queue.id, track);
      }
    }
  }

  static bool hasSelectedPlaybackQueueSource({
    required List<PlaylistStructureEntry> visibleEntries,
    required AudioPathCoordinator paths,
    required Set<String> selectedSessionIds,
  }) {
    for (final entry in visibleEntries) {
      if (!selectedSessionIds.contains(entry.sessionId)) continue;
      if (entry.isPlaybackQueue) {
        final hasEntries = entry.session.playbackQueue?.entries.any(
              (queueEntry) => queueEntry.tracks.isNotEmpty,
            ) ??
            false;
        if (hasEntries) return true;
        continue;
      }
      if (paths.sessionTrackForPath(entry.session.id, entry.trackPath) != null) {
        return true;
      }
    }
    return false;
  }
}
