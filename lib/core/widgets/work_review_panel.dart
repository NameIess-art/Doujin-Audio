import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import '../media/audio_detail.dart';
import 'app_buttons.dart';
import 'app_edit_panel.dart';
import 'app_entry_ink_well.dart';
import 'app_feedback.dart';
import 'horizontal_edge_fade_scroll.dart';
import 'unified_popup_menu.dart';
import 'windows_smooth_scroll_controller.dart';
import 'work_listen_status_badge.dart';

typedef WorkReviewDraft = ({
  WorkListenStatus? listenStatus,
  int? userRating,
  String reviewText,
});

class WorkUserReviewSection extends StatelessWidget {
  const WorkUserReviewSection({
    super.key,
    required this.listenStatus,
    required this.userRating,
    required this.reviewText,
    required this.translate,
    required this.onStatusChanged,
    required this.onRatingChanged,
    required this.onOpenNoteEditor,
    this.wrapCopyableNote,
  });

  final WorkListenStatus? listenStatus;
  final int? userRating;
  final String reviewText;
  final String Function(String) translate;
  final ValueChanged<WorkListenStatus?> onStatusChanged;
  final ValueChanged<int?> onRatingChanged;
  final VoidCallback onOpenNoteEditor;
  final Widget Function(BuildContext context, String note, Widget child)?
  wrapCopyableNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(context);
    final normalizedNote = AudioDetail.normalizeReviewText(reviewText);
    final hasNote = normalizedNote.isNotEmpty;

