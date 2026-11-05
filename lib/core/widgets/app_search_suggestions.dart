import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../media/search_query_utils.dart';

/// A sliver section that folds by rendered rows, independently of item count.
class AppSearchSuggestionSection extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = accentColor ?? cs.primary;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      sliver: AppElementChipSliver(
        items: items,
        isSelected: isSelected,
        onToggle: onToggle,
        accentColor: accent,
        maxItems: maxExpandedItems,
        collapsedRows: 3,
        headerBuilder: (context, canExpand, expanded, toggle) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (onClear != null) ...[
                      _headerButton(
                        Icons.delete_outline_rounded,
                        clearLabel,
                        items.isEmpty ? null : onClear,
                        accent,
                      ),
                      if (canExpand) const SizedBox(width: 4),
                    ],
                    if (canExpand)
                      _headerButton(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        expanded ? collapseLabel : expandLabel,
                        toggle,
                        accent,
                      ),
                  ],
                ),
              ),
            ),
            if (isLoading || errorText != null || items.isEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: items.isEmpty ? 0 : 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isLoading) LinearProgressIndicator(color: accent),
                    if (errorText != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              errorText!,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          if (onRetry != null)
                            TextButton(
                              onPressed: onRetry,
                              child: Text(retryLabel),
                            ),
                        ],
                      )
                    else if (!isLoading && items.isEmpty)
                      Text(
                        emptyText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _headerButton(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed,
    Color accent,
  ) => SizedBox.square(
    // Keep the header compact while giving touch a usable target.
    dimension: 32,
    child: IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size.square(32),
        maximumSize: const Size.square(32),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 20),
    ),
  );
}

/// Builds compact element rows only as they enter the viewport.
/// Item values are stable keys; labels may differ or be duplicated.
class AppElementChipSliver extends StatefulWidget {
  const AppElementChipSliver({
    super.key,
    required this.items,
    required this.isSelected,
    required this.onToggle,
    this.labels,
    this.isEnabled,
    this.disabledHint,
    this.readOnly = false,
    this.accentColor,
    this.maxItems,
    this.collapsedRows,
    this.headerBuilder,
  }) : assert(maxItems == null || maxItems > 0),
       assert(collapsedRows == null || collapsedRows > 0);

  /// Replace lists/maps when contents change to invalidate row layout.
  final List<String> items;
  final Map<String, String>? labels;
  final bool Function(String) isSelected;
  final bool Function(String)? isEnabled;
  final ValueChanged<String> onToggle;
  final String? disabledHint;
  final bool readOnly;
  final Color? accentColor;
  final int? maxItems;
  final int? collapsedRows;
  final Widget Function(BuildContext, bool, bool, VoidCallback)? headerBuilder;

  @override
  State<AppElementChipSliver> createState() => _AppElementChipSliverState();
}

