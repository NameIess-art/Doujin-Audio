import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../library/application/library_facade.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../application/playback_facade.dart';
import '../../domain/audio_effects.dart';
import '../../domain/playback_mode.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/natural_sort.dart';
import '../../../../core/media/path_matcher.dart';
import '../../../../core/ui/undoable_removal_service.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/library_like_cards.dart';

const double sessionVolumeDisplayMaximum = 1.5;
const int sessionVolumeDisplayMaximumPercent = 150;
const double playlistCoverSize = 72;
const double playlistRowHeight = 88;
const EdgeInsets playlistRowPadding = EdgeInsets.all(AppSpacing.xs);
const RoundedRectangleBorder playlistRowShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(
    Radius.circular(LibraryLikeCardMetrics.cardRadius),
  ),
);

LinearGradient playlistActiveHighlightGradient(
  bool isPlaying,
  Color highlightColor,
) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: isPlaying
      ? <Color>[
          highlightColor,
          Colors.transparent,
          Colors.transparent,
          Colors.transparent,
        ]
      : const <Color>[
          Colors.transparent,
          Colors.transparent,
          Colors.transparent,
          Colors.transparent,
        ],
);

UndoableRemovalKey playbackSessionRemovalKey(String sessionId) =>
    UndoableRemovalKey('playback-session', sessionId);

UndoableRemovalKey playbackQueueEntryRemovalKey(
  String sessionId,
  String entryId,
) => UndoableRemovalKey('playback-queue-entry', '$sessionId:$entryId');

UndoableRemovalKey timeSegmentRemovalKey(String labelId) =>
    UndoableRemovalKey('time-segment', labelId);

UndoableRemovalKey equalizerPresetRemovalKey(String presetId) =>
    UndoableRemovalKey('equalizer-preset', presetId);

void showPlaybackRemovalFeedback(
  BuildContext context,
  UndoableRemovalService service, {
  IconData icon = Icons.delete_outline_rounded,
}) {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  showPendingUndoableRemovalFeedback(
    context,
    service: service,
    message: i18n.tr('items_removed_count', {'count': 1}),
    batchMessage: (int count) => i18n.tr('items_removed_count', {'count': count}),
    undoLabel: i18n.tr('undo'),
    failureMessage: i18n.tr('removal_failed'),
    icon: icon,
  );
}

UndoableRemovalAction playbackSessionRemovalAction(
  WidgetRef ref,
  String sessionId,
) {
  final playback = ref.read(playbackFacadeProvider);
  final subtitles = ref.read(subtitleSettingsProvider.notifier);
  final wasPlaying =
      playback.sessionSnapshotById(sessionId)?.effectivePlaying ?? false;
  return UndoableRemovalAction(
    key: playbackSessionRemovalKey(sessionId),
    prepare: () async {
      if (wasPlaying) await playback.toggleSessionPlayPause(sessionId);
      return playback.hasSession(sessionId);
    },
    undo: () async {
      final snapshot = playback.sessionSnapshotById(sessionId);
      if (wasPlaying && snapshot != null && !snapshot.effectivePlaying) {
        await playback.toggleSessionPlayPause(sessionId);
      }
    },
    commit: () async {
      if (!await playback.removeSession(sessionId)) {
        throw StateError('Failed to remove playback session $sessionId');
      }
      subtitles.resetForSession(sessionId);
      await ref
          .read(settingsRepositoryProvider)
          .unpinPlaylistSession(sessionId);
    },
  );
}

Future<bool> stagePlaybackSessionRemovals(
  BuildContext context,
  WidgetRef ref,
  Iterable<String> sessionIds, {
  IconData icon = Icons.delete_outline_rounded,
}) async {
  final service = ref.read(undoableRemovalServiceProvider);
  var stagedAny = false;
  for (final sessionId in sessionIds.toSet()) {
    stagedAny =
        await service.stage(playbackSessionRemovalAction(ref, sessionId)) ||
        stagedAny;
  }
  if (stagedAny && context.mounted) {
    showPlaybackRemovalFeedback(context, service, icon: icon);
  } else if (stagedAny) {
    await service.commitPending();
  }
  return stagedAny;
}

