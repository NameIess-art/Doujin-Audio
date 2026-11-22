import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/widgets/app_dialog.dart';
import '../../../../core/widgets/app_edit_panel.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
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

class PlaybackQueueEditPage extends ConsumerStatefulWidget {
  const PlaybackQueueEditPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PlaybackQueueEditPage> createState() =>
      _PlaybackQueueEditPageState();
}

class _PlaybackQueueEditPageState extends ConsumerState<PlaybackQueueEditPage> {
  bool _editingColor = false;
  bool _editingName = false;

  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final playback = ref.read(playbackFacadeProvider);
    final queue = ref.watch(
      playbackSessionProvider(sessionId).select((session) {
        final queue = session?.playbackQueue;
        if (queue == null) return null;
        return (
          name: queue.name,
          colorValue: queue.colorValue,
          trackCount: queue.trackCount,
        );
      }),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final queueColor = queue.colorValue != null
        ? Color(queue.colorValue!)
        : cs.primary;

    void saveName(String value) {
      if (playback.renamePlaybackQueue(sessionId, value)) {
        _finishEditingName();
      }
    }

    Widget buildContent() {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppEditPanelHeader(
              icon: Icons.playlist_play_rounded,
              iconKey: const ValueKey('playback_queue_edit_header_icon'),
              title: queue.name,
              accentColor: queueColor,
              titleColor: queueColor,
            ),
            const SizedBox(height: 18),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _queueEditTile(
                      context,
                      Icons.edit_note_rounded,
                      i18n.tr('edit_queue_audio'),
                      () => Navigator.of(context).push(
                        buildAppPageRoute<void>(
                          context: context,
                          separateHeader: true,
                          child: PlaybackQueueAudioEditPage(
                            sessionId: sessionId,
                            returnContext: context,
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
                          '${queue.trackCount}',
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
                      () => setState(() => _editingName = true),
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
                  ],
                ),
              ).withWindowsSmoothScroll(),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: appEditPanelActionStyle(foregroundColor: cs.error),
                onPressed: () => _removeQueue(context, ref),
                child: Text(i18n.tr('remove_queue')),
              ),
            ),
          ],
        ),
      );
    }

    return PopScope(
      canPop: !_editingName && !_editingColor,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_editingName) {
          _finishEditingName();
        } else if (_editingColor) {
          setState(() => _editingColor = false);
        }
      },
      child: AppEditPanel(
        surfaceKey: const ValueKey('playback_queue_panel_surface'),
        editingInput: _editingName,
        builder: (context, editHeight, nameHeight) {
          final duration = MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : kAppFadeDuration;

          Widget? secondary;
          if (_editingName) {
            secondary = Align(
              alignment: Alignment.topCenter,
              child: AppEditInput(
                key: const ValueKey('playback_queue_name_panel'),
                height: nameHeight,
                header: AppEditPanelHeader(
                  icon: Icons.drive_file_rename_outline_rounded,
                  iconKey: const ValueKey('playback_queue_name_header_icon'),
                  title: i18n.tr('edit_queue_name'),
                  accentColor: queueColor,
                ),
                inputKey: const ValueKey('playback_queue_name_input'),
                initialValue: queue.name,
                cancelLabel: i18n.tr('cancel'),
                submitLabel: i18n.tr('save'),
                onCancel: _finishEditingName,
                onSubmit: saveName,
              ),
            );
          } else if (_editingColor) {
            secondary = PlaybackQueueColorPanel(
              colorValue: queue.colorValue,
              height: editHeight,
              onColorChanged: (value) =>
                  playback.setPlaybackQueueColorValue(sessionId, value),
              onBack: () => setState(() => _editingColor = false),
            );
          }

          return AnimatedSize(
            alignment: Alignment.topCenter,
            duration: duration,
            curve: kAppFadeCurve,
            // Run this tween outside the transition's inactive page,
            // where tickers stop as soon as the name editor opens.
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: (_editingName || _editingColor) ? 0 : 1),
              duration: duration,
              curve: kAppFadeCurve,
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: editHeight,
                maxHeight: editHeight,
                child: SizedBox.expand(
                  key: const ValueKey('playback_queue_edit_panel'),
                  child: buildContent(),
                ),
              ),
              builder: (context, opacity, primary) => AppMenuContentTransition(
                primary: SizedBox(
                  width: double.infinity,
                  height: _editingName ? nameHeight : editHeight,
                  child: Opacity(opacity: opacity, child: primary),
                ),
                secondary: secondary,
              ),
            ),
          );
        },
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
      child: AppEntryInkWell(
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

  void _finishEditingName() {
    FocusScope.of(context).unfocus();
    setState(() => _editingName = false);
  }

  Future<void> _removeQueue(BuildContext context, WidgetRef ref) async {
    if (await stagePlaybackSessionRemovals(context, ref, [sessionId]) &&
        context.mounted) {
      Navigator.of(context).pop();
    }
  }
}
