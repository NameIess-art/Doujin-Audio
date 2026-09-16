import 'package:flutter/widgets.dart';

/// An inherited widget that provides the vertical top inset of the page header or title bar,
/// ensuring child scrollbars ([DragOnlyScrollbar]) start below the title bar.
class PageHeaderInset extends InheritedWidget {
  const PageHeaderInset({
    super.key,
    required this.topInset,
    required super.child,
  });

  /// The vertical top inset of the header in logical pixels.
  final double topInset;

  /// Returns the nearest [PageHeaderInset] top inset, or 0.0 if not found.
  static double of(BuildContext context) {
    return maybeOf(context) ?? 0.0;
  }

  /// Returns the nearest [PageHeaderInset] top inset, or null if not found.
  static double? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PageHeaderInset>();
    return scope?.topInset;
  }

  @override
  bool updateShouldNotify(PageHeaderInset oldWidget) {
    return oldWidget.topInset != topInset;
  }
}
