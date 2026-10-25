import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/page_translation_scope.dart';

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
    this.subtitleStatus,
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
  final Widget? subtitleStatus;

  // Reuse text and metadata while the sliver only changes cover geometry.
  late final Widget _title = RepaintBoundary(child: _buildTitle());
  late final Widget _rjBar = Builder(builder: _buildRjBar);
  late final Widget _coverGradient = DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withValues(alpha: 0.35 * 0.9),
          Colors.transparent,
          Colors.black.withValues(alpha: 0.85 * 0.9),
        ],
        stops: const [0.0, 0.4, 1.0],
      ),
    ),
  );

  Widget _buildTitle() => Semantics(
    button: title.isNotEmpty,
    label: title.isNotEmpty ? title : null,
    child: InkWell(
      key: const ValueKey<String>('work_detail_title_copy'),
      onTap: title.isEmpty ? null : () => onCopyMetadata(title),
      onSecondaryTap:
          title.isEmpty || defaultTargetPlatform != TargetPlatform.windows
          ? null
          : () => onCopyMetadata(title),
      onLongPress:
          title.isEmpty || defaultTargetPlatform != TargetPlatform.android
          ? null
          : () => onCopyMetadata(title),
      borderRadius: BorderRadius.circular(8),
      child: WorkPageTranslationText(
        title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.bold,
          height: 1.25,
          shadows: [
            Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1)),
          ],
        ),
      ),
    ),
  );

  Widget _buildRjBar(BuildContext context) => Container(
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
              onSecondaryTap: defaultTargetPlatform == TargetPlatform.windows
                  ? () => onCopyMetadata(rjCode)
                  : null,
              onLongPress: defaultTargetPlatform == TargetPlatform.android
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
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (subtitleStatus != null) ...[
          const SizedBox(width: 8),
          subtitleStatus!,
        ],
      ],
    ),
  );

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
    final currentCoverHeight =
        coverMaxHeight -
        (shrinkOffset).clamp(0.0, coverMaxHeight - coverMinHeight);

    return Material(
      color: surfaceColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: rjBarHeight,
            child: _rjBar,
          ),
          // Cover Image area with Gradient and Title
          Positioned(
            key: const ValueKey('work_detail_cover_bounds'),
            top: 0,
            left: 0,
            right: 0,
            height: topSafeArea + currentCoverHeight,
            // Paint after the metadata row so its opaque surface does not
            // cover the shadow along the full-width artwork's bottom edge.
            child: CoverArtworkFrame(
              borderRadius: BorderRadius.zero,
              clipBehavior: Clip.hardEdge,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  coverWidget,
                  // Gradient overlay
                  _coverGradient,
                  // Work title (max 3 lines) at the bottom of the cover
                  Positioned(left: 16, right: 16, bottom: 10, child: _title),
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
    return oldDelegate.topSafeArea != topSafeArea ||
        oldDelegate.coverMaxHeight != coverMaxHeight ||
        oldDelegate.coverMinHeight != coverMinHeight ||
        oldDelegate.rjBarHeight != rjBarHeight ||
        oldDelegate.onCopyMetadata != onCopyMetadata ||
        oldDelegate.title != title ||
        oldDelegate.rjCode != rjCode ||
        oldDelegate.circleName != circleName ||
        oldDelegate.subtitleStatus != subtitleStatus ||
        oldDelegate.coverWidget != coverWidget ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.surfaceColor != surfaceColor;
  }
}
