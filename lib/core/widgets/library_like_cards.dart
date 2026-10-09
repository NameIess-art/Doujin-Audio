import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';
import '../media/time_text_formatters.dart';
import '../translation/text_translation_service.dart';
import 'async_cover_image.dart';
import 'marquee_text.dart';
import 'search_highlight.dart';
import 'shimmer_loading.dart';
import 'horizontal_edge_fade_scroll.dart';
import 'page_translation_scope.dart';

const _libraryLikeInfoLineHeight = LibraryLikeCardMetrics.contentHeight / 5;

const double kResponsiveLibraryCardMinWidth = 420;
const double kResponsiveLibraryCardSpacing = 8;

int responsiveLibraryCardColumnCount(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth <= 0) return 1;
  final count =
      ((availableWidth + kResponsiveLibraryCardSpacing) /
              (kResponsiveLibraryCardMinWidth + kResponsiveLibraryCardSpacing))
          .floor();
  return count < 1 ? 1 : count;
}

class LibraryLikeCardMetrics {
  const LibraryLikeCardMetrics._();

  static const double coverHeight = 90;
  static const double contentHeight = coverHeight;
  static const double rootTileHeight = contentHeight + coverDistance * 2;
  static const double coverAspectRatio = kStandardCoverAspectRatio;
  static const double coverRadius = 8;
  static const double coverDistance = AppSpacing.xs;
  static const double cardRadius = coverRadius + coverDistance;
  static const double listHorizontalPadding = AppSpacing.xs;
  static const EdgeInsets rootTilePadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.xs,
  );

  static const RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(cardRadius)),
  );
}

