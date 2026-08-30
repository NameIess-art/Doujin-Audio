import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';

class AppBottomSheet {
  /// Shows a standardized bottom sheet with a drag handle and rounded top corners.
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
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    final effectiveAnimationStyle =
        sheetAnimationStyle ??
        (MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: Duration(milliseconds: 320),
                reverseDuration: Duration(milliseconds: 250),
                curve: Curves.fastOutSlowIn,
                reverseCurve: Curves.fastOutSlowIn,
              ));

    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useRootNavigator: useRootNavigator,
      showDragHandle: showDragHandle,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      sheetAnimationStyle: effectiveAnimationStyle,
      backgroundColor: backgroundColor,
      elevation: elevation,
      clipBehavior: clipBehavior,
      constraints: BoxConstraints(maxHeight: maxHeight),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.dialog),
        ),
      ),
      builder: (ctx) => RepaintBoundary(child: builder(ctx)),
    );
  }
}
