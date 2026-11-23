import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';
import 'app_buttons.dart';
import 'app_transitions.dart';
import 'windows_smooth_scroll_controller.dart';

class AppBottomSheet {
  static const contentPadding = EdgeInsets.fromLTRB(20, 8, 20, 12);

  /// Shows a standardized bottom sheet with a drag handle and rounded top corners.
  static Duration reverseAnimationDurationOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : kAppMotionFast;

  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isScrollControlled = true,
    bool useRootNavigator = true,
    bool? showDragHandle,
    bool enableDrag = true,
    bool isDismissible = true,
    Color? backgroundColor,
    double? elevation,
    ShapeBorder? shape,
    Clip? clipBehavior,
    AnimationStyle? sheetAnimationStyle,
  }) {
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final effectiveShowDragHandle = showDragHandle ?? !isWindows;
    final effectiveAnimationStyle = MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : sheetAnimationStyle ??
              AnimationStyle(
                duration: kAppMotionStandard,
                reverseDuration: reverseAnimationDurationOf(context),
                curve: kAppSpringCurve,
                reverseCurve: Curves.easeInCubic,
              );

    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    final localizations = MaterialLocalizations.of(context);
    return navigator.push<T>(
      _AppBottomSheetRoute<T>(
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
        barrierLabel: localizations.scrimLabel,
        barrierOnTapHint: localizations.scrimOnTapHint(
          localizations.bottomSheetLabel,
        ),
        modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
        isScrollControlled: isScrollControlled,
        showDragHandle: effectiveShowDragHandle,
        enableDrag: enableDrag,
        isDismissible: isDismissible,
        sheetAnimationStyle: effectiveAnimationStyle,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shape:
            shape ??
            Theme.of(context).bottomSheetTheme.shape ??
            const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppRadius.dialog),
              ),
            ),
        clipBehavior: clipBehavior,
        constraints: const BoxConstraints(minWidth: double.infinity),
        builder: (ctx) => ScrollConfiguration(
          behavior: ScrollConfiguration.of(
            ctx,
          ).copyWith(scrollbars: isWindows),
          child: RepaintBoundary(child: builder(ctx)).withWindowsSmoothScroll(),
        ),
      ),
    );
  }
}

class AppBottomSheetHeader extends StatelessWidget {
  const AppBottomSheetHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.iconKey,
    this.showCloseButton,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final Key? iconKey;
  final bool? showCloseButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveShowClose =
        showCloseButton ??
        (defaultTargetPlatform == TargetPlatform.windows &&
            trailing == null &&
            ModalRoute.of(context) is ModalBottomSheetRoute<dynamic>);
    return Row(
      children: [
        Icon(icon, key: iconKey, size: 24, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        if (effectiveShowClose) ...[
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey<String>('app_bottom_sheet_close_button'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ],
    );
  }
}

class AppBottomSheetActions extends StatelessWidget {
  const AppBottomSheetActions({
    super.key,
    this.cancelKey,
    this.confirmKey,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
  });

  final Key? cancelKey;
  final Key? confirmKey;
  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton(
            key: cancelKey,
            onPressed: onCancel,
            child: Text(cancelLabel),
          ),
          AppPillButton(
            key: confirmKey,
            onPressed: onConfirm,
            style: FilledButton.styleFrom(
              minimumSize: const Size(72, 40),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}

class _AppBottomSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _AppBottomSheetRoute({
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
    super.showDragHandle,
    super.enableDrag,
    super.isDismissible,
    super.sheetAnimationStyle,
    super.backgroundColor,
    super.elevation,
    super.shape,
    super.clipBehavior,
    super.constraints,
  });

  final ValueNotifier<double> _visibleOpacity = ValueNotifier<double>(0);
  late final Animation<double> _visibleOpacityAnimation =
      Animation<double>.fromValueListenable(_visibleOpacity);
  Animation<double>? _trackedAnimation;
  double _lastAnimationValue = 0;

  @override
  Curve get barrierCurve => kAppFadeCurve;

  void _attachAnimation(Animation<double> animation) {
    if (identical(_trackedAnimation, animation)) return;
    _trackedAnimation?.removeListener(_syncOpeningOpacity);
    _trackedAnimation?.removeStatusListener(_handleAnimationStatus);
    _trackedAnimation = animation;
    _lastAnimationValue = animation.value;
    _syncOpeningOpacity();
    animation.addListener(_syncOpeningOpacity);
    animation.addStatusListener(_handleAnimationStatus);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _visibleOpacity.value = 1.0;
    } else if (status == AnimationStatus.dismissed) {
      // Clear any partial entrance opacity so RenderAnimatedOpacity drops its
      // offscreen OpacityLayer on dismissal.
      _visibleOpacity.value = 0.0;
    }
  }

  void _syncOpeningOpacity() {
    final animation = _trackedAnimation;
    if (animation == null) return;
    final value = animation.value;
    final status = animation.status;
    final draggedDownDuringEntrance =
        value < _lastAnimationValue &&
        status != AnimationStatus.reverse &&
        _visibleOpacity.value > 0 &&
        _visibleOpacity.value < 1;
    _lastAnimationValue = value;
    if (status == AnimationStatus.completed || draggedDownDuringEntrance) {
      _visibleOpacity.value = 1.0;
      return;
    }
    if (status == AnimationStatus.dismissed) {
      _visibleOpacity.value = 0.0;
      return;
    }
    // Keep the opening fade, and hold its reached opacity when a programmatic
    // close interrupts the entrance.
    final openingOpacity = kAppSpringCurve.transform(value);
    if (openingOpacity >= 1 - 1e-4) {
      _visibleOpacity.value = 1.0;
    } else if (openingOpacity > _visibleOpacity.value) {
      _visibleOpacity.value = openingOpacity;
    }
  }

  @override
  void dispose() {
    _trackedAnimation?.removeListener(_syncOpeningOpacity);
    _trackedAnimation?.removeStatusListener(_handleAnimationStatus);
    _trackedAnimation = null;
    _visibleOpacity.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final size = MediaQuery.sizeOf(context);
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final constrainWidth = isWindows || size.width > size.height;
    final rawPage = super.buildPage(context, animation, secondaryAnimation);
    final page = isScrollControlled
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * 0.75),
            child: rawPage,
          )
        : rawPage;
    final targetWidth = constrainWidth
        ? (size.width * 0.5)
              .clamp(math.min(420.0, size.width), math.min(600.0, size.width))
              .toDouble()
        : size.width;
    final constrainedPage = Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(width: targetWidth, child: page),
    );
    _attachAnimation(animation);
    return FadeTransition(
      opacity: _visibleOpacityAnimation,
      child: constrainedPage,
    );
  }
}
