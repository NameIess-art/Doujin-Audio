import 'package:flutter/material.dart';

PageRouteBuilder<T> buildAppPageRoute<T>({
  required Widget child,
  RouteSettings? settings,
  Offset beginOffset = const Offset(0, 0.032),
  Duration duration = const Duration(milliseconds: 260),
  Duration reverseDuration = const Duration(milliseconds: 200),
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.988, end: 1).animate(curved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: beginOffset,
              end: Offset.zero,
            ).animate(curved),
            child: routedChild,
          ),
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
  Duration reverseDuration = const Duration(milliseconds: 160),
}) {
  return PageRouteBuilder<T>(
    settings: settings,
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: beginOffset,
            end: Offset.zero,
          ).animate(curved),
          child: routedChild,
        ),
      );
    },
  );
}
