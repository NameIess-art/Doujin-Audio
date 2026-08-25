import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../app/localization/app_language_provider.dart';
import '../domain/asmr_models.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/app_transitions.dart';
import 'asmr_download_page.dart';

Future<void> showAsmrWorkDetailSheet(BuildContext context, AsmrWork work) {
  return AppBottomSheet.show<void>(
    context: context,
    builder: (_) => _AsmrWorkDetailSheet(work: work),
  );
}

class _AsmrWorkDetailSheet extends ConsumerStatefulWidget {
  const _AsmrWorkDetailSheet({required this.work});

  final AsmrWork work;

  @override
  ConsumerState<_AsmrWorkDetailSheet> createState() =>
      _AsmrWorkDetailSheetState();
}

class _AsmrWorkDetailSheetState extends ConsumerState<_AsmrWorkDetailSheet> {
  late final Future<AsmrWorkDetail> _detailFuture;

  Future<void> _openDownloadPage(AsmrWork work) async {
    final navigator = Navigator.of(context);
    await navigator.maybePop();
    if (!navigator.mounted) return;
    await navigator.push(
      buildAppPageRoute<void>(
        context: navigator.context,
        style: AppPageTransitionStyle.sharedAxisZ,
        child: AsmrDownloadPage(work: work),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller != null) {
      _detailFuture = controller.loadWorkDetail(widget.work);
    } else {
      _detailFuture = Future.error(
        StateError('ASMR library service is not configured.'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
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
          ref.watch(coverImageResolutionProvider),
        );
        final library = ref.read(libraryFacadeProvider);
        final coverUrl = effectiveWork.preferredCoverUrl;

        return SizedBox(
          width: double.infinity,
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
                      key: const ValueKey<String>('asmr_work_detail_download'),
                      onPressed: () => _openDownloadPage(effectiveWork),
                      tooltip: i18n.tr('asmr_download_work_tooltip'),
                      icon: const Icon(Icons.download_rounded),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
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
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: kStandardCoverAspectRatio,
                    child: AsyncRemoteCoverImage(
                      url: coverUrl,
                      future: library.coverPathFutureForRemoteCover(coverUrl),
                      initialPath: library.resolvedCoverPathForRemoteCover(
                        coverUrl,
                      ),
                      retryFutureBuilder: () =>
                          library.coverPathFutureForRemoteCover(coverUrl),
                      fit: BoxFit.cover,
                      cacheWidth: coverCacheWidth,
                      useDefaultCacheWidth: coverCacheWidth != null,
                      loadingBuilder: (_) => CoverLoadingArtwork(
                        placeholder: CoverFallbackArtwork(
                          seed: effectiveWork.title,
                        ),
                      ),
                      fallbackBuilder: (_) =>
                          CoverFallbackArtwork(seed: effectiveWork.title),
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
                  onCopy: (val) => _copyText(context, val, i18n),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('audio_detail_work_title'),
                  values: [effectiveWork.title],
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val, i18n),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('asmr_circle_label'),
                  values: [effectiveWork.circleName],
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val, i18n),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('audio_detail_voice_actors'),
                  values: effectiveWork.voiceActors,
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val, i18n),
                ),
                _AsmrDetailRow(
                  label: i18n.tr('asmr_tags_label'),
                  values: effectiveWork.tags,
                  labelStyle: labelStyle,
                  isCapsule: true,
                  onCopy: (val) => _copyText(context, val, i18n),
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
                ] else if (snapshot.connectionState ==
                    ConnectionState.waiting) ...[
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: asmrBlue,
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_release_date'),
                    values: [_formatDate(i18n, effectiveWork.releaseDate)],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_duration'),
                    values: [_formatDuration(i18n, effectiveWork.duration)],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_sales'),
                    values: ['${effectiveWork.dlCount}'],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_rating'),
                    values: [
                      effectiveWork.rating <= 0
                          ? i18n.tr('asmr_detail_unrated')
                          : effectiveWork.rating.toStringAsFixed(2),
                    ],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_reviews'),
                    values: ['${effectiveWork.reviewCount}'],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_age_rating'),
                    values: [detail?.ageCategory ?? ''],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
                  ),
                  _AsmrDetailRow(
                    label: i18n.tr('asmr_detail_language_editions'),
                    values: detail?.languageEditionLabels ?? const <String>[],
                    labelStyle: labelStyle,
                    onCopy: (val) => _copyText(context, val, i18n),
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

class _AsmrDetailRow extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final emptyText = ref
        .read(appLanguageProviderInstanceProvider)
        .tr('audio_detail_empty');
    final displayValues =
        values.isEmpty || (values.length == 1 && values.first.isEmpty)
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
              children: displayValues
                  .map(
                    (v) => _DetailCapsule(
                      text: v,
                      onCopy: onCopy != null && v != emptyText
                          ? () => onCopy!(v)
                          : null,
                    ),
                  )
                  .toList(),
            )
          else
            Text(
              displayValues.join('\uFF0C'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: displayValues.first == emptyText
                    ? cs.onSurfaceVariant
                    : cs.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailCapsule extends StatelessWidget {
  const _DetailCapsule({required this.text, this.onCopy});

  final String text;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onLongPress: defaultTargetPlatform == TargetPlatform.android
            ? onCopy
            : null,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurface),
          ),
        ),
      ),
    );
  }
}

class _AsmrDetailDescriptionBlock extends ConsumerWidget {
  const _AsmrDetailDescriptionBlock({
    required this.label,
    required this.text,
    required this.labelStyle,
  });

  final String label;
  final String text;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _copyText(
        context,
        text,
        ref.read(appLanguageProviderInstanceProvider),
      ),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: labelStyle),
                Icon(Icons.copy_rounded, size: 18, color: cs.onSurfaceVariant),
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

Future<void> _copyText(
  BuildContext context,
  String value,
  AppLanguageProvider i18n,
) async {
  final text = value.trim();
  if (text.isEmpty) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) {
    return;
  }
  final asmrBlue = AppDesignTokens.of(context).asmrAccent;
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
