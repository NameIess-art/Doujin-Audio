import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';
import '../media/card_info_field.dart';
import 'async_cover_image.dart';
import 'app_feedback.dart';
import 'marquee_text.dart';
import 'search_highlight.dart';
import 'shimmer_loading.dart';

const _libraryLikeInfoLineHeight = 16.0;

class LibraryLikeCardMetrics {
  const LibraryLikeCardMetrics._();

  static const double rootTileHeight = 150;
  static const double contentHeight = 134;
  static const double compactRootTileHeight = 112;
  static const double compactContentHeight = 96;
  static const double infoBlockHeight = 90;
  static const double infoVerticalOffset = -4;
  static const double titleBlockHeight = 38;
  static const double coverAspectRatio = kStandardCoverAspectRatio;
  static const double coverRadius = 8;
  static const double cardRadius = 10;
  static const double actionButtonSize = 40;
  static const double compactActionButtonLayoutSize = 32;
  static const double listHorizontalPadding = AppSpacing.xs;
  static const EdgeInsets rootTilePadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.xs,
  );

  static const RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(cardRadius)),
  );
}

class LibraryLikeSkeletonCard extends StatelessWidget {
  const LibraryLikeSkeletonCard({super.key, this.compactCoverLayout = false});

  final bool compactCoverLayout;

