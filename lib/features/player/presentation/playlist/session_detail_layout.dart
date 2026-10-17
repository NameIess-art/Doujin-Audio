import '../../../../core/widgets/app_transitions.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/widgets/marquee_text.dart';
import 'playlist_shared_helpers.dart';

class SessionDetailLayout extends StatelessWidget {
  const SessionDetailLayout({
    super.key,
    required this.isLandscape,
    required this.padding,
    required this.segmentPanelExpanded,
    required this.artwork,
    required this.isVideo,
    required this.title,
    required this.sessionId,
    required this.progress,
    required this.transport,
    required this.subtitle,
    required this.segmentPanelBuilder,
  });

  final bool isLandscape;
  final EdgeInsets padding;
  final bool segmentPanelExpanded;
  final Widget artwork;
  final bool isVideo;
  final String title;
  final String sessionId;
  final Widget progress;
  final Widget transport;
  final Widget subtitle;
  final Widget Function(Key key) segmentPanelBuilder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (isLandscape) {
      return Padding(
        padding: EdgeInsets.only(
          left: padding.left,
          right: padding.right,
          bottom: padding.bottom,
        ),
        child: CustomMultiChildLayout(
          key: const ValueKey('session_detail_landscape_layout'),
          delegate: _LandscapeDetailLayoutDelegate(
            topPadding: padding.top,
            segmentTop: MediaQuery.paddingOf(context).top + 6,
          ),
          children: [
            LayoutId(
              id: _LandscapeDetailSlot.artwork,
              child: Align(
                key: const ValueKey('session_detail_cover_area'),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: artwork,
                  ),
                ),
              ),
            ),
            LayoutId(
              id: _LandscapeDetailSlot.progress,
              child: RepaintBoundary(child: progress),
            ),
            if (segmentPanelExpanded)
              LayoutId(
                id: _LandscapeDetailSlot.segments,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(19),
                    topRight: Radius.circular(19),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  child: segmentPanelBuilder(
                    const ValueKey('segments_landscape'),
                  ),
                ),
              ),
            LayoutId(
              id: _LandscapeDetailSlot.details,
              child: Column(
                key: const ValueKey('session_detail_right_column'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 4,
                      right: 4,
                      bottom: 8,
                    ),
                    child: MarqueeText(
                      key: ValueKey('title_marquee_$sessionId'),
                      text: title,
                      pauseDuration: const Duration(seconds: 1),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: sessionDetailForeground(
                          cs,
                          SessionDetailForegroundLevel.strong,
                          darkFallback: cs.onSurface,
                        ),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(child: RepaintBoundary(child: subtitle)),
                  transport,
                ],
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverHeight = segmentPanelExpanded
            ? 42.0
            : (constraints.maxWidth * 3 / 4);

        return Padding(
          padding: EdgeInsets.only(top: padding.top, bottom: padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
                height: coverHeight,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!segmentPanelExpanded) artwork,
                      if (!isVideo)
                        IgnorePointer(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: 42,
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                gradient: segmentPanelExpanded
                                    ? null
                                    : LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.black.withValues(alpha: 0.0),
                                          Colors.black.withValues(alpha: 0.65),
                                        ],
                                      ),
                                color: segmentPanelExpanded
                                    ? cs.surfaceContainerHighest.withValues(
                                        alpha: 0.95,
                                      )
                                    : null,
                              ),
                              child: MarqueeText(
                                key: ValueKey('title_marquee_$sessionId'),
                                text: title,
                                pauseDuration: const Duration(seconds: 1),
                                style: Theme.of(context).textTheme.labelLarge
                                    ?.copyWith(
                                      color: segmentPanelExpanded
                                          ? sessionDetailForeground(
                                              cs,
                                              SessionDetailForegroundLevel
                                                  .medium,
                                              darkFallback: cs.onSurface
                                                  .withValues(alpha: 0.8),
                                            )
                                          : Colors.white.withValues(
                                              alpha: 0.85,
                                            ),
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(child: RepaintBoundary(child: subtitle)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: padding.left),
                child: RepaintBoundary(child: progress),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: padding.left),
                child: transport,
              ),
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : kAppFadeDuration,
                switchInCurve: kAppFadeCurve,
                switchOutCurve: kAppFadeCurve,
                transitionBuilder: (child, animation) {
                  return SizeTransition(
                    sizeFactor: animation,
                    axisAlignment: -1.0,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.0, 0.2),
                        end: Offset.zero,
                      ).animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                  );
                },
                child: segmentPanelExpanded
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: max(
                              220.0,
                              constraints.maxHeight -
                                  coverHeight -
                                  44.0 -
                                  92.0 -
                                  50.0,
                            ),
                          ),
                          child: segmentPanelBuilder(
                            const ValueKey('segments'),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('segments_closed')),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _LandscapeDetailSlot { artwork, progress, segments, details }

class _LandscapeDetailLayoutDelegate extends MultiChildLayoutDelegate {
  _LandscapeDetailLayoutDelegate({
    required this.topPadding,
    required this.segmentTop,
  });

  final double topPadding;
  final double segmentTop;

  @override
  void performLayout(Size size) {
    final columnWidth = max(0.0, (size.width - 12) / 2);
    final progressSize = layoutChild(
      _LandscapeDetailSlot.progress,
      BoxConstraints.tightFor(width: columnWidth),
    );
    final coverSpace = max(
      0.0,
      size.height - progressSize.height - 5 - topPadding,
    );
    final coverHeight = min(columnWidth * 3 / 4, coverSpace);
    final coverTop = topPadding + (coverSpace - coverHeight) / 2;
    final coverBottom = coverTop + coverHeight;

    layoutChild(
      _LandscapeDetailSlot.artwork,
      BoxConstraints.tight(Size(columnWidth, coverHeight)),
    );
    positionChild(_LandscapeDetailSlot.artwork, Offset(0, coverTop));
    positionChild(_LandscapeDetailSlot.progress, Offset(0, coverBottom + 5));

    // Both columns use the same measured content bounds, including timecodes.
    layoutChild(
      _LandscapeDetailSlot.details,
      BoxConstraints.tight(
        Size(columnWidth, coverHeight + 5 + progressSize.height),
      ),
    );
    positionChild(
      _LandscapeDetailSlot.details,
      Offset(columnWidth + 12, coverTop),
    );

    if (hasChild(_LandscapeDetailSlot.segments)) {
      layoutChild(
        _LandscapeDetailSlot.segments,
        BoxConstraints.tight(
          Size(columnWidth, max(0.0, coverBottom - segmentTop)),
        ),
      );
      positionChild(_LandscapeDetailSlot.segments, Offset(0, segmentTop));
    }
  }

  @override
  bool shouldRelayout(_LandscapeDetailLayoutDelegate oldDelegate) =>
      topPadding != oldDelegate.topPadding ||
      segmentTop != oldDelegate.segmentTop;
}