class LibraryLikeSkeletonCard extends StatelessWidget {
  const LibraryLikeSkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    const coverWidth =
        LibraryLikeCardMetrics.coverHeight *
        LibraryLikeCardMetrics.coverAspectRatio;
    return const Card(
      margin: EdgeInsets.zero,
      shape: LibraryLikeCardMetrics.cardShape,
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: ShimmerLoader(
        child: Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox(
            height: LibraryLikeCardMetrics.contentHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerContainer(
                  width: coverWidth,
                  height: LibraryLikeCardMetrics.coverHeight,
                  borderRadius: LibraryLikeCardMetrics.coverRadius,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _SkeletonInfoLine(textWidth: double.infinity),
                      _SkeletonInfoLine(icon: true, textWidth: 110),
                      _SkeletonInfoLine(icon: true, textWidth: 140),
                      _SkeletonInfoLine(icon: true, textWidth: 160),
                      SizedBox(
                        height: _libraryLikeInfoLineHeight,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ShimmerContainer(
                            width: 140,
                            height: 9,
                            borderRadius: 4,
                          ),
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

class _SkeletonInfoLine extends StatelessWidget {
  const _SkeletonInfoLine({required this.textWidth, this.icon = false});

  final double textWidth;
  final bool icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _libraryLikeInfoLineHeight,
      child: Row(
        children: [
          if (icon) ...[
            const ShimmerContainer(width: 11, height: 11, borderRadius: 4),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ShimmerContainer(
                width: textWidth,
                height: 11,
                borderRadius: 4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LibrarySkeletonListView extends StatelessWidget {
  const LibrarySkeletonListView({
    super.key,
    required this.topInset,
    required this.bottomInset,
    this.itemCount = 5,
  });

  final double topInset;
  final double bottomInset;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = responsiveLibraryCardColumnCount(
          constraints.maxWidth,
        );
        final contentHeight = math.max(
          0.0,
          constraints.maxHeight - topInset - bottomInset,
        );
        final rowCount = math.max(
          itemCount,
          (contentHeight / LibraryLikeCardMetrics.rootTileHeight).ceil(),
        );
        return ListView.builder(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            LibraryLikeCardMetrics.listHorizontalPadding,
            topInset,
            LibraryLikeCardMetrics.listHorizontalPadding,
            bottomInset,
          ),
          itemCount: rowCount,
          itemBuilder: (context, rowIndex) => columnCount <= 1
              ? const LibraryLikeSkeletonCard()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var column = 0; column < columnCount; column++) ...[
                      if (column > 0)
                        const SizedBox(width: kResponsiveLibraryCardSpacing),
                      const Expanded(child: LibraryLikeSkeletonCard()),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class LibraryLikeInfoLineData {
  const LibraryLikeInfoLineData(
    this.label,
    this.text, {
    required this.icon,
    this.lines = 1,
    this.isSecondary = false,
  });

  static const int maxLines = 5;

  final String label;
  final String text;
  final IconData icon;
  final int lines;
  final bool isSecondary;
}

class LibraryLikeInfoMetadata {
  const LibraryLikeInfoMetadata({
    this.voiceActors = const <String>[],
    this.circleName = '',
    this.tags = const <String>[],
    this.releaseDate,
    this.rating,
  });

  final List<String> voiceActors;
  final String circleName;
  final List<String> tags;
  final DateTime? releaseDate;
  final double? rating;
}

List<LibraryLikeInfoLineData> buildLibraryLikeInfoLines({
  required LibraryLikeInfoMetadata metadata,
  required String voiceActorLabel,
  required String circleLabel,
  required String tagsLabel,
  required String releaseDateLabel,
  required String ratingLabel,
  String listSeparator = '\uFF0C',
}) {
  final result = <LibraryLikeInfoLineData>[];
  if (metadata.voiceActors.isNotEmpty) {
    result.add(
      LibraryLikeInfoLineData(
        voiceActorLabel,
        _normalizeLibraryLikeList(metadata.voiceActors).join(listSeparator),
        icon: Icons.record_voice_over_rounded,
      ),
    );
  }
  final circle = metadata.circleName.trim();
  if (circle.isNotEmpty) {
    result.add(
      LibraryLikeInfoLineData(
        circleLabel,
        circle,
        icon: Icons.storefront_outlined,
      ),
    );
  }
  if (metadata.tags.isNotEmpty) {
    result.add(
      LibraryLikeInfoLineData(
        tagsLabel,
        _normalizeLibraryLikeList(
          metadata.tags,
        ).map((tag) => tag.startsWith('#') ? tag : '#$tag').join(' '),
        icon: Icons.local_offer_rounded,
      ),
    );
  }
  final releaseDate = formatLibraryLikeDate(metadata.releaseDate);
  final rating = formatLibraryLikeRating(metadata.rating);
  if (releaseDate.isNotEmpty) {
    result.add(
      LibraryLikeInfoLineData(
        releaseDateLabel,
        releaseDate,
        icon: Icons.calendar_today_rounded,
        isSecondary: true,
      ),
    );
  }
  if (rating.isNotEmpty) {
    result.add(
      LibraryLikeInfoLineData(
        ratingLabel,
        rating,
        icon: Icons.star_rounded,
        isSecondary: true,
      ),
    );
  }
  return result;
}

String formatLibraryLikeDate(DateTime? value) {
  if (value == null) return '';
  return formatDateYmd(value);
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
    this.accentColor,
    this.trailingActions,
  });

  final String title;
  final List<LibraryLikeInfoLineData> lines;
  final Widget Function(double coverWidth) coverBuilder;
  final Color? accentColor;
  final Widget? trailingActions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      fontWeight: FontWeight.w800,
      fontSize: 14,
      color: cs.onSurface,
    );
    final infoStyle = Theme.of(context).textTheme.labelSmall!.copyWith(
      fontWeight: FontWeight.w700,
      fontSize: 11,
      color: cs.onSurface.withValues(alpha: 0.82),
    );
    final primaryLines = lines.where((line) => !line.isSecondary);
    final secondaryLines = lines.where((line) => line.isSecondary).toList();
    const coverWidth =
        LibraryLikeCardMetrics.coverHeight *
        LibraryLikeCardMetrics.coverAspectRatio;
    return MarqueePauseScope(
      isPaused: false,
      hoverToRun: defaultTargetPlatform == TargetPlatform.windows,
      child: SizedBox(
        height: LibraryLikeCardMetrics.contentHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            coverBuilder(coverWidth),
            const SizedBox(width: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: LibraryLikeCardMetrics.contentHeight,
                    ),
                    child: SizedBox(
                      width: constraints.maxWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: _libraryLikeInfoLineHeight,
                            ),
                            child: LibraryLikeScrollableText(
                              text: title,
                              style: _libraryLikeFixedLineStyle(titleStyle),
                            ),
                          ),
                          for (final line in primaryLines)
                            LibraryLikeDetailInfoLine(
                              label: line.label,
                              icon: line.icon,
                              text: line.text,
                              style: infoStyle,
                              loading: false,
                              accentColor: accentColor,
                            ),
                          _libraryLikeSecondaryInfo(
                            context,
                            secondaryLines,
                            trailingActions: trailingActions,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _libraryLikeSecondaryInfo(
  BuildContext context,
  List<LibraryLikeInfoLineData> lines, {
  Widget? trailingActions,
}) {
  final color = Theme.of(
    context,
  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6);
  final style = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: color,
  );
  return SizedBox(
    height: _libraryLikeInfoLineHeight,
    child: Align(
      alignment: Alignment.bottomRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lines.isNotEmpty)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < lines.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Tooltip(
                        message: lines[i].label,
                        child: Icon(lines[i].icon, size: 12, color: color),
                      ),
                      const SizedBox(width: 4),
                      SearchHighlightedText(
                        text: lines[i].text,
                        maxLines: 1,
                        style: style,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (trailingActions != null) ...[
            if (lines.isNotEmpty) const SizedBox(width: 6),
            trailingActions,
          ],
        ],
      ),
    ),
  );
}

class LibraryLikeCardActions extends StatelessWidget {
  const LibraryLikeCardActions({
    super.key,
    required this.addLabel,
    required this.playLabel,
    this.onAdd,
    this.onPlay,
  });

  final String addLabel;
  final String playLabel;
  final VoidCallback? onAdd;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      minimumSize: Size.zero,
      fixedSize: const Size(22, _libraryLikeInfoLineHeight),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onAdd,
          style: style,
          tooltip: addLabel,
          icon: const Icon(
            Icons.add_circle_rounded,
            size: _libraryLikeInfoLineHeight,
          ),
        ),
        IconButton(
          onPressed: onPlay,
          style: style,
          tooltip: playLabel,
          icon: const Icon(
            Icons.play_arrow_rounded,
            size: _libraryLikeInfoLineHeight,
          ),
        ),
      ],
    );
  }
}

class LibraryLikeScrollableText extends StatelessWidget {
  const LibraryLikeScrollableText({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final normalizedText = text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final child = SearchHighlightedText(
      text: normalizedText,
      style: style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      strutStyle: _libraryLikeFixedLineStrut(style),
    );
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return MarqueeText(
        text: normalizedText,
        style: style,
        pauseDuration: const Duration(seconds: 1),
        edgePadding: 0,
        allowManualScroll: true,
        child: child,
      );
    }
    return HorizontalEdgeFadeScroll(
      deferDragAtEdges: true,
      builder: (controller) => SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        // Empty space belongs to the enclosing card's swipe gesture.
        hitTestBehavior: HitTestBehavior.deferToChild,
        child: child,
      ),
    );
  }
}

class LibraryLikeMetadataWorkCardContent extends StatelessWidget {
  const LibraryLikeMetadataWorkCardContent({
    super.key,
    required this.title,
    this.titleFileName = false,
    required this.metadata,
    required this.voiceActorLabel,
    required this.circleLabel,
    required this.tagsLabel,
    required this.releaseDateLabel,
    required this.ratingLabel,
    required this.coverBuilder,
    this.listSeparator = '\uFF0C',
    this.loading = false,
    this.accentColor,
    this.trailingActions,
  });

  final String title;
  final bool titleFileName;
  final LibraryLikeInfoMetadata metadata;
  final String voiceActorLabel;
  final String circleLabel;
  final String tagsLabel;
  final String releaseDateLabel;
  final String ratingLabel;
  final String listSeparator;
  final bool loading;
  final Widget? trailingActions;
  final Widget Function(double coverWidth) coverBuilder;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final parts = textTranslationText(title, fileName: titleFileName);
    return WorkPageTranslationBuilder(
      texts: [
        parts.source,
        if (!loading) ...[
          ...metadata.voiceActors,
          metadata.circleName,
          ...metadata.tags,
        ],
      ],
      builder: (context, translate, _) => LibraryLikeWorkCardContent(
        title: '${translate(parts.source)}${parts.suffix}',
        lines: loading
            ? const <LibraryLikeInfoLineData>[]
            : buildLibraryLikeInfoLines(
                metadata: LibraryLikeInfoMetadata(
                  voiceActors: metadata.voiceActors.map(translate).toList(),
                  circleName: translate(metadata.circleName),
                  tags: metadata.tags.map(translate).toList(),
                  releaseDate: metadata.releaseDate,
                  rating: metadata.rating,
                ),
                voiceActorLabel: voiceActorLabel,
                circleLabel: circleLabel,
                tagsLabel: tagsLabel,
                releaseDateLabel: releaseDateLabel,
                ratingLabel: ratingLabel,
                listSeparator: listSeparator,
              ),
        coverBuilder: coverBuilder,
        accentColor: accentColor,
        trailingActions: trailingActions,
      ),
    );
  }
}

class LibraryLikeSingleAudioCardContent extends StatelessWidget {
  const LibraryLikeSingleAudioCardContent({
    super.key,
    required this.title,
    required this.lines,
    this.accentColor,
    this.trailingActions,
    this.titleLeading,
  });

  final String title;
  final List<LibraryLikeInfoLineData> lines;
  final Color? accentColor;
  final Widget? trailingActions;
  final Widget? titleLeading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 14,
          color: cs.onSurface,
        ) ??
        const TextStyle();
    final infoStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 11,
          color: cs.onSurface.withValues(alpha: 0.82),
        ) ??
        TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 11,
          color: cs.onSurface.withValues(alpha: 0.82),
        );