  @override
  Widget build(BuildContext context) {
    if (compactCoverLayout) {
      return const _CompactLibraryLikeSkeletonCard();
    }
    const infoBlockHeight = LibraryLikeCardMetrics.infoBlockHeight;
    const titleBlockHeight = LibraryLikeCardMetrics.titleBlockHeight;
    const coverWidth =
        infoBlockHeight * LibraryLikeCardMetrics.coverAspectRatio;

    return Card(
      margin: EdgeInsets.zero,
      shape: LibraryLikeCardMetrics.cardShape,
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: SizedBox(
        height: LibraryLikeCardMetrics.rootTileHeight,
        width: double.infinity,
        child: ShimmerLoader(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const ShimmerContainer(
                      width: coverWidth,
                      height: infoBlockHeight,
                      borderRadius: LibraryLikeCardMetrics.coverRadius,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Transform.translate(
                        offset: const Offset(
                          0,
                          LibraryLikeCardMetrics.infoVerticalOffset,
                        ),
                        child: const SizedBox(
                          height: infoBlockHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SkeletonInfoLine(labelWidth: 28, textWidth: 110),
                              _SkeletonInfoLine(labelWidth: 28, textWidth: 140),
                              _SkeletonInfoLine(labelWidth: 28, textWidth: 85),
                              _SkeletonInfoLine(labelWidth: 28, textWidth: 160),
                              _SkeletonInfoLine(labelWidth: 28, textWidth: 95),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const SizedBox(
                  height: titleBlockHeight,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ShimmerContainer(height: 12, borderRadius: 4),
                            SizedBox(height: 4),
                            ShimmerContainer(
                              width: 140,
                              height: 12,
                              borderRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 8),
                      _LibraryLikeSkeletonActions(
                        actionHeight: titleBlockHeight,
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
}

class _CompactLibraryLikeSkeletonCard extends StatelessWidget {
  const _CompactLibraryLikeSkeletonCard();

  @override
  Widget build(BuildContext context) {
    const coverHeight = LibraryLikeCardMetrics.compactContentHeight;
    const coverWidth = coverHeight * LibraryLikeCardMetrics.coverAspectRatio;

    return const Card(
      margin: EdgeInsets.zero,
      shape: LibraryLikeCardMetrics.cardShape,
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: SizedBox(
        height: LibraryLikeCardMetrics.compactRootTileHeight,
        width: double.infinity,
        child: ShimmerLoader(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerContainer(
                  width: coverWidth,
                  height: coverHeight,
                  borderRadius: LibraryLikeCardMetrics.coverRadius,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ShimmerContainer(height: 12, borderRadius: 4),
                              SizedBox(height: 4),
                              ShimmerContainer(
                                width: 140,
                                height: 12,
                                borderRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        height: LibraryLikeCardMetrics.actionButtonSize,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _LibraryLikeSkeletonActions(),
                        ),
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
}

class _LibraryLikeSkeletonActions extends StatelessWidget {
  const _LibraryLikeSkeletonActions({
    this.actionHeight = LibraryLikeCardMetrics.actionButtonSize,
  });

  final double actionHeight;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: LibraryLikeCardMetrics.compactActionButtonLayoutSize,
          height: actionHeight,
          child: const Center(
            child: ShimmerContainer(width: 25, height: 25, borderRadius: 12.5),
          ),
        ),
        SizedBox(
          width: 23,
          height: actionHeight,
          child: const Padding(
            padding: EdgeInsets.only(right: 2),
            child: Center(child: ShimmerContainer(width: 16, height: 16)),
          ),
        ),
      ],
    );
  }
}

class _SkeletonInfoLine extends StatelessWidget {
  const _SkeletonInfoLine({required this.labelWidth, required this.textWidth});

  final double labelWidth;
  final double textWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _libraryLikeInfoLineHeight,
      child: Row(
        children: [
          ShimmerContainer(width: labelWidth, height: 11, borderRadius: 4),
          const SizedBox(width: 5),
          ShimmerContainer(width: textWidth, height: 11, borderRadius: 4),
        ],
      ),
    );
  }
}

class LibraryLikeInfoLineData {
  const LibraryLikeInfoLineData(this.label, this.text, {this.lines = 1});

  static const int maxLines = 6;

  final String label;
  final String text;
  final int lines;
}

class LibraryLikeInfoMetadata {
  const LibraryLikeInfoMetadata({
    this.rjCode = '',
    this.voiceActors = const <String>[],
    this.circleName = '',
    this.tags = const <String>[],
    this.releaseDate,
    this.duration,
    this.salesCount,
    this.rating,
  });

  final String rjCode;
  final List<String> voiceActors;
  final String circleName;
  final List<String> tags;
  final DateTime? releaseDate;
  final Duration? duration;
  final int? salesCount;
  final double? rating;
}

List<LibraryLikeInfoLineData> buildLibraryLikeInfoLines({
  required Iterable<CardInfoField> fields,
  required LibraryLikeInfoMetadata metadata,
  required String circleLabel,
  required String tagsLabel,
  required String releaseDateLabel,
  required String salesCountLabel,
  required String ratingLabel,
  String listSeparator = '\uFF0C',
}) {
  final selectedFields = fields.toList(growable: false);
  final result = <LibraryLikeInfoLineData>[];
  for (final field in selectedFields) {
    switch (field) {
      case CardInfoField.rjCode:
        final value = metadata.rjCode.trim();
        if (value.isNotEmpty) {
          result.add(LibraryLikeInfoLineData('RJ', value));
        }
        break;
      case CardInfoField.voiceActors:
        if (metadata.voiceActors.isNotEmpty) {
          result.add(
            LibraryLikeInfoLineData(
              'CV',
              _normalizeLibraryLikeList(
                metadata.voiceActors,
              ).join(listSeparator),
            ),
          );
        }
        break;
      case CardInfoField.circleName:
        final value = metadata.circleName.trim();
        if (value.isNotEmpty) {
          result.add(LibraryLikeInfoLineData(circleLabel, value));
        }
        break;
      case CardInfoField.tags:
        if (metadata.tags.isNotEmpty) {
          result.add(
            LibraryLikeInfoLineData(
              tagsLabel,
              _normalizeLibraryLikeList(metadata.tags).join(listSeparator),
              lines: CardInfoField.tagLineCountForSelection(
                selectedFields.length,
              ),
            ),
          );
        }
        break;
      case CardInfoField.releaseDate:
        final value = formatLibraryLikeDate(metadata.releaseDate);
        if (value.isNotEmpty) {
          result.add(LibraryLikeInfoLineData(releaseDateLabel, value));
        }
        break;

      case CardInfoField.salesCount:
        final value = metadata.salesCount;
        if (value != null && value > 0) {
          result.add(
            LibraryLikeInfoLineData(salesCountLabel, value.toString()),
          );
        }
        break;
      case CardInfoField.rating:
        final value = formatLibraryLikeRating(metadata.rating);
        if (value.isNotEmpty) {
          result.add(LibraryLikeInfoLineData(ratingLabel, value));
        }
        break;
    }
  }
  return result;
}

String formatLibraryLikeDate(DateTime? value) {
  if (value == null) return '';
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

String formatLibraryLikeRating(double? value) {
  if (value == null || value <= 0) return '';
  return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 1);
}

List<String> _normalizeLibraryLikeList(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) continue;
    result.add(trimmed);
  }
  return result;
}

class LibraryLikeWorkCardContent extends StatelessWidget {
  const LibraryLikeWorkCardContent({
    super.key,
    required this.title,
    required this.lines,
    required this.coverBuilder,
    required this.onPlay,
    required this.playTooltip,
    this.expanded = false,
    this.showExpandIndicator = false,
    this.accentColor,
    this.enableMarquee = true,
    this.enableTitleMarquee = true,
    this.playLoading = false,
    this.extraTrailing,
    this.compactCoverLayout = false,
  });

  final String title;
  final List<LibraryLikeInfoLineData> lines;
  final Widget Function(double coverWidth) coverBuilder;
  final VoidCallback onPlay;
  final bool expanded;
  final bool showExpandIndicator;
  final String playTooltip;
  final Color? accentColor;
  final bool enableMarquee;
  final bool enableTitleMarquee;
  final bool playLoading;
  final Widget? extraTrailing;
  final bool compactCoverLayout;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          height: 1.06,
          color: cs.onSurface,
        ) ??
        const TextStyle();
    final infoStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        );

    return LayoutBuilder(
      builder: (context, _) {
        const infoBlockHeight = LibraryLikeCardMetrics.infoBlockHeight;
        const titleBlockHeight = LibraryLikeCardMetrics.titleBlockHeight;
        final contentHeight = compactCoverLayout
            ? LibraryLikeCardMetrics.compactContentHeight
            : LibraryLikeCardMetrics.contentHeight;
        final coverHeight = compactCoverLayout
            ? LibraryLikeCardMetrics.compactContentHeight
            : infoBlockHeight;
        final coverWidth =
            coverHeight * LibraryLikeCardMetrics.coverAspectRatio;
        const maxInfoRows = LibraryLikeInfoLineData.maxLines;
        final visibleLines = lines.take(maxInfoRows).toList(growable: false);
        if (compactCoverLayout) {
          return SizedBox(
            height: contentHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                coverBuilder(coverWidth),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: SearchHighlightedText(
                            text: title,
                            style: titleStyle,
                            maxLines: 3,
                            softWrap: true,
                          ),
                        ),
                      ),
                      SizedBox(
                        height: LibraryLikeCardMetrics.actionButtonSize,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _buildActions(
                            context,
                            cs,
                            actionHeight:
                                LibraryLikeCardMetrics.actionButtonSize,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return SizedBox(
          height: contentHeight,
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  coverBuilder(coverWidth),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Transform.translate(
                      offset: const Offset(
                        0,
                        LibraryLikeCardMetrics.infoVerticalOffset,
                      ),
                      child: SizedBox(
                        height: infoBlockHeight,
                        child: Column(
                          children: [
                            for (final line in visibleLines)
                              LibraryLikeDetailInfoLine(
                                label: line.label,
                                text: line.text,
                                style: infoStyle,
                                loading: false,
                                lines: line.lines,
                                accentColor: accentColor,
                                enableMarquee: enableMarquee,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: titleBlockHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: LibraryLikeTwoLineMarqueeText(
                        text: title,
                        style: titleStyle,
                        enableMarquee: enableTitleMarquee,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildActions(context, cs, actionHeight: titleBlockHeight),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActions(
    BuildContext context,
    ColorScheme cs, {
    required double actionHeight,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: playLoading
              ? null
              : () {
                  unawaited(
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.tap,
                    ),
                  );
                  onPlay();
                },
          visualDensity: VisualDensity.compact,
          tooltip: playTooltip,
          style: IconButton.styleFrom(
            foregroundColor: accentColor ?? cs.primary,
            minimumSize: Size(
              LibraryLikeCardMetrics.actionButtonSize,
              actionHeight,
            ),
            maximumSize: Size(
              LibraryLikeCardMetrics.actionButtonSize,
              actionHeight,
            ),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: playLoading
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: accentColor ?? cs.primary,
                  ),
                )
              : const Icon(Icons.add_circle_rounded, size: 25),
        ),
        if (showExpandIndicator)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: IgnorePointer(
              child: AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.expand_more_rounded,
                  color: cs.onSurfaceVariant,
                  size: 21,
                ),
              ),
            ),
          ),
        ?extraTrailing,
      ],
    );
  }
}

class LibraryLikeMetadataWorkCardContent extends StatelessWidget {
  const LibraryLikeMetadataWorkCardContent({
    super.key,
    required this.title,
    required this.fields,
    required this.metadata,
    required this.circleLabel,
    required this.tagsLabel,
    required this.releaseDateLabel,
    required this.salesCountLabel,
    required this.ratingLabel,
    required this.coverBuilder,
    required this.onPlay,
    required this.playTooltip,
    this.listSeparator = '\uFF0C',
    this.loading = false,
    this.expanded = false,
    this.showExpandIndicator = false,
    this.accentColor,
    this.enableMarquee = true,
    this.enableTitleMarquee = true,
    this.playLoading = false,
    this.extraTrailing,
  });

  final String title;
  final Iterable<CardInfoField> fields;
  final LibraryLikeInfoMetadata metadata;
  final String circleLabel;
  final String tagsLabel;
  final String releaseDateLabel;
  final String salesCountLabel;
  final String ratingLabel;
  final String listSeparator;
  final bool loading;
  final Widget Function(double coverWidth) coverBuilder;
  final VoidCallback onPlay;
  final bool expanded;
  final bool showExpandIndicator;
  final String playTooltip;
  final Color? accentColor;
  final bool enableMarquee;
  final bool enableTitleMarquee;
  final bool playLoading;
  final Widget? extraTrailing;

  @override
  Widget build(BuildContext context) {
    return LibraryLikeWorkCardContent(
      title: title,
      lines: loading
          ? const <LibraryLikeInfoLineData>[]
          : buildLibraryLikeInfoLines(
              fields: fields,
              metadata: metadata,
              circleLabel: circleLabel,
              tagsLabel: tagsLabel,
              releaseDateLabel: releaseDateLabel,
              salesCountLabel: salesCountLabel,
              ratingLabel: ratingLabel,
              listSeparator: listSeparator,
            ),
      coverBuilder: coverBuilder,
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: showExpandIndicator,
      playTooltip: playTooltip,
      accentColor: accentColor,
      enableMarquee: enableMarquee,
      enableTitleMarquee: enableTitleMarquee,
      playLoading: playLoading,
      extraTrailing: extraTrailing,
      compactCoverLayout: fields.isEmpty,
    );
  }
}

class LibraryLikeSingleAudioCardContent extends StatelessWidget {
  const LibraryLikeSingleAudioCardContent({
    super.key,
    required this.title,
    required this.lines,
    this.accentColor,
    this.enableMarquee = true,
    this.enableTitleMarquee = true,
  });

  final String title;
  final List<LibraryLikeInfoLineData> lines;
  final Color? accentColor;
  final bool enableMarquee;
  final bool enableTitleMarquee;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          height: 1.06,
          color: cs.onSurface,
        ) ??
        const TextStyle();
    final infoStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          height: 1.05,
          color: cs.onSurface.withValues(alpha: 0.82),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LibraryLikeTwoLineMarqueeText(
          text: title,
          style: titleStyle,
          enableMarquee: enableTitleMarquee,
        ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i++) ...[
                if (i > 0) const SizedBox(height: 4),
                LibraryLikeDetailInfoLine(
                  label: lines[i].label,
                  text: lines[i].text,
                  style: infoStyle,
                  loading: false,
                  lines: lines[i].lines,
                  accentColor: accentColor,
                  enableMarquee: enableMarquee,
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class LibraryLikeDetailInfoLine extends StatelessWidget {
  const LibraryLikeDetailInfoLine({
    super.key,
    required this.label,
    required this.text,
    required this.style,
    required this.loading,
    this.lines = 1,
    this.accentColor,
    this.enableMarquee = true,
  });

  final String label;
  final String text;
  final TextStyle style;
  final bool loading;
  final int lines;
  final Color? accentColor;
  final bool enableMarquee;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lineCount = lines.clamp(1, LibraryLikeInfoLineData.maxLines);
    final labelStyle = style.copyWith(
      color: accentColor ?? cs.primary,
      fontWeight: FontWeight.w800,
    );
    final fixedLabelStyle = _libraryLikeFixedLineStyle(labelStyle);
    final fixedStyle = _libraryLikeFixedLineStyle(style);
    final labelWidget = enableMarquee && label.characters.length > 3
        ? MarqueeText(
            text: label,
            style: fixedLabelStyle,
            scrollSpeed: 18,
            edgePadding: 2,
          )
        : Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: fixedLabelStyle,
          );
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 28,
          child: SizedBox(
            height: _libraryLikeInfoLineHeight,
            child: labelWidget,
          ),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: loading
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    Icons.hourglass_top_rounded,
                    size: 12,
                    color: accentColor ?? cs.primary,
                  ),
                )
              : lineCount > 1
              ? _LibraryLikeMultiLineInfoText(
                  text: text,
                  style: fixedStyle,
                  lines: lineCount,
                  enableMarquee: enableMarquee,
                )
              : enableMarquee
              ? MarqueeText(text: text, style: fixedStyle, scrollSpeed: 24)
              : SearchHighlightedText(
                  text: text,
                  maxLines: 1,
                  style: fixedStyle,
                ),
        ),
      ],
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _libraryLikeInfoLineHeight),
      child: content,
    );
  }
}

class _LibraryLikeMultiLineInfoText extends StatelessWidget {
  const _LibraryLikeMultiLineInfoText({
    required this.text,
    required this.style,
    required this.lines,
    required this.enableMarquee,
  });

  final String text;
  final TextStyle style;
  final int lines;
  final bool enableMarquee;

  @override
  Widget build(BuildContext context) {
    if (lines == 2 && enableMarquee) {
      final splitLines = _splitLibraryLikeName(text);
      if (splitLines.$2.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LibraryLikeMarqueeLine(
              text: splitLines.$1,
              style: style,
              enableMarquee: enableMarquee,
            ),
            LibraryLikeMarqueeLine(
              text: splitLines.$2,
              style: style,
              enableMarquee: enableMarquee,
            ),
          ],
        );
      }
    }

    return SearchHighlightedText(
      text: text,
      maxLines: lines,
      softWrap: true,
      style: style,
      strutStyle: _libraryLikeFixedLineStrut(style),
    );
  }
}

