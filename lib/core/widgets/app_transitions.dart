import 'package:flutter/material.dart';

const kPlaceholderContentTransitionDuration = Duration(milliseconds: 750);

class PlaceholderContentTransition extends StatefulWidget {
  const PlaceholderContentTransition({
    super.key,
    required this.showPlaceholder,
    required this.placeholder,
    required this.content,
  });

  final bool showPlaceholder;
  final Widget placeholder;
  final Widget content;

  @override
  State<PlaceholderContentTransition> createState() =>
      _PlaceholderContentTransitionState();
}

class _PlaceholderContentTransitionState
    extends State<PlaceholderContentTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _placeholderOpacity;
  bool _fadingPlaceholder = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kPlaceholderContentTransitionDuration,
    )..addStatusListener(_handleAnimationStatus);
    _placeholderOpacity = Tween<double>(
      begin: 1,
      end: 0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInCubic));
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed ||
        !_fadingPlaceholder ||
        !mounted) {
      return;
    }
    setState(() => _fadingPlaceholder = false);
  }

  @override
  void didUpdateWidget(covariant PlaceholderContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showPlaceholder && !widget.showPlaceholder) {
      _fadingPlaceholder = true;
      _controller.forward(from: 0);
    } else if (!oldWidget.showPlaceholder && widget.showPlaceholder) {
      _fadingPlaceholder = false;
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showPlaceholder) return widget.placeholder;
    if (!_fadingPlaceholder) return widget.content;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.content,
        IgnorePointer(
          child: FadeTransition(
            opacity: _placeholderOpacity,
            child: widget.placeholder,
          ),
        ),
      ],
    );
  }
}

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
  final opacityAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );

  return FadeTransition(opacity: opacityAnimation, child: child);
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
  Duration duration = Duration.zero,
  Duration reverseDuration = Duration.zero,
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
