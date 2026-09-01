import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/ui_interaction_coordinator.dart';

const kPlaceholderContentTransitionDuration = Duration(milliseconds: 750);
const kAppMotionFast = Duration(milliseconds: 180);
const kAppMotionStandard = Duration(milliseconds: 220);
const kAppMotionSlow = Duration(milliseconds: 300);

class AppHeaderTransition extends StatelessWidget {
  const AppHeaderTransition({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppMotionFast;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topLeft,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) => buildAppFadeTransition(
        context: context,
        animation: animation,
        child: child,
      ),
      child: child,
    );
  }
}

class AppHeaderLeadingTransition extends StatelessWidget {
  const AppHeaderLeadingTransition({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutBack,
      builder: (context, value, _) {
        final scale = 0.4 + (0.6 * value);
        final turns = (1.0 - value) * -0.25;
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            child: Transform.rotate(
              angle: turns * 2 * 3.141592653589793,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class AppHeaderActionTransition extends StatelessWidget {
  const AppHeaderActionTransition({
    super.key,
    required this.child,
    this.delayIndex = 0,
  });

  final Widget child;
  final int delayIndex;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 320 + delayIndex * 45),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        final scale = 0.5 + (0.5 * value);
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}

extension AppHeaderTransitionWidget on Widget {
  Widget withAppHeaderTransition() => AppHeaderTransition(child: this);
}

enum AppPageTransitionStyle { fade, fadeThrough, sharedAxisX, sharedAxisZ }

enum AppIndexedStackTransitionStyle { none, directional, crossFade }

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
    if (!widget.showPlaceholder) {
      _controller.value = 1;
    }
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
      if (MediaQuery.disableAnimationsOf(context)) {
        _fadingPlaceholder = false;
        _controller.value = 1;
      } else {
        _fadingPlaceholder = true;
        _controller.forward(from: 0);
      }
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
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.showPlaceholder ? widget.placeholder : widget.content;
    }
    if (widget.showPlaceholder && !_fadingPlaceholder) {
      return widget.placeholder;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_fadingPlaceholder)
          IgnorePointer(
            child: FadeTransition(
              opacity: _placeholderOpacity,
              child: widget.placeholder,
            ),
          ),
        FadeTransition(opacity: _contentOpacity, child: widget.content),
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

class AnimatedTreeReveal extends StatelessWidget {
  const AnimatedTreeReveal({
    super.key,
    required this.visible,
    required this.child,
    this.animateInitial = false,
  });

  final bool visible;
  final bool animateInitial;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return visible ? child : const SizedBox.shrink();
    }
    final target = visible ? 1.0 : 0.0;
    return IgnorePointer(
      ignoring: !visible,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(
          begin: animateInitial && visible ? 0 : target,
          end: target,
        ),
        duration: kAppMotionStandard,
        curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
        child: child,
        builder: (context, value, child) {
          // A non-zero extent keeps lazy lists from building every descendant
          // while the newly inserted rows are still visually collapsed.
          final heightFactor = 0.2 + (0.8 * value);
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: heightFactor,
              child: Opacity(opacity: value, child: child),
            ),
          );
        },
      ),
    );
  }
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

Widget buildAppFadeTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Widget child,
  Curve curve = Curves.easeOutCubic,
  Curve reverseCurve = Curves.easeInCubic,
}) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final curved = CurvedAnimation(
    parent: animation,
    curve: curve,
    reverseCurve: reverseCurve,
  );
  return FadeTransition(opacity: curved, child: child);
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
  if (style == AppPageTransitionStyle.fade ||
      style == AppPageTransitionStyle.fadeThrough) {
    return buildAppFadeTransition(
      context: context,
      animation: animation,
      child: child,
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
    this.duration = const Duration(milliseconds: 350),
    this.onTransitionCompleted,
  }) : itemCount = children.length,
       itemBuilder = null,
       preloadUnvisited = false;

  AppFadeThroughIndexedStack.lazy({
    super.key,
    required this.indexListenable,
    required this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
    this.style = AppIndexedStackTransitionStyle.directional,
    this.duration = const Duration(milliseconds: 350),
    this.onTransitionCompleted,
    bool? preloadUnvisited,
  }) : children = List<Widget>.filled(itemCount, const SizedBox.shrink()),
       preloadUnvisited = preloadUnvisited ?? true;

  final ValueListenable<int> indexListenable;
  int get index => indexListenable.value;
  final List<Widget> children;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final bool preloadUnvisited;
  final AppIndexedStackTransitionStyle style;
  final Duration duration;
  final ValueChanged<int>? onTransitionCompleted;

  @override
  State<AppFadeThroughIndexedStack> createState() =>
      _AppFadeThroughIndexedStackState();
}

