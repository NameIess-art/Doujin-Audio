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

Widget buildCenterExpandTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Widget child,
}) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final curvedAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.fastOutSlowIn,
    reverseCurve: Curves.easeInCubic,
  );
  final opacityAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );

  return ScaleTransition(
    scale: Tween<double>(begin: 0.0, end: 1.0).animate(curvedAnimation),
    child: FadeTransition(opacity: opacityAnimation, child: child),
  );
}

class CenterScalePageTransitionsBuilder extends PageTransitionsBuilder {
  const CenterScalePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return buildCenterExpandTransition(
      context: context,
      animation: animation,
      child: child,
    );
  }
}

PageRouteBuilder<T> buildAppPageRoute<T>({
  required Widget child,
  RouteSettings? settings,
  Duration duration = const Duration(milliseconds: 240),
  Duration reverseDuration = const Duration(milliseconds: 200),
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      return buildCenterExpandTransition(
        context: context,
        animation: animation,
        child: routedChild,
      );
    },
  );
}

PageRouteBuilder<T> buildAppOverlayRoute<T>({
  required Widget child,
  RouteSettings? settings,
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
      return buildCenterExpandTransition(
        context: context,
        animation: animation,
        child: routedChild,
      );
    },
  );
}
