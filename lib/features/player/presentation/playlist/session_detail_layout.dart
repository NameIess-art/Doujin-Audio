import '../../../../core/widgets/app_transitions.dart';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/presentation/element_action_menu.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/horizontal_edge_fade_scroll.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../core/widgets/async_cover_image.dart';
import 'playlist_progress_widgets.dart';
import 'playlist_shared_helpers.dart';
import 'playlist_transport_controls.dart';

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
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final titleOverArtwork =
        !segmentPanelExpanded && (!isLandscape || (isVideo && !isAndroid));
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
          padding: isLandscape && !titleOverArtwork
              ? const EdgeInsets.fromLTRB(landscapeDetailTextInset, 0, 4, 8)
              : const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                animateOnAndroid: true,
                edgePadding: 0,
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
    final artworkWithHeading = Stack(
      fit: StackFit.expand,
      children: [
        artwork,
        if (titleOverArtwork)
          Positioned(left: 0, right: 0, bottom: 0, child: heading),
      ],
    );
    if (isLandscape) {
      return Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: CustomMultiChildLayout(
          key: const ValueKey('session_detail_landscape_layout'),
          delegate: _LandscapeDetailLayoutDelegate(
            topPadding: padding.top,
            bottomPadding: padding.bottom,
            alignCoverWithTitle: isAndroid,
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
                      borderRadius: BorderRadius.circular(16),
                      child: artworkWithHeading,
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
                  if (!titleOverArtwork) heading,
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
        final disableAnimations = MediaQuery.disableAnimationsOf(context);
        const coverHorizontalInset = 8.0;
        final coverHorizontalMargin = segmentPanelExpanded
            ? 0.0
            : coverHorizontalInset;
        final progressHeight = SessionProgressBar.preferredHeight(context);
        final fixedControlsHeight =
            progressHeight +
            PrimaryPlaybackControls.portraitHeight +
            PlaybackSecondaryControlSurface.height;
        final expandedCoverHeight = min(
          max(0.0, (constraints.maxWidth - coverHorizontalInset * 2) * 3 / 4),
          max(
            0.0,
            constraints.maxHeight - padding.vertical - fixedControlsHeight,
          ),
        );
        final coverHeight = segmentPanelExpanded ? 0.0 : expandedCoverHeight;

        return Padding(
          padding: EdgeInsets.only(top: padding.top, bottom: padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: disableAnimations
                    ? Duration.zero
                    : kAppMotionStandard,
                curve: segmentPanelExpanded
                    ? kAppSpringCurve
                    : Curves.easeOutCubic,
                margin: EdgeInsets.symmetric(horizontal: coverHorizontalMargin),
                height: coverHeight,
                width: double.infinity,
                child: IgnorePointer(
                  ignoring: segmentPanelExpanded,
                  child: ExcludeFocus(
                    excluding: segmentPanelExpanded,
                    child: ExcludeSemantics(
                      excluding: segmentPanelExpanded,
                      child: AnimatedOpacity(
                        opacity: segmentPanelExpanded ? 0 : 1,
                        duration: disableAnimations
                            ? Duration.zero
                            : kAppMotionStandard,
                        curve: kAppFadeCurve,
                        child: CoverArtworkFrame(
                          borderRadius: BorderRadius.circular(16),
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minHeight: expandedCoverHeight,
                            maxHeight: expandedCoverHeight,
                            child: artworkWithHeading,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!titleOverArtwork) heading,
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
                    : kAppMotionStandard,
                switchInCurve: kAppSpringCurve,
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
                                  progressHeight -
                                  PrimaryPlaybackControls.portraitHeight -
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
        child: AppTextLink(
          onTap: () => onCopy(value),
          label: value,
          style: style,
          padding: const EdgeInsets.symmetric(vertical: 4),
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
  });

  final double topPadding;
  final double bottomPadding;
  final bool alignCoverWithTitle;

  @override
  void performLayout(Size size) {
    const columnGap = 12.0;
    const menuProgressGap = 32.0;
    final availableWidth = max(0.0, size.width - columnGap);
    final leftBaseWidth = availableWidth * (4 / 7);
    final progressSize = layoutChild(
      _LandscapeDetailSlot.progress,
      BoxConstraints.tightFor(width: leftBaseWidth * 0.8),
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
      leftBaseWidth * 3 / 4 * 0.7,
      coverHalfSpace * 2,
    );
    final centeredCoverTop = centerY - centeredCoverHeight / 2;
    final headingTop = max(topPadding, centeredCoverTop - 64);
    final coverBottom = centeredCoverTop + centeredCoverHeight;
    final coverHeight = alignCoverWithTitle
        ? min(coverBottom - headingTop, leftBaseWidth * 3 / 4)
        : centeredCoverHeight;
    final coverTop = alignCoverWithTitle
        ? coverBottom - coverHeight
        : centeredCoverTop;
    final detailsTop = alignCoverWithTitle ? coverTop : headingTop;
    final coverWidth = coverHeight * 4 / 3;
    // Trim the dead right-side gutter inside the left column so the right pane
    // starts right after the actual left content (cover / progress / segments).
    final leftWidth = min(leftBaseWidth, max(progressSize.width, coverWidth));
    final leftOffset = (leftBaseWidth - leftWidth) * 0.25;
    final progressLeft = leftOffset + (leftWidth - progressSize.width) / 2;
    final detailsLeft = leftOffset + leftWidth + columnGap;
    final rightWidth = max(0.0, size.width - detailsLeft);

    layoutChild(
      _LandscapeDetailSlot.artwork,
      BoxConstraints.tight(Size(leftWidth, coverHeight)),
    );
    positionChild(_LandscapeDetailSlot.artwork, Offset(leftOffset, coverTop));
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
      Offset(detailsLeft, detailsTop),
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
      alignCoverWithTitle != oldDelegate.alignCoverWithTitle;
}