TextStyle _libraryLikeFixedLineStyle(TextStyle style) {
  final fontSize = style.fontSize;
  if (fontSize == null || fontSize <= 0) return style;
  return style.copyWith(height: _libraryLikeInfoLineHeight / fontSize);
}

StrutStyle? _libraryLikeFixedLineStrut(TextStyle style) {
  final fontSize = style.fontSize;
  if (fontSize == null || fontSize <= 0) return null;
  return StrutStyle(
    fontSize: fontSize,
    height: _libraryLikeInfoLineHeight / fontSize,
    forceStrutHeight: true,
  );
}

class LibraryLikeMarqueeLine extends StatelessWidget {
  const LibraryLikeMarqueeLine({
    super.key,
    required this.text,
    required this.style,
    this.enableMarquee = true,
  });

  final String text;
  final TextStyle style;
  final bool enableMarquee;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 16,
      child: enableMarquee
          ? MarqueeText(text: text, style: style, scrollSpeed: 26)
          : SearchHighlightedText(text: text, maxLines: 1, style: style),
    );
  }
}

class LibraryLikeTwoLineMarqueeText extends StatelessWidget {
  const LibraryLikeTwoLineMarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.enableMarquee = true,
  });

  final String text;
  final TextStyle style;
  final bool enableMarquee;

  @override
  Widget build(BuildContext context) {
    if (!enableMarquee) {
      return SizedBox(
        width: double.infinity,
        height: 34,
        child: SearchHighlightedText(text: text, softWrap: true, style: style),
      );
    }
    final lines = _splitLibraryLikeName(text);
    return SizedBox(
      width: double.infinity,
      height: 34,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LibraryLikeMarqueeLine(
            text: lines.$1,
            style: style,
            enableMarquee: enableMarquee,
          ),
          const SizedBox(height: 2),
          LibraryLikeMarqueeLine(
            text: lines.$2,
            style: style,
            enableMarquee: enableMarquee,
          ),
        ],
      ),
    );
  }
}

(String, String) _splitLibraryLikeName(String value) {
  final text = value.trim();
  if (text.length <= 18) {
    return (text, '');
  }

  final middle = text.length ~/ 2;
  var splitIndex = middle;
  var bestDistance = text.length;
  for (var i = 1; i < text.length - 1; i++) {
    final char = text[i];
    if (!_isLibraryLikeSplitChar(char)) {
      continue;
    }
    final distance = (i - middle).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      splitIndex = i + 1;
    }
  }

  final first = text.substring(0, splitIndex).trim();
  final second = text.substring(splitIndex).trim();
  if (first.isEmpty || second.isEmpty) {
    return (text, '');
  }
  return (first, second);
}

bool _isLibraryLikeSplitChar(String char) {
  const separators = <String>{
    ' ',
    '_',
    '-',
    '.',
    ',',
    '/',
    '\uFF0C',
    '\u3001',
    '\uFF08',
    '\uFF09',
    '(',
    ')',
    '[',
    ']',
    '\u3010',
    '\u3011',
    '+',
  };
  return separators.contains(char);
}

bool shouldReserveTwoLibraryLikeInfoLines(String text) =>
    text.characters.length > 18;
