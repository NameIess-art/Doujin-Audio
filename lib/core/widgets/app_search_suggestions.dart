import 'dart:math' as math;

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
    this.maxExpandedItems,
    this.onClear,
    this.clearLabel = 'Clear',
  }) : assert(maxExpandedItems == null || maxExpandedItems > 0);

  final String title;

  /// Replace the list when its contents change so row measurements can be reused.
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
  final int? maxExpandedItems;
  final VoidCallback? onClear;
  final String clearLabel;

  @override
  State<AppSearchSuggestionSection> createState() =>
      _AppSearchSuggestionSectionState();
}

class _AppSearchSuggestionSectionState
    extends State<AppSearchSuggestionSection> {
  static const _gap = 8.0;
  static const _rowGap = 4.0;
  static const _chipPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 8);
  static const _labelPadding = EdgeInsets.symmetric(horizontal: 4);
  bool _expanded = false;
  List<String>? _layoutItems;
  final List<List<String>> _rows = [];
  int _itemCount = 0;
  int _nextItemIndex = 0;
  (String, double)? _pendingItem;
  int? _layoutLimit;
  double? _layoutWidth;
  TextStyle? _layoutStyle;
  TextScaler? _layoutScaler;
  TextDirection? _layoutDirection;
  Locale? _layoutLocale;
  bool _layoutComplete = false;

  bool _layout(
    double width,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
  ) {
    // Source identity avoids copying or comparing entire local directories when
    // only the selection changes. The limit is applied before any item access.
    final limit = widget.maxExpandedItems;
    final itemCount = math.min(
      limit ?? widget.items.length,
      widget.items.length,
    );
    if (_layoutWidth == width &&
        _layoutStyle == style &&
        _layoutScaler == scaler &&
        _layoutDirection == direction &&
        _layoutLocale == locale &&
        identical(_layoutItems, widget.items) &&
        _layoutLimit == limit &&
        _itemCount == itemCount) {
      return false;
    }
    _layoutWidth = width;
    _layoutStyle = style;
    _layoutScaler = scaler;
    _layoutDirection = direction;
    _layoutLocale = locale;
    _layoutItems = widget.items;
    _layoutLimit = limit;
    _itemCount = itemCount;
    _nextItemIndex = 0;
    _pendingItem = null;
    _rows.clear();
    _layoutComplete = itemCount == 0;
    _ensureRows(3);
    return true;
  }

  void _ensureRows(int count) {
    if (_layoutComplete || _rows.length >= count) return;
    final width = _layoutWidth!;
    final style = _layoutStyle!;
    final scaler = _layoutScaler!;
    // Match the rendered chip padding, with 2px reserved for its border.
    final horizontalPadding =
        _chipPadding.horizontal + _labelPadding.horizontal + 2;
    final painter = TextPainter(
      textDirection: _layoutDirection!,
      textScaler: scaler,
      locale: _layoutLocale,
      maxLines: 1,
    );
    while (_rows.length < count && !_layoutComplete) {
      final row = <String>[];
      var used = 0.0;
      while (_pendingItem != null || _nextItemIndex < _itemCount) {
        final String item;
        final double itemWidth;
        if (_pendingItem case final pending?) {
          (item, itemWidth) = pending;
          _pendingItem = null;
        } else {
          item = _layoutItems![_nextItemIndex++];
          painter.text = TextSpan(text: item, style: style);
          painter.layout();
          itemWidth = math.min(
            width,
            painter.width.ceilToDouble() + horizontalPadding,
          );
        }
        if (row.isNotEmpty && used + _gap + itemWidth > width) {
          // Keep the lookahead so expansion and scrolling measure each item
          // once, rather than measuring the entire directory on expansion.
          _pendingItem = (item, itemWidth);
          break;
        }
        if (row.isNotEmpty) used += _gap;
        row.add(item);
        used += itemWidth;
      }
      if (row.isNotEmpty) _rows.add(row);
      _layoutComplete = _pendingItem == null && _nextItemIndex == _itemCount;
    }
    painter.dispose();
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
    Widget? content;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          if (_layout(width, style, scaler, direction, locale)) content = null;
          final canExpand = !_layoutComplete || _rows.length > 3;
          final count = _expanded ? _rows.length : math.min(3, _rows.length);
          // Scroll offsets change sliver constraints every frame, but not the
          // rows. Keep their delegate so only newly visible chips are built.
          return content ??= SliverMainAxisGroup(
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
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (widget.onClear != null) ...[
                          _headerButton(
                            Icons.delete_outline_rounded,
                            widget.clearLabel,
                            widget.items.isEmpty ? null : widget.onClear,
                            accent,
                          ),
                          if (canExpand) const SizedBox(width: 8),
                        ],
                        if (canExpand)
                          _headerButton(
                            _expanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            _expanded
                                ? widget.collapseLabel
                                : widget.expandLabel,
                            () => setState(() => _expanded = !_expanded),
                            accent,
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
                itemCount: _expanded
                    ? (_layoutComplete ? _rows.length : null)
                    : count,
                itemBuilder: (context, index) {
                  _ensureRows(index + 1);
                  if (index >= _rows.length) return null;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom:
                          (_expanded
                              ? !_layoutComplete || index + 1 < _rows.length
                              : index + 1 < count)
                          ? _rowGap
                          : 0,
                    ),
                    child: Row(
                      children: [
                        for (var i = 0; i < _rows[index].length; i++) ...[
                          if (i > 0) const SizedBox(width: _gap),
                          _chip(_rows[index][i], width, cs, accent),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _headerButton(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed,
    Color accent,
  ) => SizedBox.square(
    dimension: 24,
    child: IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size.square(24),
        maximumSize: const Size.square(24),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 18),
    ),
  );

  Widget _chip(String text, double maxWidth, ColorScheme cs, Color accent) {
    final selected = widget.isSelected(text);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: InputChip(
        padding: _chipPadding,
        labelPadding: _labelPadding,
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
