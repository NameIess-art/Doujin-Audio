import 'package:flutter/material.dart';

import 'app_transitions.dart';

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
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useRootNavigator: useRootNavigator,
      showDragHandle: showDragHandle,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: kAppMotionSlow,
              reverseDuration: kAppMotionStandard,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
      backgroundColor: backgroundColor,
      elevation: elevation,
      clipBehavior: clipBehavior,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: builder,
    );
  }
}
