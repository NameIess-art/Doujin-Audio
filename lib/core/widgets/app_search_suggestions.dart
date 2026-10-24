import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A sliver section that folds by rendered rows, independently of item count.
class AppSearchSuggestionSection extends StatefulWidget {
  const AppSearchSuggestionSection({
    super.key,
    required this.title,
    required this.items,
    required this.isSelected,
    required this.onToggle,
    required this.emptyText,
    required this.expandLabel,
    required this.collapseLabel,
    this.accentColor,
    this.isLoading = false,
    this.errorText,
    this.onRetry,
    this.retryLabel = 'Retry',
  });

  final String title;
  final List<String> items;
  final bool Function(String) isSelected;
  final ValueChanged<String> onToggle;
  final String emptyText;
  final String expandLabel;
  final String collapseLabel;
  final Color? accentColor;
  final bool isLoading;
  final String? errorText;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  State<AppSearchSuggestionSection> createState() =>
      _AppSearchSuggestionSectionState();
}

class _AppSearchSuggestionSectionState
    extends State<AppSearchSuggestionSection> {
  static const _gap = 8.0;
  static const _rowGap = 4.0;
  bool _expanded = false;
  List<String> _layoutItems = const [];
  List<List<String>> _rows = const [];
  double? _layoutWidth;
  TextStyle? _layoutStyle;
  TextScaler? _layoutScaler;
  TextDirection? _layoutDirection;
  Locale? _layoutLocale;
  bool _layoutComplete = false;

  void _layout(
    double width,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
  ) {
    if (_layoutWidth == width &&
        _layoutStyle == style &&
        _layoutScaler == scaler &&
        _layoutDirection == direction &&
        _layoutLocale == locale &&
        listEquals(_layoutItems, widget.items) &&
        (!_expanded || _layoutComplete)) {
      return;
    }
    _layoutWidth = width;
    _layoutStyle = style;
    _layoutScaler = scaler;
    _layoutDirection = direction;
    _layoutLocale = locale;
    _layoutItems = List.of(widget.items);
    final rows = <List<String>>[];
    var row = <String>[];
    var used = 0.0;
    _layoutComplete = true;
    final fontSize = style.fontSize ?? 14.0;
    final textScale = scaler.scale(fontSize) / 14.0;
    // Includes 16px chip padding, scaled label padding (16px..8px), and 2px border.
    final horizontalPadding =
        18.0 + (16.0 - 8.0 * (textScale - 1.0).clamp(0.0, 1.0));
    final painter = TextPainter(
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      maxLines: 1,
    );
    for (final item in widget.items) {
      painter.text = TextSpan(text: item, style: style);
      painter.layout();
      final itemWidth = math.min(
        width,
        painter.width.ceilToDouble() + horizontalPadding,
      );
      if (row.isNotEmpty && used + _gap + itemWidth > width) {
        rows.add(row);
        row = [];
        used = 0;
        // Only the first hidden row is needed to offer expansion. Expanded
        // sections measure the directory once and build visible rows lazily.
        if (!_expanded && rows.length == 3) {
          _layoutComplete = false;
          break;
        }
      }
      if (row.isNotEmpty) used += _gap;
      row.add(item);
      used += itemWidth;
    }
    painter.dispose();
    if (row.isNotEmpty) rows.add(row);
    _rows = rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = widget.accentColor ?? cs.primary;
    final style =
        ChipTheme.of(context).labelStyle ?? theme.textTheme.labelLarge!;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          _layout(width, style, scaler, direction, locale);
          final canExpand = !_layoutComplete || _rows.length > 3;
          final count = _expanded ? _rows.length : math.min(3, _rows.length);
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (canExpand)
                          SizedBox.square(
                            dimension: 24,
                            child: IconButton(
                              onPressed: () =>
                                  setState(() => _expanded = !_expanded),
                              tooltip: _expanded
                                  ? widget.collapseLabel
                                  : widget.expandLabel,
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              style: IconButton.styleFrom(
                                foregroundColor: accent,
                                minimumSize: const Size.square(24),
                                maximumSize: const Size.square(24),
                                padding: EdgeInsets.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: Icon(
                                _expanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 18,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.isLoading || widget.errorText != null || count == 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: count == 0 ? 0 : 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.isLoading)
                          LinearProgressIndicator(color: accent),
                        if (widget.errorText != null)
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.errorText!,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              if (widget.onRetry != null)
                                TextButton(
                                  onPressed: widget.onRetry,
                                  child: Text(widget.retryLabel),
                                ),
                            ],
                          )
                        else if (!widget.isLoading && count == 0)
                          Text(
                            widget.emptyText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              SliverList.builder(
                itemCount: count,
                itemBuilder: (context, index) => Padding(
                  padding: EdgeInsets.only(
                    bottom: index + 1 < count ? _rowGap : 0,
                  ),
                  child: Row(
                    children: [
                      for (var i = 0; i < _rows[index].length; i++) ...[
                        if (i > 0) const SizedBox(width: _gap),
                        _chip(_rows[index][i], width, cs, accent),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(String text, double maxWidth, ColorScheme cs, Color accent) {
    final selected = widget.isSelected(text);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: InputChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        showCheckmark: false,
        selected: selected,
        selectedColor: accent.withValues(alpha: 0.16),
        side: BorderSide(color: selected ? accent : cs.outlineVariant),
        labelStyle: selected ? TextStyle(color: accent) : null,
        label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        onPressed: () => widget.onToggle(text),
      ),
    );
  }
}
