import 'package:flutter/material.dart';

class SecondaryOverlayConfig {
  const SecondaryOverlayConfig({
    this.backgroundOpacity = 0.80,
    this.transitionDuration = const Duration(milliseconds: 160),
    this.reverseTransitionDuration = const Duration(milliseconds: 120),
    this.curve = Curves.easeOutCubic,
    this.reverseCurve = Curves.easeInCubic,
  });

  final double backgroundOpacity;
  final Duration transitionDuration;
  final Duration reverseTransitionDuration;
  final Curve curve;
  final Curve reverseCurve;

  Color scrimColor(BuildContext context, double progress) {
    return Theme.of(context).colorScheme.scrim.withValues(
      alpha: backgroundOpacity * progress.clamp(0.0, 1.0),
    );
  }
}

const kSecondaryOverlayConfig = SecondaryOverlayConfig();

PageRouteBuilder<T> buildAppPageRoute<T>({
  required Widget child,
  RouteSettings? settings,
  Offset beginOffset = const Offset(0, 0.032),
  Duration duration = const Duration(milliseconds: 240),
  Duration reverseDuration = const Duration(milliseconds: 200),
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      if (MediaQuery.disableAnimationsOf(context)) return routedChild;
      final opacityAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      );
      final offsetAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: opacityAnimation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.028),
            end: Offset.zero,
          ).animate(offsetAnimation),
          child: routedChild,
        ),
      );
    },
  );
}

PageRouteBuilder<T> buildAppOverlayRoute<T>({
  required Widget child,
  RouteSettings? settings,
  Offset beginOffset = const Offset(0, 0.024),
  Duration duration = const Duration(milliseconds: 220),
  Duration reverseDuration = const Duration(milliseconds: 180),
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      if (MediaQuery.disableAnimationsOf(context)) return routedChild;
      final opacityAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      );
      final offsetAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: opacityAnimation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.024),
            end: Offset.zero,
          ).animate(offsetAnimation),
          child: routedChild,
        ),
      );
    },
  );
}
