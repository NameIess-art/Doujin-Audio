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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              key: const ValueKey('session_detail_left_column'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final coverHeight = min(
                          constraints.maxWidth * 3 / 4,
                          max(0.0, constraints.maxHeight - padding.top),
                        );
                        final verticalSpace = max(
                          0.0,
                          (constraints.maxHeight - padding.top - coverHeight) /
                              2,
                        );
                        return SizedBox(
                          height: padding.top + verticalSpace + coverHeight,
                          child: Stack(
                            children: [
                              Padding(
                                padding: EdgeInsets.only(
                                  top: padding.top + verticalSpace,
                                ),
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  heightFactor: 1,
                                  child: AspectRatio(
                                    aspectRatio: 4 / 3,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: artwork,
                                    ),
                                  ),
                                ),
                              ),
                              if (segmentPanelExpanded)
                                Positioned.fill(
                                  top: MediaQuery.paddingOf(context).top + 6,
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
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 5),
                  RepaintBoundary(child: progress),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              key: const ValueKey('session_detail_right_column'),
              child: Padding(
                padding: EdgeInsets.only(top: padding.top),
                child: Column(
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
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
                duration: const Duration(milliseconds: 280),
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
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
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