double sessionVolumeDisplayValueFromGain(double gain) {
  final clampedGain = gain
      .clamp(0.0, PlaybackFacade.maxSessionVolume)
      .toDouble();
  if (clampedGain <= 1) return clampedGain;
  return 1 +
      (clampedGain - 1) *
          ((sessionVolumeDisplayMaximum - 1) /
              (PlaybackFacade.maxSessionVolume - 1));
}

double sessionVolumeGainFromDisplayValue(double displayValue) {
  final clampedDisplayValue = displayValue
      .clamp(0.0, sessionVolumeDisplayMaximum)
      .toDouble();
  if (clampedDisplayValue <= 1) return clampedDisplayValue;
  return 1 +
      (clampedDisplayValue - 1) *
          ((PlaybackFacade.maxSessionVolume - 1) /
              (sessionVolumeDisplayMaximum - 1));
}

enum SessionDetailForegroundLevel { strong, medium, muted }

Color sessionDetailForeground(
  ColorScheme colorScheme,
  SessionDetailForegroundLevel level, {
  Color? darkFallback,
}) {
  if (colorScheme.brightness == Brightness.dark) {
    return darkFallback ?? colorScheme.onSurface;
  }

  return switch (level) {
    SessionDetailForegroundLevel.strong => Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.10),
      colorScheme.onSurface,
    ),
    SessionDetailForegroundLevel.medium => Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.06),
      colorScheme.onSurfaceVariant,
    ),
    SessionDetailForegroundLevel.muted => Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.03),
      colorScheme.onSurfaceVariant,
    ).withValues(alpha: 0.72),
  };
}

List<MusicTrack> orderTracksForSessionSwitcher(
  List<MusicTrack> tracks, {
  required bool preserveQueueOrder,
}) {
  if (preserveQueueOrder ||
      tracks.length < 2 ||
      !tracks.every((track) => track.isRemoteAsmr)) {
    return tracks;
  }
  final sorted = List<MusicTrack>.of(tracks);
  sorted.sort((left, right) {
    final leftPath = left.remoteMetadata?['trackRelativePath']?.toString();
    final rightPath = right.remoteMetadata?['trackRelativePath']?.toString();
    final pathResult = compareNatural(
      leftPath?.trim().isNotEmpty == true ? leftPath!.trim() : left.displayName,
      rightPath?.trim().isNotEmpty == true
          ? rightPath!.trim()
          : right.displayName,
    );
    if (pathResult != 0) return pathResult;
    return compareNatural(left.path, right.path, caseSensitive: true);
  });
  return List<MusicTrack>.unmodifiable(sorted);
}

MusicTrack? resolveSessionSwitcherSelectedTrack({
  required List<MusicTrack> displayedTracks,
  required List<MusicTrack>? queueTracks,
  required String currentPath,
  required int currentQueueIndex,
}) {
  for (final track in displayedTracks) {
    if (PathMatcher.equalsNormalized(track.path, currentPath)) return track;
  }
  if (queueTracks == null ||
      currentQueueIndex < 0 ||
      currentQueueIndex >= queueTracks.length) {
    return null;
  }
  final queuedTrack = queueTracks[currentQueueIndex];
  if (!queuedTrack.isRemoteAsmr) return null;
  for (final track in displayedTracks) {
    if (sameSessionSwitcherTrack(track, queuedTrack)) return track;
  }
  return null;
}

