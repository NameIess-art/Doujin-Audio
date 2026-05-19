import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import '../services/asmr_library_controller.dart';
import '../widgets/app_feedback.dart';

Future<void> showAsmrWorkDetailSheet(BuildContext context, AsmrWork work) {
  unawaited(context.read<AsmrLibraryController>().recordHistory(work));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AsmrWorkDetailSheet(work: work),
  );
}

class _AsmrWorkDetailSheet extends StatelessWidget {
  const _AsmrWorkDetailSheet({required this.work});

  final AsmrWork work;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return FutureBuilder<AsmrWorkDetail>(
      future: controller.loadWorkDetail(work),
      builder: (context, snapshot) {
        final detail = snapshot.data;
        final effectiveWork = detail?.work ?? work;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        i18n.tr('asmr_detail_title'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
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
                Text(
                  i18n.tr('asmr_detail_readonly_hint'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (snapshot.hasError)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      i18n.tr('asmr_detail_load_failed'),
                      style: TextStyle(color: cs.error),
                    ),
                  )
                else ...[
                  _AsmrDetailHero(work: effectiveWork),
                  const SizedBox(height: 20),
                  _AsmrDetailSection(
                    title: i18n.tr('asmr_detail_basic_info'),
                    children: [
                      _CopyableValueRow(
                        label: i18n.tr('audio_detail_rj_code'),
                        value: effectiveWork.rjCode,
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('audio_detail_work_title'),
                        value: effectiveWork.title,
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('asmr_circle_label'),
                        value: effectiveWork.circleName,
                      ),
                      _CopyableChipWrapRow(
                        label: i18n.tr('audio_detail_voice_actors'),
                        values: effectiveWork.voiceActors,
                      ),
                      _CopyableChipWrapRow(
                        label: i18n.tr('asmr_tags_label'),
                        values: effectiveWork.tags,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _AsmrDetailSection(
                    title: i18n.tr('asmr_detail_statistics'),
                    children: [
                      _CopyableValueRow(
                        label: i18n.tr('asmr_detail_release_date'),
                        value: _formatDate(i18n, effectiveWork.releaseDate),
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('asmr_detail_duration'),
                        value: _formatDuration(i18n, effectiveWork.duration),
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('asmr_detail_sales'),
                        value: '${effectiveWork.dlCount}',
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('asmr_detail_rating'),
                        value: effectiveWork.rating <= 0
                            ? i18n.tr('asmr_detail_unrated')
                            : effectiveWork.rating.toStringAsFixed(2),
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('asmr_detail_reviews'),
                        value: '${effectiveWork.reviewCount}',
                      ),
                      _CopyableValueRow(
                        label: i18n.tr('asmr_detail_age_rating'),
                        value: detail?.ageCategory ?? '',
                      ),
                      _CopyableChipWrapRow(
                        label: i18n.tr('asmr_detail_language_editions'),
                        values:
                            detail?.languageEditionLabels ?? const <String>[],
                      ),
                    ],
                  ),
                  if ((detail?.description.trim().isNotEmpty ?? false)) ...[
                    const SizedBox(height: 14),
                    _AsmrDetailSection(
                      title: i18n.tr('asmr_detail_description'),
                      children: [
                        _CopyableTextBlock(text: detail!.description.trim()),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: isDark
                          ? const Color(0xFF1E2E4A)
                          : const Color(0xFFE6F0FA),
                      foregroundColor: asmrBlue,
                    ),
                    onPressed: () async {
                      await controller.playWork(
                        context.read<AudioProvider>(),
                        effectiveWork,
                      );
                      if (context.mounted) {
                        showAppSnackBar(
                          context,
                          i18n.tr('asmr_added_to_playlist', {
                            'title': effectiveWork.title,
                          }),
                          tone: AppFeedbackTone.success,
                          icon: Icons.add_circle_rounded,
                          iconColor: asmrBlue,
                        );
                      }
                    },
                    icon: const Icon(Icons.add_circle_rounded),
                    label: Text(i18n.tr('asmr_add_to_playlist')),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AsmrDetailHero extends StatelessWidget {
  const _AsmrDetailHero({required this.work});

  final AsmrWork work;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final i18n = context.watch<AppLanguageProvider>();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: 110,
            height: 146,
            child: Image.network(
              work.mainCoverUrl.isNotEmpty ? work.mainCoverUrl : work.coverUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      isDark
                          ? const Color(0xFF16253D)
                          : const Color(0xFFE8F1FC),
                      (isDark
                              ? const Color(0xFF1A365D)
                              : const Color(0xFFD0E1FD))
                          .withValues(alpha: 0.92),
                    ],
                  ),
                ),
                child: Icon(
                  Icons.graphic_eq_rounded,
                  color: asmrBlue,
                  size: 36,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                work.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.18,
                ),
              ),
              const SizedBox(height: 10),
              _AsmrInfoChip(
                icon: Icons.album_rounded,
                label: work.circleName.isEmpty
                    ? i18n.tr('asmr_unknown_circle')
                    : work.circleName,
              ),
              const SizedBox(height: 8),
              _AsmrInfoChip(
                icon: Icons.confirmation_number_rounded,
                label: work.rjCode.isEmpty
                    ? i18n.tr('asmr_missing_rj')
                    : work.rjCode,
              ),
              if (work.hasSubtitle) ...[
                const SizedBox(height: 8),
                _AsmrInfoChip(
                  icon: Icons.subtitles_rounded,
                  label: i18n.tr('asmr_has_subtitle'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AsmrDetailSection extends StatelessWidget {
  const _AsmrDetailSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _CopyableValueRow extends StatelessWidget {
  const _CopyableValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final text = value.trim().isEmpty
        ? i18n.tr('audio_detail_empty')
        : value.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          _CopyableTextChip(text: text),
        ],
      ),
    );
  }
}

class _CopyableChipWrapRow extends StatelessWidget {
  const _CopyableChipWrapRow({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final filtered = values.where((value) => value.trim().isNotEmpty).toList();
    final i18n = context.watch<AppLanguageProvider>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if (filtered.isEmpty)
            _CopyableTextChip(text: i18n.tr('audio_detail_empty'))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in filtered) _CopyableTextChip(text: value),
              ],
            ),
        ],
      ),
    );
  }
}

class _CopyableTextBlock extends StatelessWidget {
  const _CopyableTextBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _CopyableTextChip(text: text, multiline: true, compact: false);
  }
}

class _CopyableTextChip extends StatelessWidget {
  const _CopyableTextChip({
    required this.text,
    this.multiline = false,
    this.compact = true,
  });

  final String text;
  final bool multiline;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(multiline ? 16 : 999),
      child: InkWell(
        borderRadius: BorderRadius.circular(multiline ? 16 : 999),
        onLongPress: () => _copyText(context, text),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: multiline ? 12 : 9,
          ),
          child: Text(
            text,
            maxLines: multiline ? null : 2,
            overflow: multiline ? null : TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.35,
              color: cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrInfoChip extends StatelessWidget {
  const _AsmrInfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: asmrBlue),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
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
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
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
