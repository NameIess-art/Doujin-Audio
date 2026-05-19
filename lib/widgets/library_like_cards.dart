import 'package:flutter/material.dart';

import 'marquee_text.dart';

class LibraryLikeInfoLineData {
  const LibraryLikeInfoLineData(this.label, this.text, {this.lines = 1});

  final String label;
  final String text;
  final int lines;
}

class LibraryLikeFeaturedCardContent extends StatelessWidget {
  const LibraryLikeFeaturedCardContent({
    super.key,
    required this.title,
    required this.lines,
    required this.coverBuilder,
    required this.onPlay,
    this.expanded = false,
    this.showExpandIndicator = false,
    this.playTooltip = '播放',
    this.accentColor,
  });

  final String title;
  final List<LibraryLikeInfoLineData> lines;
  final Widget Function(double coverWidth) coverBuilder;
  final VoidCallback onPlay;
  final bool expanded;
  final bool showExpandIndicator;
  final String playTooltip;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w900,
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
        const infoBlockHeight = 96.0;
        const titleBlockHeight = 38.0;
        const coverWidth = infoBlockHeight * 1.25;
        return SizedBox(
          height: 140,
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  coverBuilder(coverWidth),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: infoBlockHeight,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < lines.length;
                            index++
                          ) ...[
                            if (index > 0) const SizedBox(height: 4),
                            LibraryLikeDetailInfoLine(
                              label: lines[index].label,
                              text: lines[index].text,
                              style: infoStyle,
                              loading: false,
                              lines: lines[index].lines,
                              accentColor: accentColor,
                            ),
                          ],
                        ],
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
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: onPlay,
                      visualDensity: VisualDensity.compact,
                      tooltip: playTooltip,
                      style: IconButton.styleFrom(
                        foregroundColor: accentColor ?? cs.primary,
                        minimumSize: const Size(40, 44),
                        maximumSize: const Size(40, 44),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.add_circle_rounded, size: 25),
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
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class LibraryLikeSingleAudioCardContent extends StatelessWidget {
  const LibraryLikeSingleAudioCardContent({
    super.key,
    required this.title,
    required this.lines,
    this.accentColor,
  });

  final String title;
  final List<LibraryLikeInfoLineData> lines;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w900,
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
        LibraryLikeTwoLineMarqueeText(text: title, style: titleStyle),
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
  });

  final String label;
  final String text;
  final TextStyle style;
  final bool loading;
  final int lines;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lineCount = lines.clamp(1, 2);
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 28,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: style.copyWith(
              color: accentColor ?? cs.primary,
              fontWeight: FontWeight.w900,
            ),
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
              : lineCount == 2
              ? LibraryLikeTwoLineMarqueeText(text: text, style: style)
              : MarqueeText(text: text, style: style, scrollSpeed: 24),
        ),
      ],
    );

    return SizedBox(height: lineCount == 2 ? 36 : 16, child: content);
  }
}

class LibraryLikeMarqueeLine extends StatelessWidget {
  const LibraryLikeMarqueeLine({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 16,
      child: MarqueeText(text: text, style: style, scrollSpeed: 26),
    );
  }
}

class LibraryLikeTwoLineMarqueeText extends StatelessWidget {
  const LibraryLikeTwoLineMarqueeText({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final lines = _splitLibraryLikeName(text);
    return SizedBox(
      width: double.infinity,
      height: 34,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LibraryLikeMarqueeLine(text: lines.$1, style: style),
          const SizedBox(height: 2),
          LibraryLikeMarqueeLine(text: lines.$2, style: style),
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
    if (!RegExp(r'[\s_\-\.,，、（）()\[\]【】]+').hasMatch(char)) {
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

bool shouldReserveTwoLibraryLikeInfoLines(String text) =>
    text.characters.length > 18;
