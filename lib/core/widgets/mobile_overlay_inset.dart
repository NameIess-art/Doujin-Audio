import 'package:flutter/widgets.dart';

class MobileOverlayInset extends InheritedWidget {
  const MobileOverlayInset({
    super.key,
    required this.bottomInset,
    this.menuOverlayKey,
    this.menuDismiss,
    required super.child,
  });

  final double bottomInset;
  final GlobalKey<OverlayState>? menuOverlayKey;
  final ValueNotifier<VoidCallback?>? menuDismiss;

  static double of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<MobileOverlayInset>();
    return scope?.bottomInset ?? 0;
  }

  static OverlayState? menuOverlayOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<MobileOverlayInset>();
    return scope?.menuOverlayKey?.currentState;
  }

  static ValueNotifier<VoidCallback?>? menuDismissOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MobileOverlayInset>()
          ?.menuDismiss;

  @override
  bool updateShouldNotify(MobileOverlayInset oldWidget) {
    return oldWidget.bottomInset != bottomInset ||
        oldWidget.menuOverlayKey != menuOverlayKey ||
        oldWidget.menuDismiss != menuDismiss;
  }
}
