import '../playback_providers.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_dialog.dart';
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

const double _playbackQueueEditPanelHeight = 350;
const double _playbackQueueNamePanelHeight = 192;

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
  final _nameController = TextEditingController();

  String get sessionId => widget.sessionId;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

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
    final tokens = AppDesignTokens.of(context);
    final queueColor = queue.colorValue != null
        ? Color(queue.colorValue!)
        : cs.primary;

    ButtonStyle buildActionStyle({Color? foregroundColor}) {
      return appTextButtonStyle(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          foregroundColor: foregroundColor,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    }

    final actionStyle = buildActionStyle();
    void saveName() {
      if (playback.renamePlaybackQueue(sessionId, _nameController.text)) {
        _finishEditingName();
      }
    }

    Widget buildContent({required bool editingName}) {
      final header = Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: queueColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(tokens.radiusSmall),
            ),
            child: Icon(
              editingName
                  ? Icons.drive_file_rename_outline_rounded
                  : Icons.edit_note_rounded,
              key: ValueKey(
                editingName
                    ? 'playback_queue_name_header_icon'
                    : 'playback_queue_edit_header_icon',
              ),
              color: queueColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              editingName ? i18n.tr('edit_queue_name') : queue.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: editingName ? null : queueColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      );
      final actions = Align(
        alignment: Alignment.centerRight,
        child: editingName
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    style: actionStyle,
                    onPressed: _finishEditingName,
                    child: Text(i18n.tr('cancel')),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: actionStyle,
                    onPressed: saveName,
                    child: Text(i18n.tr('save')),
                  ),
                ],
              )
            : TextButton(
                style: buildActionStyle(foregroundColor: cs.error),
                onPressed: () => _removeQueue(context, ref),
                child: Text(i18n.tr('remove_queue')),
              ),
      );

      return editingName
          ? SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('playback_queue_name_input'),
                    controller: _nameController,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => saveName(),
                  ),
                  const SizedBox(height: 4),
                  actions,
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 18),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _queueEditTile(
                            context,
                            Icons.playlist_play_rounded,
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
                            () {
                              _nameController.text = queue.name;
                              setState(() => _editingName = true);
                            },
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
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.8,
                                  ),
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
                  actions,
                ],
              ),
            );
    }

    return PopScope(
      canPop: !_editingName,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editingName) _finishEditingName();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
          // Base the anchor on the safe height before the keyboard changes
          // the system bar inset.
          final anchorHeight =
              (height - MediaQuery.viewPaddingOf(context).bottom).clamp(
                0.0,
                height,
              );
          final usableHeight = (height - keyboardHeight).clamp(
            0.0,
            anchorHeight,
          );
          final editHeight = anchorHeight.clamp(
            0.0,
            _playbackQueueEditPanelHeight,
          );
          final nameHeight = usableHeight.clamp(
            0.0,
            _playbackQueueNamePanelHeight,
          );
          final editTop = (anchorHeight - editHeight) / 2;
          final top = _editingName
              ? editTop.clamp(0.0, usableHeight - nameHeight)
              : editTop;
          final duration = MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : kAppFadeDuration;

          Widget? secondary;
          if (_editingName) {
            secondary = Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                key: const ValueKey('playback_queue_name_panel'),
                width: double.infinity,
                height: nameHeight,
                child: buildContent(editingName: true),
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

          final radius = BorderRadius.circular(
            AppDesignTokens.of(context).radiusOverlay,
          );
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: Align(
              alignment: Alignment.topCenter,
              child: DecoratedBox(
                key: const ValueKey('playback_queue_panel_surface'),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.22),
                      blurRadius: 32,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: Material(
                  color: cs.surfaceContainerLow,
                  borderRadius: radius,
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedSize(
                    alignment: Alignment.topCenter,
                    duration: duration,
                    curve: kAppFadeCurve,
                    // Run this tween outside the transition's inactive page,
                    // where tickers stop as soon as the name editor opens.
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: _editingName ? 0 : 1),
                      duration: duration,
                      curve: kAppFadeCurve,
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: editHeight,
                        maxHeight: editHeight,
                        child: SizedBox.expand(
                          key: const ValueKey('playback_queue_edit_panel'),
                          child: buildContent(editingName: false),
                        ),
                      ),
                      builder: (context, opacity, primary) =>
                          AppMenuContentTransition(
                            primary: SizedBox(
                              width: double.infinity,
                              height: _editingName ? nameHeight : editHeight,
                              child: Opacity(opacity: opacity, child: primary),
                            ),
                            secondary: secondary,
                          ),
                    ),
                  ),
                ),
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