class _AppFadeThroughIndexedStackState extends State<AppFadeThroughIndexedStack>
    with SingleTickerProviderStateMixin {
  static const _incomingOffset = 0.12;
  static const _outgoingOffset = 0.035;
  static const _outgoingOpacityFloor = 0.0;

  late final AnimationController _controller;
  late int _currentIndex;
  late int _targetIndex;
  int _transitionDirection = 1;
  bool _isAnimating = false;
  late List<Widget?> _lazyChildren;
  late Set<int> _requestedLazyChildren;
  final Object _lazyTransitionInteraction = Object();
  int _preloadEpoch = 0;

  bool get _isLazy => widget.itemBuilder != null;
  int get _itemCount => widget.itemCount;

  @override
  void initState() {
    super.initState();
    _currentIndex = _safeIndex(widget.indexListenable.value);
    _targetIndex = _currentIndex;
    _lazyChildren = List<Widget?>.filled(_itemCount, null);
    _requestedLazyChildren = <int>{if (_itemCount > 0) _currentIndex};
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.duration,
    )..addStatusListener(_handleStatusChanged);
    _controller.value = 1;
    widget.indexListenable.addListener(_handleIndexChanged);
    _scheduleIdlePreload();
  }

  @override
  void didUpdateWidget(covariant AppFadeThroughIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
      _controller.reverseDuration = widget.duration;
    }
    if (!identical(oldWidget.indexListenable, widget.indexListenable)) {
      oldWidget.indexListenable.removeListener(_handleIndexChanged);
      widget.indexListenable.addListener(_handleIndexChanged);
      _handleIndexChanged();
    }
    if (_isLazy != (oldWidget.itemBuilder != null) ||
        _itemCount != oldWidget.itemCount) {
      _resetLazyChildren();
      _handleIndexChanged();
    }
  }

  void _resetLazyChildren() {
    _preloadEpoch++;
    _lazyChildren = List<Widget?>.filled(_itemCount, null);
    _requestedLazyChildren = <int>{
      if (_itemCount > 0) _safeIndex(widget.indexListenable.value),
    };
    _scheduleIdlePreload();
  }

  int _safeIndex(int index) {
    if (_itemCount == 0) return 0;
    return index.clamp(0, _itemCount - 1);
  }

  void _handleIndexChanged() {
    if (!mounted || _itemCount == 0) return;
    final nextIndex = _safeIndex(widget.indexListenable.value);
    if (nextIndex == _targetIndex) return;
    _preloadEpoch++;
    _requestedLazyChildren.add(nextIndex);
    UiInteractionCoordinator.instance.beginInteraction(
      _lazyTransitionInteraction,
    );
    if (widget.style == AppIndexedStackTransitionStyle.none ||
        widget.duration == Duration.zero ||
        MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _currentIndex = nextIndex;
        _targetIndex = nextIndex;
        _isAnimating = false;
        _controller.value = 1;
      });
      widget.onTransitionCompleted?.call(_currentIndex);
      UiInteractionCoordinator.instance.endInteraction(
        _lazyTransitionInteraction,
      );
      _scheduleIdlePreload();
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
      UiInteractionCoordinator.instance.endInteraction(
        _lazyTransitionInteraction,
      );
      _scheduleIdlePreload();
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
    UiInteractionCoordinator.instance.endInteraction(
      _lazyTransitionInteraction,
    );
    _scheduleIdlePreload();
  }

  void _scheduleIdlePreload() {
    if (!_isLazy || !widget.preloadUnvisited || _itemCount < 2) return;
    final epoch = _preloadEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _preloadEpoch) return;
      final coordinator = UiInteractionCoordinator.instance;
      final generation = coordinator.generation;
      for (var index = 0; index < _itemCount; index++) {
        if (_requestedLazyChildren.contains(index)) continue;
        coordinator.scheduleAfterIdle(
          key: 'lazy_indexed_stack_${identityHashCode(this)}_$index',
          generation: generation,
          priority: 50 + index,
          group: 'lazy_indexed_stack_${identityHashCode(this)}',
          task: () async {
            if (!mounted ||
                epoch != _preloadEpoch ||
                generation != coordinator.generation ||
                _requestedLazyChildren.contains(index)) {
              return;
            }
            setState(() => _requestedLazyChildren.add(index));
          },
        );
      }
    });
  }

  Widget _childAt(int index) {
    if (!_isLazy) return widget.children[index];
    if (!_requestedLazyChildren.contains(index)) {
      return const SizedBox.shrink();
    }
    return _lazyChildren[index] ??= widget.itemBuilder!(context, index);
  }

  @override
  void dispose() {
    widget.indexListenable.removeListener(_handleIndexChanged);
    UiInteractionCoordinator.instance.cancelInteraction(
      _lazyTransitionInteraction,
    );
    _controller.dispose();
    super.dispose();
  }

  Widget _pageHost({required Widget child, required bool visible}) {
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: IgnorePointer(ignoring: !visible, child: child),
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
    final page = _pageHost(child: _childAt(index), visible: visible);
    if (widget.style == AppIndexedStackTransitionStyle.none ||
        widget.duration == Duration.zero) {
      return KeyedSubtree(
        key: ValueKey<String>('app_indexed_page_$index'),
        child: RepaintBoundary(child: page),
      );
    }
    return AnimatedBuilder(
      key: ValueKey<String>('app_indexed_page_$index'),
      animation: outgoing || incoming
          ? _controller
          : const AlwaysStoppedAnimation<double>(1),
      child: RepaintBoundary(child: page),
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
            ? (1 - progress * (1 - _outgoingOpacityFloor)).clamp(0.0, 1.0)
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
    if (_itemCount == 0) return const SizedBox.shrink();
    final paintOrder = <int>[
      for (var index = 0; index < _itemCount; index++)
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

class AppRollingNumber extends StatefulWidget {
  const AppRollingNumber({
    super.key,
    required this.number,
    this.style,
    this.duration = const Duration(milliseconds: 280),
    this.curve = Curves.easeOutCubic,
  });

  final int number;
  final TextStyle? style;
  final Duration duration;
  final Curve curve;

  @override
  State<AppRollingNumber> createState() => _AppRollingNumberState();
}

class _AppRollingNumberState extends State<AppRollingNumber>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late int _currentNumber;
  int? _previousNumber;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _currentNumber = widget.number;
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant AppRollingNumber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.number != oldWidget.number) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _currentNumber = widget.number;
        _previousNumber = null;
        _controller.value = 1.0;
        return;
      }
      _previousNumber = _currentNumber;
      _currentNumber = widget.number;
      _direction = _currentNumber >= (_previousNumber ?? 0) ? 1 : -1;
      _controller.duration = widget.duration;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    if (_previousNumber == null ||
        _previousNumber == _currentNumber ||
        MediaQuery.disableAnimationsOf(context)) {
      return Text('$_currentNumber', style: style);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = widget.curve.transform(_controller.value);
        if (progress >= 1.0) {
          return Text('$_currentNumber', style: style);
        }

        final outgoingOffset = Offset(0, -_direction * progress);
        final incomingOffset = Offset(0, _direction * (1.0 - progress));
        final outgoingOpacity = (1.0 - progress).clamp(0.0, 1.0);
        final incomingOpacity = progress.clamp(0.0, 1.0);

        return ClipRect(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              FractionalTranslation(
                translation: outgoingOffset,
                child: Opacity(
                  opacity: outgoingOpacity,
                  child: Text('$_previousNumber', style: style),
                ),
              ),
              FractionalTranslation(
                translation: incomingOffset,
                child: Opacity(
                  opacity: incomingOpacity,
                  child: Text('$_currentNumber', style: style),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