    final statusHeight =
        MediaQuery.textScalerOf(context).scale(12) *
            (theme.textTheme.bodyMedium?.height ?? 1.4) +
        12;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          HorizontalEdgeFadeScroll(
            key: const ValueKey<String>('work_review_status_edge_fade'),
            builder: (scrollController) => SizedBox(
              height: statusHeight,
              child: SingleChildScrollView(
                key: const ValueKey<String>('work_review_status_scroller'),
                controller: scrollController,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < WorkListenStatus.values.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 6),
                      Builder(
                        builder: (context) {
                          final status = WorkListenStatus.values[index];
                          final selected = listenStatus == status;
                          final label = translate(
                            workListenStatusTranslationKey(status),
                          );
                          return _StatusCapsule(
                            capsuleKey: ValueKey<String>(
                              'work_review_status_${status.wireValue}',
                            ),
                            status: status,
                            label: label,
                            selected: selected,
                            onTap: () {
                              unawaited(
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.selection,
                                ),
                              );
                              onStatusChanged(selected ? null : status);
                            },
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _InteractiveStarBar(
                rating: userRating,
                starSize: 20,
                keyPrefix: 'work_review_star',
                onChanged: (next) {
                  unawaited(
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.selection,
                    ),
                  );
                  onRatingChanged(next);
                },
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  userRating == null
                      ? translate('work_unrated')
                      : translate(
                          'work_user_rating_stars',
                        ).replaceAll('{count}', '$userRating'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: userRating == null
                        ? FontWeight.w500
                        : FontWeight.w700,
                    color: userRating == null ? cs.onSurfaceVariant : cs.primary,
                  ),
                ),
              ),
              AppEntryInkWell(
                key: const ValueKey<String>('work_review_note_button'),
                onTap: onOpenNoteEditor,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        hasNote
                            ? Icons.edit_note_rounded
                            : Icons.note_add_outlined,
                        size: 16,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        translate(
                          hasNote
                              ? 'work_review_note'
                              : 'work_write_review_note',
                        ),
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (hasNote) ...[
            const SizedBox(height: 6),
            Builder(
              builder: (context) {
                final cardRadius = BorderRadius.circular(tokens.radiusSmall);
                final noteCard = Material(
                  color: Colors.transparent,
                  child: AppEntryInkWell(
                    key: const ValueKey<String>('work_review_note_card'),
                    onTap: onOpenNoteEditor,
                    borderRadius: cardRadius,
                    child: Ink(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? cs.surfaceContainerHighest.withValues(alpha: 0.42)
                            : cs.surfaceContainerHigh.withValues(alpha: 0.56),
                        borderRadius: cardRadius,
                        border: Border.all(
                          color: cs.outlineVariant.withValues(
                            alpha: isDark ? 0.28 : 0.36,
                          ),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        normalizedNote,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          height: 1.45,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                );
                return wrapCopyableNote?.call(
                      context,
                      normalizedNote,
                      noteCard,
                    ) ??
                    noteCard;
              },
            ),
          ],
        ],
      ),
    );
  }
}

Future<WorkReviewDraft?> showWorkReviewEditPanel({
  required BuildContext context,
  required String workTitle,
  String rjCode = '',
  required WorkListenStatus? initialStatus,
  required int? initialUserRating,
  required String initialReviewText,
  required bool syncsWithCloud,
  required String Function(String) translate,
}) {
  final headerTitle = rjCode.trim().isNotEmpty && !workTitle.contains(rjCode)
      ? '$workTitle · ${rjCode.trim()}'
      : (workTitle.trim().isNotEmpty
            ? workTitle.trim()
            : translate('work_review_edit_title'));
  final header = AppEditPanelHeader(
    icon: Icons.rate_review_rounded,
    title: headerTitle,
  );
  return showAppInputPanel<WorkReviewDraft>(
    context: context,
    header: header,
    preferredHeight: null,
    surfaceKey: const ValueKey<String>('work_review_edit_panel'),
    builder: (panelContext, _) => _WorkReviewEditForm(
      header: header,
      initialStatus: initialStatus,
      initialUserRating: initialUserRating,
      initialReviewText: initialReviewText,
      syncHint: translate(
        syncsWithCloud
            ? 'work_review_sync_hint_cloud'
            : 'work_review_sync_hint_local',
      ),
      translate: translate,
    ),
  );
}

class _WorkReviewEditForm extends StatefulWidget {
  const _WorkReviewEditForm({
    required this.header,
    required this.initialStatus,
    required this.initialUserRating,
    required this.initialReviewText,
    required this.syncHint,
    required this.translate,
  });

  final AppEditPanelHeader header;
  final WorkListenStatus? initialStatus;
  final int? initialUserRating;
  final String initialReviewText;
  final String syncHint;
  final String Function(String) translate;

  @override
  State<_WorkReviewEditForm> createState() => _WorkReviewEditFormState();
}

class _WorkReviewEditFormState extends State<_WorkReviewEditForm> {
  late WorkListenStatus? _status = widget.initialStatus;
  late int? _rating = widget.initialUserRating;
  late final TextEditingController _noteController = TextEditingController(
    text: widget.initialReviewText,
  );

  bool get _hasAnyValue =>
      _status != null ||
      _rating != null ||
      AudioDetail.normalizeReviewText(_noteController.text).isNotEmpty;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _submit(WorkReviewDraft draft) {
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final actionStyle = appEditPanelActionStyle();
    final destructiveStyle = appEditPanelActionStyle(foregroundColor: cs.error);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.header,
            const SizedBox(height: 6),
            Text(
              widget.syncHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontSize: 11.5,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final status in WorkListenStatus.values)
                  _StatusCapsule(
                    capsuleKey: ValueKey<String>(
                      'work_review_panel_status_${status.wireValue}',
                    ),
                    status: status,
                    label: widget.translate(
                      workListenStatusTranslationKey(status),
                    ),
                    selected: _status == status,
                    onTap: () => setState(() {
                      _status = _status == status ? null : status;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _InteractiveStarBar(
                  rating: _rating,
                  starSize: 24,
                  keyPrefix: 'work_review_panel_star',
                  onChanged: (next) => setState(() => _rating = next),
                ),
                const SizedBox(width: 8),
                Text(
                  _rating == null
                      ? widget.translate('work_unrated')
                      : widget
                            .translate('work_user_rating_stars')
                            .replaceAll('{count}', '$_rating'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: _rating == null ? cs.onSurfaceVariant : cs.primary,
                    fontWeight: _rating == null
                        ? FontWeight.w500
                        : FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('work_review_panel_note_input'),
              controller: _noteController,
              contextMenuBuilder: buildAppEditableTextMenu,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: widget.translate('work_review_note'),
                hintText: widget.translate('work_review_note_hint'),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (_hasAnyValue ||
                    widget.initialStatus != null ||
                    widget.initialUserRating != null ||
                    widget.initialReviewText.trim().isNotEmpty)
                  TextButton(
                    key: const ValueKey<String>('work_review_panel_clear'),
                    style: destructiveStyle,
                    onPressed: () => _submit((
                      listenStatus: null,
                      userRating: null,
                      reviewText: '',
                    )),
                    child: Text(widget.translate('work_review_clear')),
                  ),
                const Spacer(),
                TextButton(
                  style: actionStyle,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(widget.translate('cancel')),
                ),
                const SizedBox(width: 8),
                AppPillButton(
                  key: const ValueKey<String>('work_review_panel_save'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  onPressed: () => _submit((
                    listenStatus: _status,
                    userRating: _rating,
                    reviewText: AudioDetail.normalizeReviewText(
                      _noteController.text,
                    ),
                  )),
                  child: Text(widget.translate('save')),
                ),
              ],
            ),
          ],
        ),
      ).withWindowsSmoothScroll(),
    );
  }
}

class _StatusCapsule extends StatelessWidget {
  const _StatusCapsule({
    required this.capsuleKey,
    required this.status,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key capsuleKey;
  final WorkListenStatus status;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg = selected
        ? cs.primary.withValues(alpha: isDark ? 0.24 : 0.14)
        : (isDark
              ? cs.surfaceContainerHighest.withValues(alpha: 0.45)
              : cs.surfaceContainerHigh.withValues(alpha: 0.60));
    final fg = selected ? cs.primary : cs.onSurfaceVariant;
    final border = selected
        ? cs.primary.withValues(alpha: 0.55)
        : cs.outlineVariant.withValues(alpha: isDark ? 0.28 : 0.38);

    return Material(
      color: Colors.transparent,
      child: AppEntryInkWell(
        key: capsuleKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border, width: selected ? 1.0 : 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                workListenStatusIcon(status),
                size: 13,
                color: fg,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InteractiveStarBar extends StatelessWidget {
  const _InteractiveStarBar({
    required this.rating,
    required this.starSize,
    required this.keyPrefix,
    required this.onChanged,
  });

  final int? rating;
  final double starSize;
  final String keyPrefix;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = rating ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var star = 1; star <= 5; star++)
          AppEntryInkWell(
            key: ValueKey<String>('${keyPrefix}_$star'),
            onTap: () => onChanged(current == star ? null : star),
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                star <= current
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                size: starSize,
                color: star <= current
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.65),
              ),
            ),
          ),
      ],
    );
  }
}
