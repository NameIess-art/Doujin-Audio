import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../playback_providers.dart';

Future<void> showSubtitleMenuBottomSheet({
  required BuildContext context,
  required PlaybackSessionSnapshot session,
  required VoidCallback? onToggleGlobalSubtitle,
}) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (sheetContext) => SubtitleMenuSheet(
      session: session,
      onToggleGlobalSubtitle: onToggleGlobalSubtitle,
    ),
  );
}

class SubtitleMenuSheet extends ConsumerStatefulWidget {
  const SubtitleMenuSheet({
    super.key,
    required this.session,
    this.onToggleGlobalSubtitle,
  });

  final PlaybackSessionSnapshot session;
  final VoidCallback? onToggleGlobalSubtitle;

  @override
  ConsumerState<SubtitleMenuSheet> createState() => _SubtitleMenuSheetState();
}

class _SubtitleMenuSheetState extends ConsumerState<SubtitleMenuSheet> {
  bool _importing = false;

  String _formatOffset(Duration offset) {
    final seconds = offset.inMilliseconds / 1000.0;
    if (offset == Duration.zero) return '0.0s';
    final sign = seconds > 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
  }

  Future<void> _pickSubtitleFile(
    BuildContext context,
    PlaybackSubtitleService subtitles,
  ) async {
    if (_importing) return;
    setState(() => _importing = true);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final trackPath = widget.session.currentTrackPath;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'lrc',
          'srt',
          'vtt',
          'webvtt',
          'ass',
          'ssa',
          'txt',
        ],
      );
      if (!mounted) return;
      final selectedPath = result?.files.singleOrNull?.path;
      if (selectedPath == null || selectedPath.isEmpty) return;

      final track = await subtitles.importSubtitle(trackPath, selectedPath);
      if (!mounted || !context.mounted) return;

      if (track != null) {
        ref
            .read(subtitleSettingsProvider.notifier)
            .ensureSubtitlesEnabled(widget.session.id);
        showAppSnackBar(
          context,
          i18n.tr('subtitle_imported'),
          tone: AppFeedbackTone.success,
          icon: Icons.check_circle_rounded,
        );
      } else {
        showAppSnackBar(
          context,
          i18n.tr('subtitle_import_failed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _adjustOffset(PlaybackSubtitleService subtitles, int deltaMs) {
    final trackPath = widget.session.currentTrackPath;
    final currentOffset = subtitles.getOffset(trackPath);
    final nextMs = (currentOffset.inMilliseconds + deltaMs).clamp(
      -60000,
      60000,
    );
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(
      subtitles.setTrackOffset(trackPath, Duration(milliseconds: nextMs)),
    );
  }

  void _resetOffset(PlaybackSubtitleService subtitles) {
    final trackPath = widget.session.currentTrackPath;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(subtitles.setTrackOffset(trackPath, Duration.zero));
  }

  void _removeCustomSubtitle(PlaybackSubtitleService subtitles) {
    final trackPath = widget.session.currentTrackPath;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    unawaited(subtitles.removeCustomSubtitle(trackPath));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final i18n = ref.watch(appLanguageProviderInstanceProvider);
    final subtitles = ref.watch(playbackSubtitleServiceProvider);
    final subtitleSettings = ref.watch(subtitleSettingsProvider);

    final trackPath = widget.session.currentTrackPath;
    final showSubtitles = subtitleSettings.isShowEnabled(widget.session.id);
    final globalSubtitles = subtitleSettings.isGlobalEnabled(widget.session.id);

    return ListenableBuilder(
      listenable: subtitles,
      builder: (context, _) {
        final activeOffset = subtitles.getOffset(trackPath);
        final activeCustomPath = subtitles.getCustomSubtitlePath(trackPath);
        final activeTrack = subtitles.trackSync(trackPath);
        final isOffsetZero = activeOffset == Duration.zero;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Title Row
                  Row(
                    children: [
                      Icon(
                        Icons.subtitles_rounded,
                        color: cs.primary,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        i18n.tr('subtitles'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (activeCustomPath != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            path.basename(activeCustomPath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Switches Card
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        SwitchListTile(
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(16),
                            ),
                          ),
                          secondary: Icon(
                            showSubtitles
                                ? Icons.subtitles_rounded
                                : Icons.subtitles_off_rounded,
                            color: showSubtitles ? cs.primary : cs.onSurfaceVariant,
                          ),
                          title: Text(
                            showSubtitles
                                ? i18n.tr('turn_off_subtitle')
                                : i18n.tr('turn_on_subtitle'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          value: showSubtitles,
                          onChanged: (_) {
                            ref
                                .read(subtitleSettingsProvider.notifier)
                                .toggleShowSubtitles(widget.session.id);
                          },
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          endIndent: 16,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                        SwitchListTile(
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              bottom: Radius.circular(16),
                            ),
                          ),
                          secondary: Icon(
                            globalSubtitles
                                ? Icons.layers_rounded
                                : Icons.layers_clear_rounded,
                            color: globalSubtitles
                                ? cs.primary
                                : cs.onSurfaceVariant,
                          ),
                          title: Text(
                            i18n.tr('subtitle_global_display'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          value: globalSubtitles,
                          onChanged: (_) {
                            widget.onToggleGlobalSubtitle?.call();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Import Subtitle Card
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          leading: _importing
                              ? SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: cs.primary,
                                  ),
                                )
                              : Icon(
                                  Icons.upload_file_rounded,
                                  color: cs.primary,
                                ),
                          title: Text(
                            i18n.tr('import_subtitle'),
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            activeCustomPath != null
                                ? '${i18n.tr('reimport_subtitle')}: ${path.basename(activeCustomPath)}'
                                : (activeTrack != null
                                    ? '已载入: ${path.basename(activeTrack.sourcePath)}'
                                    : i18n.tr('import_subtitle_hint')),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                          ),
                          onTap: _importing
                              ? null
                              : () => _pickSubtitleFile(context, subtitles),
                        ),
                        if (activeCustomPath != null) ...[
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            indent: 16,
                            endIndent: 16,
                            color: cs.outlineVariant.withValues(alpha: 0.35),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: cs.error,
                                  visualDensity: VisualDensity.compact,
                                ),
                                icon: const Icon(Icons.undo_rounded, size: 16),
                                label: Text(
                                  i18n.tr('remove_custom_subtitle'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () =>
                                    _removeCustomSubtitle(subtitles),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Subtitle Sync Controls Card
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.sync_rounded,
                              size: 20,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              i18n.tr('subtitle_sync'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isOffsetZero
                                    ? cs.surfaceContainerHighest
                                    : cs.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                i18n.tr('subtitle_offset_current', {
                                  'offset': _formatOffset(activeOffset),
                                }),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: isOffsetZero
                                      ? cs.onSurfaceVariant
                                      : cs.onPrimaryContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Five Sync Buttons: [-0.5s] [-0.1s] [重置] [+0.1s] [+0.5s]
                        Row(
                          children: [
                            Expanded(
                              child: _SyncControlButton(
                                label: '-0.5s',
                                onPressed: () =>
                                    _adjustOffset(subtitles, -500),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: '-0.1s',
                                onPressed: () =>
                                    _adjustOffset(subtitles, -100),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: i18n.tr('subtitle_reset'),
                                isReset: true,
                                onPressed: isOffsetZero
                                    ? null
                                    : () => _resetOffset(subtitles),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: '+0.1s',
                                onPressed: () =>
                                    _adjustOffset(subtitles, 100),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SyncControlButton(
                                label: '+0.5s',
                                onPressed: () =>
                                    _adjustOffset(subtitles, 500),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SyncControlButton extends StatelessWidget {
  const _SyncControlButton({
    required this.label,
    required this.onPressed,
    this.isReset = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isReset;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onPressed != null;

    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        side: BorderSide(
          color: enabled
              ? (isReset
                  ? cs.primary.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.5))
              : cs.outlineVariant.withValues(alpha: 0.2),
          width: isReset && enabled ? 1.0 : 0.8,
        ),
        backgroundColor: isReset && enabled
            ? cs.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        foregroundColor: enabled
            ? (isReset ? cs.primary : cs.onSurface)
            : cs.onSurface.withValues(alpha: 0.38),
      ),
      onPressed: onPressed,
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: isReset ? 12 : 11,
          fontWeight: isReset ? FontWeight.bold : FontWeight.w600,
        ),
      ),
    );
  }
}
