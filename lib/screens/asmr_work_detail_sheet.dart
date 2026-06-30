import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import '../services/asmr_library_controller.dart';
import '../services/audio_state_services.dart';
import '../services/ui_operation_service.dart';
import '../theme/app_design_tokens.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';

Future<void> showAsmrWorkDetailSheet(BuildContext context, AsmrWork work) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AsmrWorkDetailSheet(work: work),
  );
}

class _AsmrWorkDetailSheet extends StatefulWidget {
  const _AsmrWorkDetailSheet({required this.work});

  final AsmrWork work;

  @override
  State<_AsmrWorkDetailSheet> createState() => _AsmrWorkDetailSheetState();
}

class _AsmrWorkDetailSheetState extends State<_AsmrWorkDetailSheet> {
  Future<AsmrWorkDetail>? _detailFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _detailFuture ??= UiOperationService.instance.run<AsmrWorkDetail>(
      scope: UiOperationScope.asmrWork(
        AsmrOperationKind.detail,
        widget.work.id,
      ),
      labelKey: 'loading_dot',
      task: (_) =>
          context.read<AsmrLibraryController>().loadWorkDetail(widget.work),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

    return FutureBuilder<AsmrWorkDetail>(
      future: _detailFuture,
      builder: (context, snapshot) {
        final detail = snapshot.data;
        final effectiveWork = detail?.work ?? widget.work;
        final coverCacheWidth = coverCacheWidthForResolution(
          context.select<AudioProvider, CoverImageResolution>(
            (provider) => provider.coverImageResolution,
          ),
        );
        final provider = context.read<AudioProvider>();
        final coverUrl = effectiveWork.preferredCoverUrl;

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.68,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        i18n.tr('asmr_detail_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: effectiveWork.hasSubtitle
                        ? Colors.green.withValues(alpha: 0.2)
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    effectiveWork.hasSubtitle ? '有字幕' : '无字幕',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: effectiveWork.hasSubtitle
                              ? Colors.green
                              : cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AsyncRemoteCoverImage(
                    url: coverUrl,
                    future: provider.coverPathFutureForRemoteCover(coverUrl),
                    initialPath: provider.resolvedCoverPathForRemoteCover(coverUrl),
                    retryFutureBuilder: () =>
                        provider.coverPathFutureForRemoteCover(coverUrl),
                    fit: BoxFit.cover,
                    cacheWidth: coverCacheWidth,
                    useDefaultCacheWidth: coverCacheWidth != null,
                    loadingBuilder: (_) => AspectRatio(
                      aspectRatio: 1.45,
                      child: CoverLoadingArtwork(
                        placeholder: CoverFallbackArtwork(
                          seed: effectiveWork.title,
                          showIcon: false,
                        ),
                        size: 36,
                        strokeWidth: 3,
                        color: asmrBlue,
                      ),
                    ),
                    fallbackBuilder: (_) => AspectRatio(
                      aspectRatio: 1.45,
                      child: CoverFallbackArtwork(
                        seed: effectiveWork.title,
                        icon: Icons.graphic_eq_rounded,
                        iconSize: 36,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  i18n.tr('asmr_detail_basic_info'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: asmrBlue,
                  ),
                ),
                const SizedBox(height: 8),
                _AsmrDetailRow(
                  label: i18n.tr('audio_detail_rj_code'),
                  values: [effectiveWork.rjCode],
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('audio_detail_work_title'),
                  values: [effectiveWork.title],
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('asmr_circle_label'),
                  values: [effectiveWork.circleName],
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('audio_detail_voice_actors'),
                  values: effectiveWork.voiceActors,
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('asmr_tags_label'),
                  values: effectiveWork.tags,
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val),
                ),
                const SizedBox(height: 16),
                Text(
                  i18n.tr('asmr_detail_other'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: asmrBlue,
                  ),
                ),
                const SizedBox(height: 8),
                if (snapshot.hasError) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      i18n.tr('asmr_detail_load_failed'),
                      style: TextStyle(color: cs.error),
                    ),
                  ),
                ] else if (snapshot.connectionState == ConnectionState.waiting) ...[
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: asmrBlue),
                      ),
                    ),
                  ),
                ] else ...[
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_release_date'),
                    values: [_formatDate(i18n, effectiveWork.releaseDate)],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_duration'),
                    values: [_formatDuration(i18n, effectiveWork.duration)],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_sales'),
                    values: ['${effectiveWork.dlCount}'],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_rating'),
                    values: [effectiveWork.rating <= 0
                        ? i18n.tr('asmr_detail_unrated')
                        : effectiveWork.rating.toStringAsFixed(2)],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_reviews'),
                    values: ['${effectiveWork.reviewCount}'],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_age_rating'),
                    values: [detail?.ageCategory ?? ''],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_language_editions'),
                    values: detail?.languageEditionLabels ?? const <String>[],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val),
                  ),
                  if ((detail?.description.trim().isNotEmpty ?? false)) ...[
                    const SizedBox(height: 4),
                    _AsmrDetailDescriptionBlock(
                      label: i18n.tr('asmr_detail_description'),
                      text: detail!.description.trim(),
                      labelStyle: labelStyle,
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AsmrDetailRow extends StatelessWidget {
  const _AsmrDetailRow({
    required this.label,
    required this.values,
    required this.labelStyle,
    this.isCapsule = false,
    this.onCopy,
  });

  final String label;
  final List<String> values;
  final TextStyle? labelStyle;
  final bool isCapsule;
  final void Function(String)? onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final emptyText = context.read<AppLanguageProvider>().tr('audio_detail_empty');
    final displayValues = values.isEmpty || (values.length == 1 && values.first.isEmpty) 
        ? [emptyText]
        : values;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: labelStyle),
          const SizedBox(height: 8),
          if (isCapsule)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: displayValues.map((v) => _DetailCapsule(
                text: v,
                onLongPress: onCopy != null && v != emptyText ? () => onCopy!(v) : null,
              )).toList(),
            )
          else
            Text(
              displayValues.join('\uFF0C'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: displayValues.first == emptyText ? cs.onSurfaceVariant : cs.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailCapsule extends StatelessWidget {
  const _DetailCapsule({required this.text, this.onLongPress});

  final String text;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrDetailDescriptionBlock extends StatelessWidget {
  const _AsmrDetailDescriptionBlock({
    required this.label,
    required this.text,
    required this.labelStyle,
  });

  final String label;
  final String text;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _copyText(context, text),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: labelStyle),
                Icon(
                  Icons.copy_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurface,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _copyText(BuildContext context, String value) async {
  final text = value.trim();
  if (text.isEmpty) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) {
    return;
  }
  final asmrBlue = AppDesignTokens.of(context).asmrAccent;
  final i18n = context.read<AppLanguageProvider>();
  showAppSnackBar(
    context,
    i18n.tr('copied_to_clipboard', {'value': text}),
    tone: AppFeedbackTone.success,
    icon: Icons.copy_rounded,
    iconColor: asmrBlue,
  );
}

String _formatDate(AppLanguageProvider i18n, DateTime? value) {
  if (value == null) {
    return i18n.tr('asmr_unknown');
  }
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _formatDuration(AppLanguageProvider i18n, Duration value) {
  if (value == Duration.zero) {
    return i18n.tr('asmr_unknown');
  }
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${value.inMinutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
