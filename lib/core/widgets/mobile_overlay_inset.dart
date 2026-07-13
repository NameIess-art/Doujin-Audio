import 'package:flutter/widgets.dart';

class MobileOverlayInset extends InheritedWidget {
  const MobileOverlayInset({
    super.key,
    required this.bottomInset,
    required super.child,
  });

  final double bottomInset;

  static double of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<MobileOverlayInset>();
    return scope?.bottomInset ?? 0;
  }

  @override
  bool updateShouldNotify(MobileOverlayInset oldWidget) {
    return oldWidget.bottomInset != bottomInset;
  }
}
