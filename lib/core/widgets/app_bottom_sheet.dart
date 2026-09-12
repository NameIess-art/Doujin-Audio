import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';

class AppBottomSheet {
  /// Shows a standardized bottom sheet with a drag handle and rounded top corners.
  static Duration reverseAnimationDurationOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 250);

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
    Clip? clipBehavior,
    AnimationStyle? sheetAnimationStyle,
  }) {
    final size = MediaQuery.sizeOf(context);
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final effectiveAnimationStyle =
        sheetAnimationStyle ??
        (MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : AnimationStyle(
                duration: const Duration(milliseconds: 320),
                reverseDuration: reverseAnimationDurationOf(context),
                curve: Curves.fastOutSlowIn,
                reverseCurve: Curves.fastOutSlowIn,
              ));

    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    final localizations = MaterialLocalizations.of(context);
    return navigator.push<T>(
      _AppBottomSheetRoute<T>(
        halfWidth: isWindows,
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
        clipBehavior: clipBehavior,
        constraints: BoxConstraints(
          minWidth: isWindows ? double.infinity : 0,
          maxHeight: size.height * 0.75,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.dialog),
          ),
        ),
        builder: (ctx) => RepaintBoundary(child: builder(ctx)),
      ),
    );
  }
}

class _AppBottomSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _AppBottomSheetRoute({
    required this.halfWidth,
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
    super.clipBehavior,
    super.constraints,
    super.shape,
  });

  final bool halfWidth;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = super.buildPage(context, animation, secondaryAnimation);
    return halfWidth
        ? FractionallySizedBox(widthFactor: 0.5, child: page)
        : page;
  }
}
