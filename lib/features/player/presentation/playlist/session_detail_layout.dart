import '../../../../core/widgets/app_transitions.dart';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/presentation/element_action_menu.dart';
import '../../../../core/widgets/horizontal_edge_fade_scroll.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../core/widgets/async_cover_image.dart';
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
    this.circleName = '',
    this.voiceActors = const [],
    this.onCopyCredit,
    required this.sessionId,
    required this.progress,
    this.primaryTransport = const SizedBox.shrink(),
    required this.transport,
    required this.subtitle,
    required this.segmentPanelBuilder,
    this.showCoverOverlays = true,
  });

  final bool isLandscape;
  final EdgeInsets padding;
  final bool segmentPanelExpanded;
  final Widget artwork;
  final bool isVideo;
  final String title;
  final String circleName;
  final List<String> voiceActors;
  final ValueChanged<String>? onCopyCredit;
  final String sessionId;
  final Widget progress;
  final Widget primaryTransport;
  final Widget transport;
  final Widget subtitle;
  final Widget Function(Key key) segmentPanelBuilder;
  final bool showCoverOverlays;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleOverArtwork = !isLandscape && !segmentPanelExpanded;
    final heading = IgnorePointer(
      ignoring: !showCoverOverlays,
      child: AnimatedOpacity(
        key: const ValueKey('session_detail_title_fade'),
        opacity: showCoverOverlays ? 1 : 0,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppFadeDuration,
        curve: kAppFadeCurve,
        child: Container(
          padding: EdgeInsets.fromLTRB(
            isLandscape ? landscapeDetailTextInset : 16,
            isLandscape ? 0 : 12,
            isLandscape ? 4 : 16,
            8,
          ),
          decoration: titleOverArtwork
              ? const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xB3000000)],
                  ),
                )
              : null,
          child: Column(
            key: ValueKey('session_detail_heading_$sessionId'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              MarqueeText(
                key: ValueKey('title_marquee_$sessionId'),
                text: title,
                pauseDuration: const Duration(seconds: 1),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: titleOverArtwork
                      ? Colors.white
                      : sessionDetailForeground(
                          cs,
                          SessionDetailForegroundLevel.strong,
                          darkFallback: cs.onSurface,
                        ),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              _buildCredits(
                context,
                Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: titleOverArtwork
                      ? Colors.white.withValues(alpha: 0.8)
                      : sessionDetailForeground(
                          cs,
                          SessionDetailForegroundLevel.muted,
                          darkFallback: cs.onSurface.withValues(alpha: 0.65),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (isLandscape) {
      return Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: CustomMultiChildLayout(
          key: const ValueKey('session_detail_landscape_layout'),
          delegate: _LandscapeDetailLayoutDelegate(
            topPadding: padding.top,
            bottomPadding: padding.bottom,
            alignCoverWithTitle:
                defaultTargetPlatform == TargetPlatform.android,
            leftFraction: defaultTargetPlatform == TargetPlatform.windows
                ? 4 / 7
                : 0.5,
          ),
          children: [
            LayoutId(
              id: _LandscapeDetailSlot.artwork,
              child: Visibility(
                visible: !segmentPanelExpanded,
                maintainState: true,
                child: Align(
                  key: const ValueKey('session_detail_cover_area'),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: CoverArtworkFrame(
                      showShadow: !isVideo,
                      borderRadius: BorderRadius.circular(16),
                      child: artwork,
                    ),
                  ),
                ),
              ),
            ),
            LayoutId(
              id: _LandscapeDetailSlot.progress,
              child: RepaintBoundary(child: progress),
            ),
            LayoutId(
              id: _LandscapeDetailSlot.primaryTransport,
              child: Align(heightFactor: 1, child: primaryTransport),
            ),
            LayoutId(
              id: _LandscapeDetailSlot.segments,
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : kAppFadeDuration,
                switchInCurve: kAppFadeCurve,
                switchOutCurve: kAppFadeCurve,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final child in previousChildren)
                      ExcludeFocus(
                        child: ExcludeSemantics(
                          child: IgnorePointer(child: child),
                        ),
                      ),
                    ?currentChild,
                  ],
                ),
                child: segmentPanelExpanded
                    ? segmentPanelBuilder(const ValueKey('segments_landscape'))
                    : null,
              ),
            ),
            LayoutId(
              id: _LandscapeDetailSlot.details,
              child: Column(
                key: const ValueKey('session_detail_right_column'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  Expanded(child: RepaintBoundary(child: subtitle)),
                  Align(alignment: Alignment.centerLeft, child: transport),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverHorizontalMargin = !isVideo && !segmentPanelExpanded
            ? 8.0
            : 0.0;
        final coverHeight = segmentPanelExpanded
            ? 0.0
            : ((constraints.maxWidth - coverHorizontalMargin * 2) * 3 / 4);

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
                margin: EdgeInsets.symmetric(horizontal: coverHorizontalMargin),
                height: coverHeight,
                width: double.infinity,
                child: CoverArtworkFrame(
                  showShadow: !isVideo && !segmentPanelExpanded,
                  borderRadius: BorderRadius.circular(16),
                  child: segmentPanelExpanded
                      ? const SizedBox.shrink()
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            artwork,
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: heading,
                            ),
                          ],
                        ),
                ),
              ),
              if (segmentPanelExpanded) heading,
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

  Widget _buildCredits(BuildContext context, TextStyle? style) {
    final circle = circleName.trim();
    final voices = voiceActors
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    Widget credit(String value, String key) {
      if (value.isEmpty) return Text('--', style: style);
      final onCopy = onCopyCredit;
      if (onCopy == null) return Text(value, style: style);
      return ElementActionMenu(
        key: ValueKey(key),
        value: value,
        onCopy: () => onCopy(value),
        child: InkWell(
          onTap: () => onCopy(value),
          borderRadius: BorderRadius.circular(4),
          hoverColor: style?.color?.withValues(alpha: 0.16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(value, style: style),
          ),
        ),
      );
    }

    return HorizontalEdgeFadeScroll(
      key: ValueKey('session_detail_credits_$sessionId'),
      builder: (controller) => SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              credit(circle, 'session_detail_circle_$sessionId'),
              Text(' / ', style: style),
              if (voices.isEmpty) Text('--', style: style),
              for (var index = 0; index < voices.length; index++) ...[
                if (index > 0) Text('、', style: style),
                credit(
                  voices[index],
                  'session_detail_voice_${sessionId}_$index',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _LandscapeDetailSlot {
  artwork,
  progress,
  primaryTransport,
  segments,
  details,
}

class _LandscapeDetailLayoutDelegate extends MultiChildLayoutDelegate {
  _LandscapeDetailLayoutDelegate({
    required this.topPadding,
    required this.bottomPadding,
    required this.alignCoverWithTitle,
    required this.leftFraction,
  });

  final double topPadding;
  final double bottomPadding;
  final bool alignCoverWithTitle;
  final double leftFraction;

  @override
  void performLayout(Size size) {
    const columnGap = 12.0;
    const menuProgressGap = 32.0;
    final availableWidth = max(0.0, size.width - columnGap);
    final leftWidth = availableWidth * leftFraction;
    final rightWidth = availableWidth - leftWidth;
    final progressSize = layoutChild(
      _LandscapeDetailSlot.progress,
      BoxConstraints.tightFor(width: leftWidth * 0.8),
    );
    final primarySize = layoutChild(
      _LandscapeDetailSlot.primaryTransport,
      BoxConstraints.tightFor(width: progressSize.width),
    );
    const coverToPrimaryMinGap = 16.0;
    const primaryToProgressGap = 4.0;
    final progressBottom = size.height - bottomPadding;
    final progressTop = progressBottom - progressSize.height;
    final primaryTop = progressTop - primarySize.height - primaryToProgressGap;
    final centerY = size.height / 2;
    // Size the centered frame first; Android extends its top to the heading.
    final coverHalfSpace = max(
      0.0,
      min(centerY - topPadding, primaryTop - coverToPrimaryMinGap - centerY),
    );
    final centeredCoverHeight = min(
      leftWidth * 3 / 4 * 0.7,
      coverHalfSpace * 2,
    );
    final centeredCoverTop = centerY - centeredCoverHeight / 2;
    final headingTop = max(topPadding, centeredCoverTop - 64);
    final coverBottom = centeredCoverTop + centeredCoverHeight;
    final coverHeight = alignCoverWithTitle
        ? min(coverBottom - headingTop, leftWidth * 3 / 4)
        : centeredCoverHeight;
    final coverTop = alignCoverWithTitle
        ? coverBottom - coverHeight
        : centeredCoverTop;
    final detailsTop = alignCoverWithTitle ? coverTop : headingTop;
    final progressLeft = (leftWidth - progressSize.width) / 2;

    layoutChild(
      _LandscapeDetailSlot.artwork,
      BoxConstraints.tight(Size(leftWidth, coverHeight)),
    );
    positionChild(_LandscapeDetailSlot.artwork, Offset(0, coverTop));
    positionChild(
      _LandscapeDetailSlot.progress,
      Offset(progressLeft, progressTop),
    );
    positionChild(
      _LandscapeDetailSlot.primaryTransport,
      Offset(progressLeft, primaryTop),
    );

    layoutChild(
      _LandscapeDetailSlot.details,
      BoxConstraints.tight(
        Size(rightWidth, max(0.0, progressBottom - detailsTop)),
      ),
    );
    positionChild(
      _LandscapeDetailSlot.details,
      Offset(leftWidth + columnGap, detailsTop),
    );

    layoutChild(
      _LandscapeDetailSlot.segments,
      BoxConstraints.tight(
        Size(
          progressSize.width,
          max(0.0, primaryTop - detailsTop - menuProgressGap),
        ),
      ),
    );
    positionChild(
      _LandscapeDetailSlot.segments,
      Offset(progressLeft, detailsTop),
    );
  }

  @override
  bool shouldRelayout(_LandscapeDetailLayoutDelegate oldDelegate) =>
      topPadding != oldDelegate.topPadding ||
      bottomPadding != oldDelegate.bottomPadding ||
      alignCoverWithTitle != oldDelegate.alignCoverWithTitle ||
      leftFraction != oldDelegate.leftFraction;
}
