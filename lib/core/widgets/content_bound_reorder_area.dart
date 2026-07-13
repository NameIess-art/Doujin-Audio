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
    this.topExpansion = 0,
    this.bottomExpansion = 0,
    this.scrollController,
    this.showScrollbar = false,
    this.scrollbarMainAxisMargin = 0,
  });

  /// The Y-coordinate of the content area top — typically the bottom edge of
  /// the page header / title bar. The list viewport starts here, so drag
  /// auto-scroll triggers at this boundary rather than higher up.
  final double headerHeight;

  /// The distance from the screen bottom to the content area bottom —
  /// typically the height of the bottom dock / nav bar / playback card.
  /// The list viewport ends here, so drag auto-scroll triggers above this line.
  final double bottomInset;

  /// Extra space to extend the viewport upward, allowing auto-scroll to trigger
  /// before the dragged item reaches the visible content boundary.
  final double topExpansion;

  /// Extra space to extend the viewport downward, allowing auto-scroll to trigger
  /// before the dragged item reaches the visible content boundary.
  final double bottomExpansion;

  final Widget child;

  final ScrollController? scrollController;

  final bool showScrollbar;

  final double scrollbarMainAxisMargin;

  @override
  Widget build(BuildContext context) {
    final expandedScrollable = Positioned(
      top: -topExpansion,
      bottom: -bottomExpansion,
      left: 0,
      right: 0,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: child,
      ),
    );
    final content = Stack(
      clipBehavior: Clip.none,
      children: [expandedScrollable],
    );

    Widget buildBoundedScrollbar() {
      final mediaQuery = MediaQuery.of(context);
      // ScrollbarPainter uses the expanded viewport dimension, so consume both
      // expansions as trailing padding to keep its track inside this area.
      final scrollbarPadding = mediaQuery.padding.copyWith(
        bottom: mediaQuery.padding.bottom + topExpansion + bottomExpansion,
      );
      return MediaQuery(
        data: mediaQuery.copyWith(padding: scrollbarPadding),
        child: ScrollbarTheme(
          data: ScrollbarTheme.of(
            context,
          ).copyWith(mainAxisMargin: scrollbarMainAxisMargin),
          child: Scrollbar(
            controller: scrollController,
            child: MediaQuery(data: mediaQuery, child: content),
          ),
        ),
      );
    }

    return Positioned(
      top: headerHeight,
      bottom: bottomInset,
      left: 0,
      right: 0,
      child: showScrollbar ? buildBoundedScrollbar() : content,
    );
  }
}