    return MarqueePauseScope(
      isPaused: false,
      hoverToRun: defaultTargetPlatform == TargetPlatform.windows,
      child: SizedBox(
        height: LibraryLikeCardMetrics.contentHeight,
        child: LayoutBuilder(
          builder: (context, constraints) => FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: LibraryLikeCardMetrics.contentHeight,
              ),
              child: SizedBox(
                width: constraints.maxWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: _libraryLikeInfoLineHeight,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ?titleLeading,
                          Expanded(
                            child: LibraryLikeScrollableText(
                              text: title,
                              style: _libraryLikeFixedLineStyle(titleStyle),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final line in lines.where((line) => !line.isSecondary))
                      LibraryLikeDetailInfoLine(
                        label: line.label,
                        icon: line.icon,
                        text: line.text,
                        style: infoStyle,
                        loading: false,
                        accentColor: accentColor,
                      ),
                    _libraryLikeSecondaryInfo(
                      context,
                      lines.where((line) => line.isSecondary).toList(),
                      trailingActions: trailingActions,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LibraryLikeDetailInfoLine extends StatelessWidget {
  const LibraryLikeDetailInfoLine({
    super.key,
    required this.label,
    required this.icon,
    required this.text,
    required this.style,
    required this.loading,
    this.lines = 1,
    this.accentColor,
    this.enableMarquee = true,
  });

  final String label;
  final IconData icon;
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
    final fixedStyle = _libraryLikeFixedLineStyle(
      icon == Icons.local_offer_rounded
          ? style.copyWith(
              color: Color.lerp(
                style.color,
                cs.onSurfaceVariant.withValues(alpha: 0.6),
                0.5,
              ),
            )
          : style,
    );
    Widget buildLabel(String label, IconData icon) => Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: label,
        child: Icon(icon, size: 11, color: accentColor ?? cs.primary),
      ),
    );

    Widget buildValue(String value) => loading
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
            text: value,
            style: fixedStyle,
            lines: lineCount,
            enableMarquee: enableMarquee,
          )
        : LibraryLikeScrollableText(text: value, style: fixedStyle);

    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 11,
          child: SizedBox(
            height: _libraryLikeInfoLineHeight,
            child: buildLabel(label, icon),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: buildValue(text)),
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
              height: _libraryLikeInfoLineHeight,
            ),
            LibraryLikeMarqueeLine(
              text: splitLines.$2,
              style: style,
              enableMarquee: enableMarquee,
              height: _libraryLikeInfoLineHeight,
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
    this.height = 16,
  });

  final String text;
  final TextStyle style;
  final bool enableMarquee;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: enableMarquee
          ? MarqueeText(text: text, style: style, scrollSpeed: 26)
          : SearchHighlightedText(text: text, maxLines: 1, style: style),
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
