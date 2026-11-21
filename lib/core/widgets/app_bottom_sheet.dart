import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';
import 'app_buttons.dart';
import 'app_transitions.dart';

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
    bool showDragHandle = true,
    bool enableDrag = true,
    bool isDismissible = true,
    Color? backgroundColor,
    double? elevation,
    ShapeBorder? shape,
    Clip? clipBehavior,
    AnimationStyle? sheetAnimationStyle,
  }) {
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
        showDragHandle: showDragHandle,
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
          behavior: ScrollConfiguration.of(ctx).copyWith(scrollbars: false),
          child: RepaintBoundary(child: builder(ctx)),
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
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final Key? iconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

  double _visibleOpacity = 0;

  @override
  Curve get barrierCurve => kAppFadeCurve;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final size = MediaQuery.sizeOf(context);
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final halfWidth = isWindows || size.width > size.height;
    final rawPage = super.buildPage(context, animation, secondaryAnimation);
    final page = isScrollControlled
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * 0.75),
            child: rawPage,
          )
        : rawPage;
    final constrainedPage = Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        widthFactor: halfWidth ? 0.5 : 1.0,
        child: page,
      ),
    );
    return AnimatedBuilder(
      animation: animation,
      child: constrainedPage,
      builder: (context, child) {
        // Keep the opening fade, but hold its reached opacity during dragging
        // and dismissal, including a close that interrupts the entrance.
        final openingOpacity = kAppSpringCurve.transform(animation.value);
        if (openingOpacity > _visibleOpacity) _visibleOpacity = openingOpacity;
        return Opacity(opacity: _visibleOpacity, child: child);
      },
    );
  }
}
