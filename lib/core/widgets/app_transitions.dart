import 'package:flutter/material.dart';

const kPlaceholderContentTransitionDuration = Duration(milliseconds: 750);
const kAppMotionFast = Duration(milliseconds: 180);
const kAppMotionStandard = Duration(milliseconds: 220);
const kAppMotionSlow = Duration(milliseconds: 300);

enum AppPageTransitionStyle { fadeThrough, sharedAxisX, sharedAxisZ }

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
  late final Animation<double> _contentOpacity;
  bool _fadingPlaceholder = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kPlaceholderContentTransitionDuration,
    )..addStatusListener(_handleAnimationStatus);
    final crossFade = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
    _contentOpacity = crossFade;
    _placeholderOpacity = ReverseAnimation(crossFade);
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
        IgnorePointer(
          child: FadeTransition(
            opacity: _contentOpacity,
            child: widget.content,
          ),
        ),
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
    this.transitionDuration = kAppMotionStandard,
    this.reverseTransitionDuration = kAppMotionFast,
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

AnimationStyle appExpansionAnimationStyle(BuildContext context) {
  if (MediaQuery.disableAnimationsOf(context)) {
    return AnimationStyle.noAnimation;
  }
  return const AnimationStyle(
    duration: kAppMotionStandard,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
}

Widget buildAppScaleFadeTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Widget child,
  double beginScale = 0.94,
  Curve curve = Curves.easeOutCubic,
  Curve reverseCurve = Curves.easeInCubic,
}) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final curved = CurvedAnimation(
    parent: animation,
    curve: curve,
    reverseCurve: reverseCurve,
  );
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: beginScale, end: 1).animate(curved),
      child: child,
    ),
  );
}

Widget buildCenterExpandTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Widget child,
}) {
  return buildAppScaleFadeTransition(
    context: context,
    animation: animation,
    child: child,
  );
}

Widget _buildSharedAxisTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
  required AppPageTransitionStyle style,
}) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  return AnimatedBuilder(
    animation: Listenable.merge([animation, secondaryAnimation]),
    child: child,
    builder: (context, child) {
      final primary = Curves.easeOutCubic.transform(animation.value);
      final secondary = Curves.easeInCubic.transform(secondaryAnimation.value);
      final isDepth = style == AppPageTransitionStyle.sharedAxisZ;
      final opacity = (primary * (1 - secondary * 0.08)).clamp(0.0, 1.0);
      final scale = isDepth
          ? (0.94 + 0.06 * primary) * (1 - secondary * 0.02)
          : 1.0;
      final dx = isDepth ? 0.0 : 24 * (1 - primary) - 8 * secondary;
      return Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..translateByDouble(dx, 0.0, 0.0, 1.0)
            ..scaleByDouble(scale, scale, 1.0, 1.0),
          child: child,
        ),
      );
    },
  );
}

Widget buildAppPageTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
  required AppPageTransitionStyle style,
}) {
  if (style == AppPageTransitionStyle.fadeThrough) {
    return buildAppScaleFadeTransition(
      context: context,
      animation: animation,
      child: child,
      beginScale: 0.92,
    );
  }
  return _buildSharedAxisTransition(
    context: context,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
    style: style,
  );
}

class AppFadeThroughIndexedStack extends StatefulWidget {
  const AppFadeThroughIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.onTransitionCompleted,
  });

  final int index;
  final List<Widget> children;
  final ValueChanged<int>? onTransitionCompleted;

  @override
  State<AppFadeThroughIndexedStack> createState() =>
      _AppFadeThroughIndexedStackState();
}

class _AppFadeThroughIndexedStackState extends State<AppFadeThroughIndexedStack>
    with SingleTickerProviderStateMixin {
  static const _transitionDuration = Duration(milliseconds: 260);
  static const _incomingOffset = 0.16;
  static const _outgoingOffset = 0.045;
  static const _outgoingOpacityFloor = 0.86;

  late final AnimationController _controller;
  late int _currentIndex;
  late int _targetIndex;
  int _transitionDirection = 1;
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.index;
    _targetIndex = widget.index;
    _controller = AnimationController(
      vsync: this,
      duration: _transitionDuration,
      reverseDuration: _transitionDuration,
    )..addStatusListener(_handleStatusChanged);
    _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant AppFadeThroughIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _targetIndex) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _currentIndex = widget.index;
      _targetIndex = widget.index;
      _isAnimating = false;
      _controller.value = 1;
      widget.onTransitionCompleted?.call(_currentIndex);
      return;
    }

    if (_isAnimating && _controller.value >= 0.5) {
      _currentIndex = _targetIndex;
    }
    _targetIndex = widget.index;
    if (_targetIndex == _currentIndex) {
      _isAnimating = false;
      _controller.value = 1;
      widget.onTransitionCompleted?.call(_currentIndex);
      return;
    }

    _transitionDirection = _targetIndex > _currentIndex ? 1 : -1;
    _isAnimating = true;
    _controller.forward(from: 0);
  }

  void _handleStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_isAnimating || !mounted) {
      return;
    }
    setState(() {
      _currentIndex = _targetIndex;
      _isAnimating = false;
    });
    widget.onTransitionCompleted?.call(_currentIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: _isAnimating,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final rawProgress = _isAnimating ? _controller.value : 1.0;
          final progress = Curves.easeOutCubic.transform(rawProgress);
          final direction = _transitionDirection.toDouble();
          final paintOrder = <int>[
            for (var index = 0; index < widget.children.length; index++)
              if (index != _currentIndex && index != _targetIndex) index,
            _currentIndex,
            if (_isAnimating && _targetIndex != _currentIndex) _targetIndex,
          ];

          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: paintOrder
                  .map((index) {
                    final isOutgoing = _isAnimating && index == _currentIndex;
                    final isIncoming = _isAnimating && index == _targetIndex;
                    final isVisible =
                        isOutgoing ||
                        isIncoming ||
                        (!_isAnimating && index == _currentIndex);

                    final translation = switch ((isOutgoing, isIncoming)) {
                      (true, _) => Offset(
                        -direction * _outgoingOffset * progress,
                        0,
                      ),
                      (_, true) => Offset(
                        direction * _incomingOffset * (1 - progress),
                        0,
                      ),
                      _ => Offset.zero,
                    };
                    final opacity = switch ((isOutgoing, isIncoming)) {
                      (true, _) => 1 - progress * (1 - _outgoingOpacityFloor),
                      (_, true) => 1.0,
                      _ => 1.0,
                    };

                    return KeyedSubtree(
                      key: ValueKey<String>('app_indexed_page_$index'),
                      child: Offstage(
                        offstage: !isVisible,
                        child: FractionalTranslation(
                          translation: translation,
                          child: Opacity(
                            opacity: opacity,
                            child: widget.children[index],
                          ),
                        ),
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          );
        },
      ),
    );
  }
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
    return buildAppPageTransition(
      context: context,
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
      style: AppPageTransitionStyle.sharedAxisZ,
    );
  }
}

PageRouteBuilder<T> buildAppPageRoute<T>({
  required BuildContext context,
  required Widget child,
  RouteSettings? settings,
  AppPageTransitionStyle style = AppPageTransitionStyle.sharedAxisX,
  Duration duration = kAppMotionSlow,
  Duration reverseDuration = kAppMotionFast,
}) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: reducedMotion ? Duration.zero : duration,
    reverseTransitionDuration: reducedMotion ? Duration.zero : reverseDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      return buildAppPageTransition(
        context: context,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: routedChild,
        style: style,
      );
    },
  );
}
