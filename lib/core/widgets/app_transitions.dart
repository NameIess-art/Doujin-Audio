import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/ui_interaction_coordinator.dart';

const kPlaceholderContentTransitionDuration = Duration(milliseconds: 750);
const kAppMotionFast = Duration(milliseconds: 180);
const kAppMotionStandard = Duration(milliseconds: 220);
const kAppMotionSlow = Duration(milliseconds: 300);
const kAppPageTransitionDuration = Duration(milliseconds: 400);

typedef _PageTransitionBuilder = Widget Function(BuildContext, Widget);

// Animation ownership stays with the route/tab; regions only choose which
// transition to display, without moving header state out of its page.
class _AppPageMotionScope extends InheritedWidget {
  const _AppPageMotionScope({
    required this.contentBuilder,
    required this.headerBuilder,
    required super.child,
  });

  final _PageTransitionBuilder contentBuilder;
  final _PageTransitionBuilder headerBuilder;

  @override
  bool updateShouldNotify(_AppPageMotionScope oldWidget) => true;
}

class AppPageContentTransition extends StatelessWidget {
  const AppPageContentTransition({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    if (motion == null) return child;
    return motion.contentBuilder(context, child);
  }
}

class AppPageHeaderTransition extends StatelessWidget {
  const AppPageHeaderTransition({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    if (motion == null) return child;
    return motion.headerBuilder(context, child);
  }
}

Widget _buildCoveringPageTransition({
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
}) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  return ClipRect(
    child: FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeInOutCubic)),
      child: _AppPageMotionScope(
        contentBuilder: (context, content) => SlideTransition(
          position: animation.drive(
            Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeInOutCubic)),
          ),
          child: content,
        ),
        headerBuilder: (context, header) => AnimatedBuilder(
          animation: Listenable.merge([animation, secondaryAnimation]),
          child: header,
          builder: (context, header) {
            final incoming = Curves.easeOutCubic.transform(
              (animation.value / 0.6).clamp(0.0, 1.0),
            );
            final outgoing = Curves.easeOutCubic.transform(
              (secondaryAnimation.value / 0.6).clamp(0.0, 1.0),
            );
            return Opacity(opacity: incoming * (1 - outgoing), child: header);
          },
        ),
        child: child,
      ),
    ),
  );
}

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

enum AppIndexedStackTransitionStyle { none, directional, crossFade }

class PlaceholderContentTransition extends StatefulWidget {
  const PlaceholderContentTransition({
    super.key,
    required this.showPlaceholder,
    required this.placeholder,
    required this.content,
    this.duration = kPlaceholderContentTransitionDuration,
    this.fadeContent = true,
  });

  final bool showPlaceholder;
  final Widget placeholder;
  final Widget content;
  final Duration duration;
  final bool fadeContent;

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
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleAnimationStatus);
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
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
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
        if (widget.fadeContent)
          FadeTransition(opacity: _contentOpacity, child: widget.content)
        else
          widget.content,
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

class UndoableRemovalTransition extends StatefulWidget {
  const UndoableRemovalTransition({
    super.key,
    required this.hidden,
    required this.child,
    this.duration = kAppMotionStandard,
    this.curve = Curves.easeInOutCubic,
    this.reverseCurve = Curves.easeOutCubic,
  });

  final bool hidden;
  final Widget child;
  final Duration duration;
  final Curve curve;
  final Curve reverseCurve;

  @override
  State<UndoableRemovalTransition> createState() =>
      _UndoableRemovalTransitionState();
}

class _UndoableRemovalTransitionState extends State<UndoableRemovalTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.hidden ? 0.0 : 1.0,
    );
    _updateAnimation();
  }

  void _updateAnimation() {
    _animation = CurvedAnimation(
      parent: _controller,
      curve: widget.reverseCurve,
      reverseCurve: widget.curve,
    );
  }

  @override
  void didUpdateWidget(UndoableRemovalTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.curve != oldWidget.curve ||
        widget.reverseCurve != oldWidget.reverseCurve) {
      _updateAnimation();
    }
    if (widget.hidden != oldWidget.hidden) {
      if (MediaQuery.disableAnimationsOf(context) ||
          widget.duration == Duration.zero) {
        _controller.value = widget.hidden ? 0.0 : 1.0;
      } else if (widget.hidden) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.value == 0.0 && widget.hidden) {
          return const SizedBox.shrink();
        }
        if (_controller.value == 1.0 && !widget.hidden) {
          return child!;
        }
        return SizeTransition(
          sizeFactor: _animation,
          axisAlignment: -1.0,
          child: FadeTransition(
            opacity: _animation,
            child: IgnorePointer(
              ignoring: widget.hidden,
              child: ExcludeSemantics(excluding: widget.hidden, child: child),
            ),
          ),
        );
      },
      child: widget.child,
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

class AppFadeThroughIndexedStack extends StatefulWidget {
  const AppFadeThroughIndexedStack({
    super.key,
    required this.indexListenable,
    required this.children,
    this.style = AppIndexedStackTransitionStyle.directional,
    this.separateHeader = false,
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
    this.separateHeader = false,
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
  final bool separateHeader;
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
        if (!widget.separateHeader) {
          return FractionalTranslation(
            translation: translation,
            child: Opacity(opacity: opacity, child: child),
          );
        }
        return Opacity(
          opacity: incoming ? (rawProgress / 0.2).clamp(0.0, 1.0) : 1,
          child: _AppPageMotionScope(
            contentBuilder: (context, content) => FractionalTranslation(
              translation: translation,
              child: Opacity(opacity: opacity, child: content),
            ),
            headerBuilder: (context, header) {
              final headerProgress = Curves.easeOutCubic.transform(
                (rawProgress / 0.6).clamp(0.0, 1.0),
              );
              final headerOpacity = !outgoing && !incoming
                  ? 1.0
                  : outgoing
                  ? 1 - headerProgress
                  : headerProgress;
              return Opacity(opacity: headerOpacity, child: header);
            },
            child: child!,
          ),
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

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => kAppPageTransitionDuration;

  @override
  Duration get reverseTransitionDuration => kAppPageTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _buildCoveringPageTransition(
      context: context,
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

PageRouteBuilder<T> buildAppPageRoute<T>({
  required BuildContext context,
  required Widget child,
  RouteSettings? settings,
}) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: reducedMotion
        ? Duration.zero
        : kAppPageTransitionDuration,
    reverseTransitionDuration: reducedMotion
        ? Duration.zero
        : kAppPageTransitionDuration,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      return _buildCoveringPageTransition(
        context: context,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: routedChild,
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
