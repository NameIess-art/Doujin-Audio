export '../../application/session_switcher_tree.dart'
    show orderTracksForSessionSwitcher, resolveSessionSwitcherSelectedTrack;

import '../playback_providers.dart';
import '../../../settings/presentation/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../application/playback_facade.dart';
import '../../domain/audio_effects.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/ui/undoable_removal_service.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/library_like_cards.dart';

const double sessionVolumeDisplayMaximum = 1.5;
const int sessionVolumeDisplayMaximumPercent = 150;
const double playlistCoverSize = 52;
const double playlistActionContainerWidth = 48;
const double playbackSecondaryControlButtonWidth = 46;
const double playbackSecondaryControlButtonHeight = 40;
const BoxConstraints playbackSecondaryControlButtonConstraints =
    BoxConstraints.tightFor(
      width: playbackSecondaryControlButtonWidth,
      height: playbackSecondaryControlButtonHeight,
    );
const double playlistRowHeight = 64;
const double landscapeDetailTextInset = 4;
const EdgeInsets playlistRowPadding = EdgeInsets.symmetric(
  horizontal: AppSpacing.xs,
  vertical: 6,
);
const RoundedRectangleBorder playlistRowShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(
    Radius.circular(LibraryLikeCardMetrics.coverRadius),
  ),
);

Color playlistTemporaryCardColor(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
}

UndoableRemovalKey playbackSessionRemovalKey(String sessionId) =>
    UndoableRemovalKey('playback-session', sessionId);

UndoableRemovalKey playbackQueueEntryRemovalKey(
  String sessionId,
  String entryId,
) => UndoableRemovalKey('playback-queue-entry', '$sessionId:$entryId');

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
    batchMessage: (int count) =>
        i18n.tr('items_removed_count', {'count': count}),
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

IconData sessionVolumeIcon(double gain) {
  if (gain <= 0.001) return Icons.volume_off_rounded;
  if (gain < 0.45) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
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

List<IconData> sessionFeatureBadgeIcons({
  required bool showSubtitles,
  required bool channelSwapEnabled,
  required AudioEffectsState audioEffects,
  required double speed,
}) => [
  for (final badge in sessionFeatureBadgeVisibility(
    showSubtitles: showSubtitles,
    channelSwapEnabled: channelSwapEnabled,
    audioEffects: audioEffects,
    speed: speed,
  ).entries)
    if (badge.value) badge.key,
];

Map<IconData, bool> sessionFeatureBadgeVisibility({
  required bool showSubtitles,
  required bool channelSwapEnabled,
  required AudioEffectsState audioEffects,
  required double speed,
}) {
  return {
    Icons.subtitles_rounded: showSubtitles,
    Icons.speed_rounded: (speed - 1.0).abs() >= 0.001,
    Icons.equalizer_rounded: audioEffects.eqEnabled,
    Icons.keyboard_double_arrow_right_rounded: audioEffects.skipSilenceEnabled,
    Icons.noise_control_off_rounded: audioEffects.noiseReductionEnabled,
    Icons.compress_rounded: audioEffects.volumeNormalizationEnabled,
    Icons.surround_sound_rounded:
        audioEffects.panning.abs() >= 0.001 ||
        audioEffects.frontBack.abs() >= 0.001,
    Icons.swap_horiz_rounded: channelSwapEnabled,
  };
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
  return '${rounded.toStringAsFixed(2)}x';
}

ButtonStyle sessionDetailResetButtonStyle(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  return appSurfaceButtonStyle(
    colorScheme: cs,
    platform: theme.platform,
    defaultBackgroundColor: cs.secondaryContainer,
    style: FilledButton.styleFrom(
      backgroundColor: cs.primary.withValues(alpha: 0.12),
      foregroundColor: cs.primary,
      elevation: 0,
      minimumSize: const Size.fromHeight(48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
  );
}

ButtonStyle playbackSecondaryControlButtonStyle({
  required Color foregroundColor,
  Color backgroundColor = Colors.transparent,
  Color? disabledForegroundColor,
}) {
  return appIconButtonStyle(
    IconButton.styleFrom(
      fixedSize: const Size(
        playbackSecondaryControlButtonWidth,
        playbackSecondaryControlButtonHeight,
      ),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const StadiumBorder(),
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      disabledForegroundColor: disabledForegroundColor,
    ),
  );
}
