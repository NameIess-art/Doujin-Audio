import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mobile_overlay_inset.dart';
import 'page_header_inset.dart';

class DragOnlyScrollbar extends RawScrollbar {
  const DragOnlyScrollbar({
    super.key,
    super.controller,
    super.padding,
    super.thumbVisibility = true,
    required super.child,
  }) : super(interactive: true);

  @override
  RawScrollbarState<DragOnlyScrollbar> createState() =>
      _DragOnlyScrollbarState();
}

class _DragOnlyScrollbarState extends RawScrollbarState<DragOnlyScrollbar> {
  final _states = <WidgetState>{};

  // The default handler pages toward the pointer. Desktop navigation here is
  // limited to dragging the thumb, so intentionally omit that superclass action.
  @override
  // ignore: must_call_super
  void handleTrackTapDown(TapDownDetails details) {}

  @override
  void handleThumbPressStart(Offset localPosition) {
    super.handleThumbPressStart(localPosition);
    setState(() => _states.add(WidgetState.dragged));
  }

  @override
  void handleThumbPressEnd(Offset localPosition, Velocity velocity) {
    super.handleThumbPressEnd(localPosition, velocity);
    setState(() => _states.remove(WidgetState.dragged));
  }

  @override
  void handleHover(PointerHoverEvent event) {
    super.handleHover(event);
    final hovered = isPointerOverScrollbar(
      event.position,
      event.kind,
      forHover: true,
    );
    if (hovered != _states.contains(WidgetState.hovered)) {
      setState(() {
        if (hovered) {
          _states.add(WidgetState.hovered);
        } else {
          _states.remove(WidgetState.hovered);
        }
      });
    }
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    super.handleHoverExit(event);
    setState(() => _states.remove(WidgetState.hovered));
  }

  @override
  void updateScrollbarPainter() {
    super.updateScrollbarPainter();
    final theme = ScrollbarTheme.of(context);
    final mediaPadding = MediaQuery.paddingOf(context);
    final headerTop = PageHeaderInset.of(context);
    final bottomInset = MobileOverlayInset.of(context);
    final resolvedPadding = widget.padding?.resolve(Directionality.of(context));
    final effectiveTop = resolvedPadding?.top ??
        (headerTop > 0 ? headerTop : mediaPadding.top);
    final effectiveBottom = resolvedPadding?.bottom ??
        (mediaPadding.bottom + bottomInset);

    scrollbarPainter
      ..color =
          theme.thumbColor?.resolve(_states) ??
          Theme.of(context).colorScheme.outline
      ..thickness = theme.thickness?.resolve(_states) ?? 8
      ..radius = theme.radius ?? const Radius.circular(8)
      ..crossAxisMargin = theme.crossAxisMargin ?? 0
      ..mainAxisMargin = theme.mainAxisMargin ?? 0
      ..minLength = theme.minThumbLength ?? 48
      ..padding = EdgeInsets.only(
        top: effectiveTop,
        bottom: effectiveBottom,
        left: resolvedPadding?.left ?? mediaPadding.left,
        right: resolvedPadding?.right ?? mediaPadding.right,
      );
  }
}

/// A [ScrollPhysics] that limits the maximum vertical fling and ballistic
/// velocity to avoid runaway momentum scrolling and data loading stutter.
class MaxScrollVelocityPhysics extends ScrollPhysics {
  const MaxScrollVelocityPhysics({
    super.parent,
    this.maxVelocity = kDefaultMaxScrollVelocity,
  });

  /// The maximum allowed fling and ballistic velocity in logical pixels per second.
  final double maxVelocity;

  /// Default maximum scroll velocity cap.
  ///
  /// Standard Flutter [kMaxFlingVelocity] is 8000.0 px/s. Capping vertical scroll
  /// velocity to 3000.0 px/s prevents rapid swiping from overwhelming image
  /// decoding, widget construction, and data loading.
  static const double kDefaultMaxScrollVelocity = 3000.0;

  @override
  MaxScrollVelocityPhysics applyTo(ScrollPhysics? ancestor) {
    return MaxScrollVelocityPhysics(
      parent: buildParent(ancestor),
      maxVelocity: maxVelocity,
    );
  }

  @override
  double get maxFlingVelocity {
    final parentMax = parent?.maxFlingVelocity;
    if (parentMax != null) {
      return math.min(parentMax, maxVelocity);
    }
    return maxVelocity;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final effectiveVelocity = position.axis == Axis.vertical
        ? velocity.clamp(-maxVelocity, maxVelocity)
        : velocity;
    if (parent != null) {
      return parent!.createBallisticSimulation(position, effectiveVelocity);
    }
    return const ClampingScrollPhysics().createBallisticSimulation(
      position,
      effectiveVelocity,
    );
  }

  @override
  double carriedMomentum(double existingVelocity) {
    final momentum = parent?.carriedMomentum(existingVelocity) ?? 0.0;
    return momentum.clamp(-maxVelocity, maxVelocity);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;
    return other is MaxScrollVelocityPhysics &&
        other.maxVelocity == maxVelocity &&
        other.parent == parent;
  }

  @override
  int get hashCode => Object.hash(runtimeType, maxVelocity, parent);
}

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior({
    this.maxVelocity = MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity,
  });

  final double maxVelocity;

  static const ScrollPhysics defaultScrollPhysics = MaxScrollVelocityPhysics(
    parent: ClampingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    ),
  );

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return MaxScrollVelocityPhysics(
      maxVelocity: maxVelocity,
      parent: const ClampingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
    );
  }

  @override
  ScrollBehavior copyWith({
    bool? scrollbars,
    bool? overscroll,
    Set<PointerDeviceKind>? dragDevices,
    MultitouchDragStrategy? multitouchDragStrategy,
    Set<LogicalKeyboardKey>? pointerAxisModifiers,
    ScrollPhysics? physics,
    TargetPlatform? platform,
    ScrollViewKeyboardDismissBehavior? keyboardDismissBehavior,
  }) {
    final effectivePhysics = physics != null
        ? (physics is MaxScrollVelocityPhysics
            ? (physics.maxVelocity ==
                        MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity &&
                    maxVelocity !=
                        MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity
                ? MaxScrollVelocityPhysics(
                    maxVelocity: maxVelocity,
                    parent: physics.parent,
                  )
                : physics)
            : MaxScrollVelocityPhysics(
                maxVelocity: maxVelocity,
                parent: physics,
              ))
        : null;
    return super.copyWith(
      scrollbars: scrollbars,
      overscroll: overscroll,
      dragDevices: dragDevices,
      multitouchDragStrategy: multitouchDragStrategy,
      pointerAxisModifiers: pointerAxisModifiers,
      physics: effectivePhysics,
      platform: platform,
      keyboardDismissBehavior: keyboardDismissBehavior,
    );
  }

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) != Axis.vertical) {
      return child;
    }
    return DragOnlyScrollbar(
      controller: details.controller,
      thumbVisibility: defaultTargetPlatform == TargetPlatform.windows,
      child: child,
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      return child;
    }
    return StretchingOverscrollIndicator(
      axisDirection: details.direction,
      child: child,
    );
  }
}

