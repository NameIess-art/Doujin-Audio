import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class WorkDetailHeaderDelegate extends SliverPersistentHeaderDelegate {
  WorkDetailHeaderDelegate({
    required this.topSafeArea,
    required this.coverMaxHeight,
    required this.coverMinHeight,
    required this.rjBarHeight,
    required this.title,
    required this.rjCode,
    required this.circleName,
    required this.coverWidget,
    required this.accentColor,
    required this.surfaceColor,
    required this.onCopyMetadata,
  });

  final double topSafeArea;
  final double coverMaxHeight;
  final double coverMinHeight;
  final double rjBarHeight;
  final String title;
  final String rjCode;
  final String circleName;
  final Widget coverWidget;
  final Color accentColor;
  final Color surfaceColor;
  final ValueChanged<String> onCopyMetadata;

  @override
  double get maxExtent => topSafeArea + coverMaxHeight + rjBarHeight;

  @override
  double get minExtent => topSafeArea + coverMinHeight + rjBarHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final scrollDelta = maxExtent - minExtent;
    final progress = scrollDelta <= 0
        ? 0.0
        : (shrinkOffset / scrollDelta).clamp(0.0, 1.0);

    final currentCoverHeight =
        coverMaxHeight -
        (shrinkOffset).clamp(0.0, coverMaxHeight - coverMinHeight);

    return Material(
      color: surfaceColor,
      elevation: progress > 0.8 ? 2.0 : 0.0,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Cover Image area with Gradient and Title
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topSafeArea + currentCoverHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                coverWidget,
                // Gradient overlay
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.0, 0.4, 1.0],
                    ),
                  ),
                ),
                // Work title (max 3 lines) at the bottom of the cover
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 10,
                  child: Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: progress > 0.5 ? 15 : 17,
                      fontWeight: FontWeight.bold,
                      height: 1.25,
                      shadows: const [
                        Shadow(
                          color: Colors.black87,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // RJXXXX | 社团名 Row (Pinned at the bottom of the header, never collapsed!)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: rjBarHeight,
            child: Container(
              color: surfaceColor,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  if (rjCode.isNotEmpty) ...[
                    Semantics(
                      button: true,
                      label: rjCode,
                      child: InkWell(
                        key: const ValueKey<String>('work_detail_rj_copy'),
                        onTap: () => onCopyMetadata(rjCode),
                        onSecondaryTap:
                            defaultTargetPlatform == TargetPlatform.windows
                            ? () => onCopyMetadata(rjCode)
                            : null,
                        onLongPress:
                            defaultTargetPlatform == TargetPlatform.android
                            ? () => onCopyMetadata(rjCode)
                            : () {},
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 10,
                          ),
                          child: Text(
                            rjCode,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: accentColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '|',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    Icons.storefront_outlined,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Semantics(
                      button: circleName.isNotEmpty,
                      label: circleName.isNotEmpty ? circleName : null,
                      child: InkWell(
                        key: const ValueKey<String>('work_detail_circle_copy'),
                        onTap: circleName.isEmpty
                            ? null
                            : () => onCopyMetadata(circleName),
                        onSecondaryTap:
                            circleName.isEmpty ||
                                defaultTargetPlatform != TargetPlatform.windows
                            ? null
                            : () => onCopyMetadata(circleName),
                        onLongPress: circleName.isEmpty
                            ? null
                            : defaultTargetPlatform == TargetPlatform.android
                            ? () => onCopyMetadata(circleName)
                            : () {},
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            circleName.isNotEmpty ? circleName : '--',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant WorkDetailHeaderDelegate oldDelegate) {
    return oldDelegate.title != title ||
        oldDelegate.rjCode != rjCode ||
        oldDelegate.circleName != circleName ||
        oldDelegate.coverWidget != coverWidget ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.surfaceColor != surfaceColor;
  }
}
