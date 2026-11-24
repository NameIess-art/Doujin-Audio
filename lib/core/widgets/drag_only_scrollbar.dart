import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_styles.dart';
import 'mobile_overlay_inset.dart';
import 'page_header_inset.dart';
import 'windows_smooth_scroll_controller.dart';

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
  static const _expandDuration = Duration(milliseconds: 150);
  static const double _hoverStripWidth = 14.0;
  final _states = <WidgetState>{};
  AnimationController? _expandController;

  AnimationController _ensureExpandController() {
    return _expandController ??= AnimationController(
      vsync: this,
      duration: _expandDuration,
      value: _states.isNotEmpty ? 1.0 : 0.0,
    )..addListener(() {
      if (mounted) updateScrollbarPainter();
    });
  }

  void _syncExpandAnimation() {
    final active = _states.isNotEmpty;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _expandController?.value = active ? 1.0 : 0.0;
      if (mounted) updateScrollbarPainter();
      return;
    }
    final controller = _ensureExpandController();
    if (active) {
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  @override
  void dispose() {
    _expandController?.dispose();
    _expandController = null;
    super.dispose();
  }

  // The default handler pages toward the pointer. Desktop navigation here is
  // limited to dragging the thumb, so intentionally omit that superclass action.
  @override
  // ignore: must_call_super
  void handleTrackTapDown(TapDownDetails details) {}

  @override
  void handleThumbPressStart(Offset localPosition) {
    final controller = widget.controller ?? PrimaryScrollController.maybeOf(context);
    if (controller != null && controller.positions.length == 1) {
      final position = controller.position;
      if (position.isScrollingNotifier.value) {
        position.jumpTo(position.pixels);
      }
    }
    super.handleThumbPressStart(localPosition);
    if (_states.add(WidgetState.dragged) && mounted) {
      _syncExpandAnimation();
    }
  }

  @override
  void handleThumbPressEnd(Offset localPosition, Velocity velocity) {
    super.handleThumbPressEnd(localPosition, velocity);
    if (_states.remove(WidgetState.dragged) && mounted) {
      _syncExpandAnimation();
    }
  }

  @override
  void handleHover(PointerHoverEvent event) {
    super.handleHover(event);
    final box = context.findRenderObject() as RenderBox?;
    final inHoverStrip = box != null &&
        box.hasSize &&
        (Directionality.of(context) == TextDirection.rtl
            ? event.localPosition.dx <= _hoverStripWidth
            : event.localPosition.dx >= box.size.width - _hoverStripWidth);
    final hovered =
        (inHoverStrip &&
            isPointerOverScrollbar(event.position, event.kind, forHover: true)) ||
        isPointerOverThumb(event.position, event.kind);
    if (hovered != _states.contains(WidgetState.hovered)) {
      if (hovered) {
        _states.add(WidgetState.hovered);
      } else {
        _states.remove(WidgetState.hovered);
      }
      if (mounted) _syncExpandAnimation();
    }
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    super.handleHoverExit(event);
    if (_states.remove(WidgetState.hovered) && mounted) {
      _syncExpandAnimation();
    }
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
        math.max(mediaPadding.bottom, bottomInset);

    final fallbackColor = Theme.of(context).colorScheme.outline;
    final restingColor =
        theme.thumbColor?.resolve(const <WidgetState>{}) ?? fallbackColor;
    final activeStates = _states.isEmpty
        ? const <WidgetState>{WidgetState.hovered}
        : _states;
    final activeColor = theme.thumbColor?.resolve(activeStates) ?? fallbackColor;
    final restingThickness =
        theme.thickness?.resolve(const <WidgetState>{}) ?? 8.0;
    final activeThickness = theme.thickness?.resolve(activeStates) ?? 8.0;
    final rawT = _expandController?.value ?? (_states.isNotEmpty ? 1.0 : 0.0);
    final easedT = Curves.easeOutCubic.transform(rawT.clamp(0.0, 1.0));

    scrollbarPainter
      ..color = Color.lerp(restingColor, activeColor, easedT) ?? activeColor
      ..thickness =
          lerpDouble(restingThickness, activeThickness, easedT) ??
          activeThickness
      ..radius = theme.radius ?? const Radius.circular(AppRadius.small)
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
    final controller = details.controller;
    final wrapWheel =
        defaultTargetPlatform == TargetPlatform.windows &&
        controller is WindowsSmoothScrollController;
    final scrollbarChild = axisDirectionToAxis(details.direction) == Axis.vertical
        ? DragOnlyScrollbar(
            controller: controller,
            thumbVisibility: defaultTargetPlatform == TargetPlatform.windows,
            child: child,
          )
        : child;
    if (!wrapWheel) return scrollbarChild;
    return _WindowsWheelReversalProxy(
      child: controller.handleWheelReversal(context, scrollbarChild),
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Some pages hide the scrollbar, while refreshable lists hide overscroll.
    final controller = details.controller;
    if (defaultTargetPlatform == TargetPlatform.windows &&
        controller is WindowsSmoothScrollController &&
        child is! _WindowsWheelReversalProxy) {
      child = controller.handleWheelReversal(context, child);
    }
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

class _WindowsWheelReversalProxy extends StatelessWidget {
  const _WindowsWheelReversalProxy({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