String playlistLoopModeSummary(BuildContext context, SessionLoopMode mode) {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  if (mode == SessionLoopMode.single) return i18n.tr('single_loop');
  final scope = mode.isCrossFolder
      ? i18n.tr('cross_folder')
      : i18n.tr('current_folder');
  final order = mode.isShuffle
      ? i18n.tr('random_order')
      : i18n.tr('sequential_order');
  if (mode.isOneShot) {
    return '$order (${i18n.tr('pause_after_playback')}) - $scope';
  }
  return '$order - $scope';
}

bool sameSessionSwitcherTrack(MusicTrack left, MusicTrack right) {
  if (identical(left, right) ||
      PathMatcher.equalsNormalized(left.path, right.path)) {
    return true;
  }
  if (!left.isRemoteAsmr || !right.isRemoteAsmr) {
    return false;
  }
  final leftRelative = left.remoteMetadata?['trackRelativePath']
      ?.toString()
      .trim();
  final rightRelative = right.remoteMetadata?['trackRelativePath']
      ?.toString()
      .trim();
  if (leftRelative == null ||
      leftRelative.isEmpty ||
      rightRelative == null ||
      rightRelative.isEmpty ||
      normalizedRemoteRelativePath(leftRelative) !=
          normalizedRemoteRelativePath(rightRelative)) {
    return false;
  }
  final leftWorkId = left.remoteMetadata?['id']?.toString().trim();
  final rightWorkId = right.remoteMetadata?['id']?.toString().trim();
  if (leftWorkId?.isNotEmpty == true && rightWorkId?.isNotEmpty == true) {
    return leftWorkId == rightWorkId;
  }
  return left.groupKey.isNotEmpty && left.groupKey == right.groupKey;
}

String normalizedRemoteRelativePath(String value) =>
    path.posix.normalize(value.replaceAll('\\', '/'));

List<IconData> sessionFeatureBadgeIcons({
  required bool showSubtitles,
  required bool channelSwapEnabled,
  required AudioEffectsState audioEffects,
  required double speed,
}) {
  return <IconData>[
    if (showSubtitles) Icons.subtitles_rounded,
    if ((speed - 1.0).abs() >= 0.001) Icons.speed_rounded,
    if (audioEffects.eqEnabled) Icons.tune_rounded,
    if (audioEffects.skipSilenceEnabled)
      Icons.keyboard_double_arrow_right_rounded,
    if (audioEffects.noiseReductionEnabled) Icons.graphic_eq_rounded,
    if (audioEffects.volumeNormalizationEnabled)
      Icons.vertical_align_center_rounded,
    if (audioEffects.panning.abs() >= 0.001) Icons.compare_arrows_rounded,
    if (channelSwapEnabled) Icons.swap_horiz_rounded,
  ];
}

({List<IconData> top, List<IconData> bottom}) splitSessionFeatureBadgeIcons(
  List<IconData> icons, {
  int bottomLimit = 4,
}) {
  return (
    top: icons.skip(bottomLimit).toList(growable: false),
    bottom: icons.take(bottomLimit).toList(growable: false),
  );
}

String formatSpeedValue(double value) {
  final clamped = value.clamp(0.25, 4.0).toDouble();
  final rounded = (clamped * 100).round() / 100.0;
  if ((rounded - rounded.truncateToDouble()).abs() < 0.001) {
    return '${rounded.toInt()}x';
  }
  return '${rounded.toStringAsFixed(2)}x';
}

ButtonStyle sessionDetailResetButtonStyle(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    backgroundColor: cs.primary.withValues(alpha: 0.12),
    foregroundColor: cs.primary,
    elevation: 0,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    visualDensity: VisualDensity.compact,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
}

Future<String?> coverFutureForTrack(
  LibraryFacade library,
  MusicTrack? track, {
  bool cachedOnly = false,
}) {
  if (track == null) {
    return Future<String?>.value();
  }
  if (cachedOnly) {
    return SynchronousFuture<String?>(
      library.resolvedPlaybackCoverPathForTrack(track),
    );
  }
  return library.playbackCoverPathFutureForTrack(track);
}
