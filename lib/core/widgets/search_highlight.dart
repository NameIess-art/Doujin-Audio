import 'package:flutter/material.dart';

import '../media/search_query_utils.dart';

/// Carries the active search terms down to text widgets that highlight them.
class SearchHighlightScope extends InheritedWidget {
  SearchHighlightScope({
    super.key,
    required String query,
    required super.child,
  }) : terms = extractSearchTerms(query);

  SearchHighlightScope.withTerms({
    super.key,
    required this.terms,
    required super.child,
  });

  final List<String> terms;

  static List<String> termsOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<SearchHighlightScope>()
            ?.terms ??
        const <String>[];
  }

  @override
  bool updateShouldNotify(SearchHighlightScope oldWidget) {
    if (oldWidget.terms.length != terms.length) return true;
    for (var i = 0; i < terms.length; i++) {
      if (oldWidget.terms[i] != terms[i]) return true;
    }
    return false;
  }
}

/// Renders [text] and emphasizes every span matching the enclosing
/// [SearchHighlightScope] terms. Falls back to a plain [Text] when there is
/// nothing to highlight.
class SearchHighlightedText extends StatelessWidget {
  const SearchHighlightedText({
    super.key,
    required this.text,
    required this.style,
    this.terms,
    this.maxLines = 2,
    this.softWrap,
    this.strutStyle,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final TextStyle style;
  final List<String>? terms;
  final int maxLines;
  final bool? softWrap;
  final StrutStyle? strutStyle;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final activeTerms = terms ?? SearchHighlightScope.termsOf(context);
    final spans = activeTerms.isEmpty
        ? const <TextSpan>[]
        : _buildSpans(context, activeTerms);
    if (spans.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        softWrap: softWrap,
        strutStyle: strutStyle,
        overflow: overflow,
      );
    }
    return RichText(
      text: TextSpan(style: style, children: spans),
      maxLines: maxLines,
      softWrap: softWrap ?? true,
      strutStyle: strutStyle,
      overflow: overflow,
    );
  }

  List<TextSpan> _buildSpans(BuildContext context, List<String> activeTerms) {
    final ranges = _matchedRanges(text, activeTerms);
    if (ranges.isEmpty) return const <TextSpan>[];
    final cs = Theme.of(context).colorScheme;
    final highlightStyle = TextStyle(
      backgroundColor: cs.primary.withValues(alpha: 0.18),
      color: cs.primary,
      fontWeight: FontWeight.w900,
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.$1 > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, range.$1)));
      }
      spans.add(
        TextSpan(
          text: text.substring(range.$1, range.$2),
          style: highlightStyle,
        ),
      );
      cursor = range.$2;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }
}

/// Non-overlapping, ascending `(start, end)` offsets of every term occurrence.
List<(int, int)> _matchedRanges(String text, List<String> terms) {
  final lowerText = text.toLowerCase();
  if (lowerText.length != text.length) return const <(int, int)>[];
  final found = <(int, int)>[];
  for (final term in terms) {
    final needle = term.toLowerCase();
    if (needle.isEmpty) continue;
    var index = lowerText.indexOf(needle);
    while (index != -1) {
      found.add((index, index + needle.length));
      index = lowerText.indexOf(needle, index + needle.length);
    }
  }
  if (found.isEmpty) return const <(int, int)>[];
  found.sort((a, b) => a.$1 == b.$1 ? b.$2.compareTo(a.$2) : a.$1 - b.$1);
  final merged = <(int, int)>[found.first];
  for (final range in found.skip(1)) {
    final last = merged.last;
    if (range.$1 <= last.$2) {
      if (range.$2 > last.$2) merged[merged.length - 1] = (last.$1, range.$2);
      continue;
    }
    merged.add(range);
  }
  return merged;
}
