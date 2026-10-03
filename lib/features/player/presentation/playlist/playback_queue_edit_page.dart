import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../application/playback_facade.dart';
import 'playlist_shared_helpers.dart';

import 'playback_queue_audio_edit_page.dart';
import 'playback_queue_color_panel.dart';

Future<void> showPlaybackQueueEditPanel(
  BuildContext context,
  String sessionId,
) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (_) => PlaybackQueueEditPage(sessionId: sessionId),
  );
}

const double _playbackQueueEditPanelHeight = 390;

class PlaybackQueueEditPage extends ConsumerStatefulWidget {
  const PlaybackQueueEditPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PlaybackQueueEditPage> createState() =>
      _PlaybackQueueEditPageState();
}

class _PlaybackQueueEditPageState extends ConsumerState<PlaybackQueueEditPage> {
  bool _editingColor = false;

  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    final playback = ref.read(playbackFacadeProvider);
    final queue = ref.watch(
      playbackSessionProvider(
        sessionId,
      ).select((session) => session?.playbackQueue),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();
    if (_editingColor) {
      return PlaybackQueueColorPanel(
        colorValue: queue.colorValue,
        height: _playbackQueueEditPanelHeight,
        onColorChanged: (value) =>
            playback.setPlaybackQueueColorValue(sessionId, value),
        onBack: () => setState(() => _editingColor = false),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final queueColor = queue.colorValue != null
        ? Color(queue.colorValue!)
        : cs.primary;

    return SizedBox(
      height: _playbackQueueEditPanelHeight,
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      key: const ValueKey('playback_queue_edit_header_icon'),
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: queueColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(tokens.radiusSmall),
                      ),
                      child: Icon(
                        Icons.playlist_play_rounded,
                        color: queueColor,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            queue.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            i18n.tr('audio_count', {
                              'count': queue.expandedTracks.length.toString(),
                            }),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: i18n.tr('close'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: [
                      _queueEditTile(
                        context,
                        Icons.playlist_play_rounded,
                        i18n.tr('edit_queue_audio'),
                        () => Navigator.of(context).push(
                          buildAppPageRoute<void>(
                            context: context,
                            child: PlaybackQueueAudioEditPage(
                              sessionId: sessionId,
                            ),
                          ),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${queue.expandedTracks.length}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _queueEditTile(
                        context,
                        Icons.drive_file_rename_outline_rounded,
                        i18n.tr('edit_queue_name'),
                        () => _editQueueName(context, playback, queue.name),
                      ),
                      const SizedBox(height: 8),
                      _queueEditTile(
                        context,
                        Icons.palette_outlined,
                        i18n.tr('edit_queue_color'),
                        () => setState(() => _editingColor = true),
                        trailing: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: queueColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: cs.outlineVariant.withValues(alpha: 0.8),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: queueColor.withValues(alpha: 0.35),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Divider(
                          height: 1,
                          thickness: 0.8,
                          color: cs.outlineVariant.withValues(alpha: 0.3),
                        ),
                      ),
                      _queueEditTile(
                        context,
                        Icons.delete_outline_rounded,
                        i18n.tr('remove_queue'),
                        () => _removeQueue(context, ref),
                        destructive: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueEditTile(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap, {
    Widget? trailing,
    bool destructive = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(context);
    final foreground = destructive ? cs.error : cs.onSurface;
    final iconColor = destructive ? cs.error : cs.primary;
    final iconBgColor = destructive
        ? cs.error.withValues(alpha: 0.14)
        : cs.primary.withValues(alpha: 0.12);

    return Material(
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: destructive
                ? cs.errorContainer.withValues(alpha: isDark ? 0.22 : 0.4)
                : cs.surfaceContainer.withValues(alpha: isDark ? 0.6 : 0.85),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  key: ValueKey(
                    'playback_queue_edit_tile_icon_${icon.codePoint}',
                  ),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(tokens.radiusSmall),
                  ),
                  child: Icon(icon, size: 20, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: foreground,
                    ),
                  ),
                ),
                if (trailing != null) ...[trailing, const SizedBox(width: 6)],
                if (!destructive)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editQueueName(
    BuildContext context,
    PlaybackFacade playback,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final name = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: i18n.tr('edit_queue_name'),
        icon: Icons.drive_file_rename_outline_rounded,
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: AppDialogActions(
          children: [
            AppSecondaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: i18n.tr('cancel'),
            ),
            AppPrimaryButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              label: i18n.tr('save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name?.isNotEmpty == true) {
      playback.renamePlaybackQueue(sessionId, name!);
    }
  }

  Future<void> _removeQueue(BuildContext context, WidgetRef ref) async {
    if (await stagePlaybackSessionRemovals(context, ref, [sessionId]) &&
        context.mounted) {
      Navigator.of(context).pop();
    }
  }
}
