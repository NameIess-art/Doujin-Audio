import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
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
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
  return showAppOverlayPanel<void>(
    context: context,
    barrierLabel: i18n.tr('close'),
    mobileAlignment: Alignment.center,
    mobileOuterPadding: const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 24,
    ),
    builder: (_) => PlaybackQueueEditPage(sessionId: sessionId),
  );
}

const double _playbackQueueEditPanelHeight = 350;

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
      width: double.infinity,
      height: _playbackQueueEditPanelHeight,
      child: DecoratedBox(
        key: const ValueKey('playback_queue_edit_panel'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: cs.surfaceContainerLow,
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: queueColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(tokens.radiusSmall),
                      ),
                      child: Icon(
                        Icons.edit_note_rounded,
                        key: const ValueKey('playback_queue_edit_header_icon'),
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
                  ],
                ),
                const SizedBox(height: 18),
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
                const SizedBox(height: 12),
                _queueEditTile(
                  context,
                  Icons.drive_file_rename_outline_rounded,
                  i18n.tr('edit_queue_name'),
                  () => _editQueueName(context, playback, queue.name),
                ),
                const SizedBox(height: 12),
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
                const Spacer(),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: cs.error,
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _removeQueue(context, ref),
                    child: Text(i18n.tr('remove_queue')),
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
  }) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final foreground = cs.onSurface;
    final iconColor = cs.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(tokens.radiusSmall),
                ),
                child: Icon(
                  icon,
                  key: ValueKey(
                    'playback_queue_edit_tile_icon_${icon.codePoint}',
                  ),
                  size: 20,
                  color: iconColor,
                ),
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
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
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