class _AppElementChipSliverState extends State<AppElementChipSliver> {
  static const _gap = 8.0;
  static const _rowGap = 8.0;
  bool _expanded = false;
  Map<String, String>? _layoutLabels;
  final _widths = <String, double>{};
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
    final limit = widget.maxItems;
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
        identical(_layoutLabels, widget.labels) &&
        _layoutLimit == limit &&
        _itemCount == itemCount) {
      return false;
    }
    if (_layoutStyle != style ||
        _layoutScaler != scaler ||
        _layoutDirection != direction ||
        _layoutLocale != locale ||
        !identical(_layoutLabels, widget.labels)) {
      _widths.clear();
    }
    _layoutLabels = widget.labels;
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
    _ensureRows(widget.collapsedRows ?? 1);
    return true;
  }

  void _ensureRows(int count) {
    if (_layoutComplete || _rows.length >= count) return;
    final width = _layoutWidth!;
    final style = _layoutStyle!;
    final scaler = _layoutScaler!;
    // Match the rendered chip padding, with 2px reserved for its border.
    const horizontalPadding = AppElementChip._paddingWidth + 2;
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
          final measured = _widths.putIfAbsent(item, () {
            painter.text = TextSpan(
              text: widget.labels?[item] ?? item,
              style: style,
            );
            painter.layout();
            return painter.width.ceilToDouble() + horizontalPadding;
          });
          itemWidth = math.min(width, measured);
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
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        if (_layout(width, style, scaler, direction, locale)) content = null;
        final collapsedRows = widget.collapsedRows;
        final expanded = collapsedRows == null || _expanded;
        final canExpand =
            collapsedRows != null &&
            (!_layoutComplete || _rows.length > collapsedRows);
        final count = expanded
            ? _rows.length
            : math.min(collapsedRows, _rows.length);
        // Scroll constraints change every frame. Reuse the delegate until inputs
        // change, so scrolling builds only newly visible chips.
        if (content != null) return content!;
        final rows = SliverList.builder(
          itemCount: expanded ? (_layoutComplete ? _rows.length : null) : count,
          itemBuilder: (context, index) {
            _ensureRows(index + 1);
            if (index >= _rows.length) return null;
            final hasNext = expanded
                ? !_layoutComplete || index + 1 < _rows.length
                : index + 1 < count;
            return Padding(
              padding: EdgeInsets.only(bottom: hasNext ? _rowGap : 0),
              child: Row(
                children: [
                  for (var i = 0; i < _rows[index].length; i++) ...[
                    if (i > 0) const SizedBox(width: _gap),
                    _chip(_rows[index][i], width, accent),
                  ],
                ],
              ),
            );
          },
        );
        final header = widget.headerBuilder;
        return content = header == null
            ? rows
            : SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: header(
                      context,
                      canExpand,
                      expanded,
                      () => setState(() => _expanded = !_expanded),
                    ),
                  ),
                  rows,
                ],
              );
      },
    );
  }

  Widget _chip(String item, double maxWidth, Color accent) {
    final enabled = widget.isEnabled?.call(item) ?? true;
    return AppElementChip(
      key: ValueKey(item),
      label: widget.labels?[item] ?? item,
      maxWidth: maxWidth,
      accentColor: accent,
      selected: widget.isSelected(item),
      disabledHint: enabled ? null : widget.disabledHint,
      muted: !enabled,
      onPressed: !enabled || widget.readOnly
          ? null
          : () => widget.onToggle(item),
    );
  }
}

/// The directories only need a label and a tap target. A full Material
/// InputChip allocates selection, avatar, delete and enable animations per item.
class AppElementChip extends StatelessWidget {
  const AppElementChip({
    super.key,
    required this.label,
    required this.maxWidth,
    required this.accentColor,
    required this.selected,
    required this.onPressed,
    this.muted = false,
    this.disabledHint,
  });

  static const _paddingWidth = 16.0;
  static const _radius = BorderRadius.all(Radius.circular(8));
  final String label;
  final double maxWidth;
  final Color accentColor;
  final bool selected;
  final VoidCallback? onPressed;
  final bool muted;
  final String? disabledHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final highlighted = selected && !muted;
    final shape = RoundedRectangleBorder(
      borderRadius: _radius,
      side: BorderSide(color: highlighted ? accentColor : cs.outlineVariant),
    );
    final chip = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, minHeight: 28),
      child: Semantics(
        button: true,
        selected: selected,
        enabled: onPressed != null,
        child: Material(
          color: muted
              ? cs.surfaceContainerHighest
              : highlighted
              ? accentColor.withValues(alpha: .16)
              : Colors.transparent,
          shape: shape,
          child: InkWell(
            onTap: onPressed,
            customBorder: shape,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _paddingWidth / 2,
                vertical: 6,
              ),
              child: Align(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  label,
                  style:
                      (ChipTheme.of(context).labelStyle ??
                              theme.textTheme.labelLarge)
                          ?.copyWith(
                            color: highlighted
                                ? accentColor
                                : cs.onSurfaceVariant,
                          ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final hint = disabledHint;
    return hint == null ? chip : Tooltip(message: hint, child: chip);
  }
}

class AppSearchElementTabs extends StatelessWidget {
  const AppSearchElementTabs({
    super.key,
    required this.draft,
    required this.matchAll,
    required this.onSelected,
    required this.translate,
  });

  final String draft;
  final bool matchAll;
  final ValueChanged<bool> onSelected;
  final String Function(String) translate;

  @override
  Widget build(BuildContext context) {
    final elements = parseSearchElements(draft);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final (all, key, count) in [
                (true, 'search_elements_all', elements?.all.length ?? 0),
                (false, 'search_elements_any', elements?.any.length ?? 0),
              ])
                ChoiceChip(
                  label: Text('${translate(key)} $count'),
                  showCheckmark: false,
                  selected: matchAll == all,
                  onSelected: (_) => onSelected(all),
                ),
            ],
          ),
          if (elements == null)
            Text(
              translate('search_elements_invalid'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
