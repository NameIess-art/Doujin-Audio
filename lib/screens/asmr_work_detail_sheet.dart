import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    final cs = Theme.of(context).colorScheme;
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
                        '详细信息',
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
                  '只读模式，不支持编辑或拖拽排序',
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
                      '读取作品信息失败，请稍后重试。',
                      style: TextStyle(color: cs.error),
                    ),
                  )
                else ...[
                  _AsmrDetailHero(work: effectiveWork),
                  const SizedBox(height: 20),
                  _AsmrDetailSection(
                    title: '基础信息',
                    children: [
                      _AsmrDetailRow(label: 'RJ号', value: effectiveWork.rjCode),
                      _AsmrDetailRow(label: '作品标题', value: effectiveWork.title),
                      _AsmrDetailRow(
                        label: '社团',
                        value: effectiveWork.circleName,
                      ),
                      _AsmrDetailRow(
                        label: '声优',
                        value: _joinValues(effectiveWork.voiceActors),
                      ),
                      _AsmrDetailRow(
                        label: '标签',
                        value: _joinValues(effectiveWork.tags),
                        multiline: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _AsmrDetailSection(
                    title: '统计信息',
                    children: [
                      _AsmrDetailRow(
                        label: '发售日期',
                        value: _formatDate(effectiveWork.releaseDate),
                      ),
                      _AsmrDetailRow(
                        label: '时长',
                        value: _formatDuration(effectiveWork.duration),
                      ),
                      _AsmrDetailRow(
                        label: '销量',
                        value: '${effectiveWork.dlCount}',
                      ),
                      _AsmrDetailRow(
                        label: '评分',
                        value: effectiveWork.rating <= 0
                            ? '未评分'
                            : effectiveWork.rating.toStringAsFixed(2),
                      ),
                      _AsmrDetailRow(
                        label: '评论数',
                        value: '${effectiveWork.reviewCount}',
                      ),
                      _AsmrDetailRow(
                        label: '年龄分级',
                        value: detail?.ageCategory ?? '',
                      ),
                      _AsmrDetailRow(
                        label: '语言版本',
                        value: _joinValues(
                          detail?.languageEditionLabels ?? const <String>[],
                        ),
                        multiline: true,
                      ),
                    ],
                  ),
                  if ((detail?.description.trim().isNotEmpty ?? false)) ...[
                    const SizedBox(height: 14),
                    _AsmrDetailSection(
                      title: '简介',
                      children: [
                        Text(
                          detail!.description.trim(),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                height: 1.5,
                                color: cs.onSurface.withValues(alpha: 0.88),
                              ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await controller.playWork(
                        context.read<AudioProvider>(),
                        effectiveWork,
                      );
                      if (context.mounted) {
                        showAppSnackBar(
                          context,
                          '已添加到播放列表：${effectiveWork.title}',
                          tone: AppFeedbackTone.success,
                          icon: Icons.add_circle_rounded,
                        );
                      }
                    },
                    icon: const Icon(Icons.add_circle_rounded),
                    label: const Text('添加到播放列表'),
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
    final cs = Theme.of(context).colorScheme;
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
                      cs.primaryContainer,
                      cs.secondaryContainer.withValues(alpha: 0.92),
                    ],
                  ),
                ),
                child: Icon(
                  Icons.graphic_eq_rounded,
                  color: cs.onPrimaryContainer,
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
                label: work.circleName.isEmpty ? '未知社团' : work.circleName,
              ),
              const SizedBox(height: 8),
              _AsmrInfoChip(
                icon: Icons.confirmation_number_rounded,
                label: work.rjCode.isEmpty ? '未提供 RJ 号' : work.rjCode,
              ),
              if (work.hasSubtitle) ...[
                const SizedBox(height: 8),
                const _AsmrInfoChip(
                  icon: Icons.subtitles_rounded,
                  label: '包含字幕',
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

class _AsmrDetailRow extends StatelessWidget {
  const _AsmrDetailRow({
    required this.label,
    required this.value,
    this.multiline = false,
  });

  final String label;
  final String value;
  final bool multiline;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.trim().isEmpty ? '未填写' : value.trim(),
            maxLines: multiline ? null : 2,
            overflow: multiline ? null : TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.primary),
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

String _joinValues(List<String> values) {
  final filtered = values.where((value) => value.trim().isNotEmpty).toList();
  return filtered.isEmpty ? '' : filtered.join('、');
}

String _formatDate(DateTime? value) {
  if (value == null) {
    return '未知';
  }
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _formatDuration(Duration value) {
  if (value == Duration.zero) {
    return '未知';
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
