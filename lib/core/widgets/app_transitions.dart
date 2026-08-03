import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const kPlaceholderContentTransitionDuration = Duration(milliseconds: 750);
const kAppMotionFast = Duration(milliseconds: 180);
const kAppMotionStandard = Duration(milliseconds: 220);
const kAppMotionSlow = Duration(milliseconds: 300);

enum AppPageTransitionStyle { fadeThrough, sharedAxisX, sharedAxisZ }

enum AppIndexedStackTransitionStyle { directional, crossFade }

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
    required this.indexListenable,
    required this.children,
    this.style = AppIndexedStackTransitionStyle.directional,
    this.onTransitionCompleted,
  });

  final ValueListenable<int> indexListenable;
  int get index => indexListenable.value;
  final List<Widget> children;
  final AppIndexedStackTransitionStyle style;
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
    _currentIndex = _safeIndex(widget.indexListenable.value);
    _targetIndex = _currentIndex;
    _controller = AnimationController(
      vsync: this,
      duration: _transitionDuration,
      reverseDuration: _transitionDuration,
    )..addStatusListener(_handleStatusChanged);
    _controller.value = 1;
    widget.indexListenable.addListener(_handleIndexChanged);
  }

  @override
  void didUpdateWidget(covariant AppFadeThroughIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.indexListenable, widget.indexListenable)) {
      oldWidget.indexListenable.removeListener(_handleIndexChanged);
      widget.indexListenable.addListener(_handleIndexChanged);
      _handleIndexChanged();
    } else if (widget.children.length != oldWidget.children.length) {
      _handleIndexChanged();
    }
  }

  int _safeIndex(int index) {
    if (widget.children.isEmpty) return 0;
    return index.clamp(0, widget.children.length - 1);
  }

  void _handleIndexChanged() {
    if (!mounted || widget.children.isEmpty) return;
    final nextIndex = _safeIndex(widget.indexListenable.value);
    if (nextIndex == _targetIndex) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _currentIndex = nextIndex;
        _targetIndex = nextIndex;
        _isAnimating = false;
        _controller.value = 1;
      });
      widget.onTransitionCompleted?.call(_currentIndex);
      return;
    }

    final nextCurrent = _isAnimating && _controller.value >= 0.5
        ? _targetIndex
        : _currentIndex;
    if (nextIndex == nextCurrent) {
      setState(() {
        _currentIndex = nextCurrent;
        _targetIndex = nextIndex;
        _isAnimating = false;
        _controller.value = 1;
      });
      widget.onTransitionCompleted?.call(_currentIndex);
      return;
    }

    setState(() {
      _currentIndex = nextCurrent;
      _targetIndex = nextIndex;
      _transitionDirection = _targetIndex > _currentIndex ? 1 : -1;
      _isAnimating = true;
    });
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
    widget.indexListenable.removeListener(_handleIndexChanged);
    _controller.dispose();
    super.dispose();
  }

  Widget _pageHost({required int index, required bool visible}) {
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: IgnorePointer(
              ignoring: !visible,
              child: widget.children[index],
            ),
          ),
        ),
      ),
    );
  }

  Widget _animatedPage({
    required int index,
    required bool outgoing,
    required bool incoming,
  }) {
    final visible =
        outgoing || incoming || (!_isAnimating && index == _currentIndex);
    final page = _pageHost(index: index, visible: visible);
    return AnimatedBuilder(
      key: ValueKey<String>('app_indexed_page_$index'),
      animation: outgoing || incoming
          ? _controller
          : const AlwaysStoppedAnimation<double>(1),
      child: page,
      builder: (context, child) {
        final rawProgress = _isAnimating ? _controller.value : 1.0;
        final progress = Curves.easeOutCubic.transform(rawProgress);
        final direction = _transitionDirection.toDouble();
        final crossFade =
            widget.style == AppIndexedStackTransitionStyle.crossFade;
        final translation = !outgoing && !incoming
            ? Offset.zero
            : crossFade
            ? Offset.zero
            : outgoing
            ? Offset(-direction * _outgoingOffset * progress, 0)
            : Offset(direction * _incomingOffset * (1 - progress), 0);
        final opacity = !outgoing && !incoming
            ? 1.0
            : crossFade
            ? outgoing
                  ? 1 - progress
                  : progress
            : outgoing
            ? 1 - progress * (1 - _outgoingOpacityFloor)
            : 1.0;
        return FractionalTranslation(
          translation: translation,
          child: Opacity(opacity: opacity, child: child),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final paintOrder = <int>[
      for (var index = 0; index < widget.children.length; index++)
        if (index != _currentIndex && index != _targetIndex) index,
      _currentIndex,
      if (_isAnimating && _targetIndex != _currentIndex) _targetIndex,
    ];
    return IgnorePointer(
      ignoring: _isAnimating,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: paintOrder
              .map(
                (index) => _animatedPage(
                  index: index,
                  outgoing: _isAnimating && index == _currentIndex,
                  incoming: _isAnimating && index == _targetIndex,
                ),
              )
              .toList(growable: false),
        ),
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
