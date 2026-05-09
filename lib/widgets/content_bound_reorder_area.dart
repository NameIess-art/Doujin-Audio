import 'package:flutter/material.dart';

/// Restricts a [ReorderableListView] (or any scrollable list) viewport to the
/// content area — below the header and above the bottom dock/nav bar.
///
/// This ensures that Flutter's built-in auto-scroll during drag-to-reorder
/// triggers at content-area edges rather than at absolute screen edges,
/// preventing clashes with system gestures and keeping the drag interaction
/// within the usable UI region.
///
/// The caller must adjust the list's own [ScrollView.padding] to match:
/// the top padding that was previously offset by the expanded viewport should
/// be reduced by the same amount.
///
/// Usage in a [Stack]:
/// ```dart
/// ContentBoundReorderArea(
///   headerHeight: _headerHeight,
///   bottomInset: bottomInset + 8,
///   child: ReorderableListView.builder(
///     padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
///     ...
///   ),
/// ),
/// ```
class ContentBoundReorderArea extends StatelessWidget {
  const ContentBoundReorderArea({
    super.key,
    required this.headerHeight,
    required this.bottomInset,
    required this.child,
  });

  /// The Y-coordinate of the content area top — typically the bottom edge of
  /// the page header / title bar. The list viewport starts here, so drag
  /// auto-scroll triggers at this boundary rather than higher up.
  final double headerHeight;

  /// The distance from the screen bottom to the content area bottom —
  /// typically the height of the bottom dock / nav bar / playback card.
  /// The list viewport ends here, so drag auto-scroll triggers above this line.
  final double bottomInset;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: headerHeight,
      bottom: bottomInset,
      left: 0,
      right: 0,
      child: child,
    );
  }
}
