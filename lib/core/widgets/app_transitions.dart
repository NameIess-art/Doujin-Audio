import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../ui/ui_interaction_coordinator.dart';

const kPlaceholderContentTransitionDuration = Duration(milliseconds: 450);
const kAppMotionFast = Duration(milliseconds: 180);
const kAppMotionStandard = Duration(milliseconds: 220);
const kAppMotionSlow = Duration(milliseconds: 300);

typedef _PageTransitionBuilder = Widget Function(BuildContext, Widget);

class AppNavigationInputLock extends StatefulWidget {
  const AppNavigationInputLock({
    super.key,
    required this.navigationAllowed,
    required this.child,
  });

  final ValueListenable<bool> navigationAllowed;
  final Widget child;

  @override
  State<AppNavigationInputLock> createState() => _AppNavigationInputLockState();
}

class _AppNavigationInputLockState extends State<AppNavigationInputLock> {
  final GlobalKey _pointerBarrierKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.navigationAllowed.addListener(_handleChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_handleKeyEvent);
  }

  @override
  void didUpdateWidget(AppNavigationInputLock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationAllowed != widget.navigationAllowed) {
      oldWidget.navigationAllowed.removeListener(_handleChanged);
      widget.navigationAllowed.addListener(_handleChanged);
      _handleChanged();
    }
  }

  void _handleChanged() {
    // Block another pointer event even before the next widget frame is built.
    final barrier = _pointerBarrierKey.currentContext?.findRenderObject();
    if (barrier is RenderAbsorbPointer) {
      barrier.absorbing = !widget.navigationAllowed.value;
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) =>
      widget.navigationAllowed.value
      ? KeyEventResult.ignored
      : KeyEventResult.handled;

  @override
  void deactivate() {
    widget.navigationAllowed.removeListener(_handleChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKeyEvent);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    widget.navigationAllowed.addListener(_handleChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    widget.navigationAllowed.removeListener(_handleChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKeyEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      key: _pointerBarrierKey,
      absorbing: !widget.navigationAllowed.value,
      child: widget.child,
    );
  }
}

// Animation ownership stays with the route/tab; regions only choose which
// transition to display, without moving header state out of its page.
class _AppPageMotionScope extends InheritedWidget {
  const _AppPageMotionScope({
    super.key,
    required this.contentBuilder,
    required this.headerBuilder,
    this.configuration,
    required super.child,
  });

  final _PageTransitionBuilder contentBuilder;
  final _PageTransitionBuilder headerBuilder;
  final Object? configuration;

  @override
  bool updateShouldNotify(_AppPageMotionScope oldWidget) =>
      configuration == null || configuration != oldWidget.configuration;
}

class AppPageContentTransition extends StatelessWidget {
  const AppPageContentTransition({
    super.key,
    required this.child,
    this.backgroundColor,
  });
  final Widget child;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    final content = backgroundColor == null
        ? child
        : ColoredBox(color: backgroundColor!, child: child);
    if (motion == null) return content;
    return motion.contentBuilder(context, content);
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
  required GlobalKey contentKey,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
  bool workDetailTransition = false,
}) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final position = animation.drive(
    Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).chain(
      CurveTween(
        curve: workDetailTransition
            ? const Cubic(0.215, 0.61, 0.355, 1)
            : Curves.easeOutCubic,
      ),
    ),
  );
  final transition = ClipRect(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final page = _AppPageMotionScope(
          key: contentKey,
          configuration: (
            animation,
            secondaryAnimation,
            constraints.maxWidth,
            workDetailTransition,
          ),
          contentBuilder: (context, content) => workDetailTransition
              ? AnimatedBuilder(
                  animation: position,
                  child: RepaintBoundary(child: content),
                  builder: (context, content) => Transform.translate(
                    offset: Offset(constraints.maxWidth * position.value.dx, 0),
                    child: content,
                  ),
                )
              : RepaintBoundary(child: content),
          headerBuilder: (context, header) => AnimatedBuilder(
            animation: Listenable.merge([animation, secondaryAnimation]),
            child: workDetailTransition
                ? RepaintBoundary(child: header)
                : header,
            builder: (context, header) {
              final incoming = Curves.easeOutCubic.transform(
                (animation.value / 0.6).clamp(0.0, 1.0),
              );
              final outgoing = Curves.easeOutCubic.transform(
                (secondaryAnimation.value / 0.6).clamp(0.0, 1.0),
              );
              final fadedHeader = Opacity(
                opacity: incoming * (1 - outgoing),
                child: header,
              );
              if (workDetailTransition) return fadedHeader;
              // Generic routes translate the whole page; cancel that motion
              // for headers narrower than the page so menus change in place.
              return Transform.translate(
                offset: Offset(-constraints.maxWidth * position.value.dx, 0),
                child: fadedHeader,
              );
            },
          ),
          child: child,
        );
        // Keep header fades out of the moving content's recording/cache layer.
        // Every detail region moves in route coordinates, including overlays.
        return workDetailTransition
            ? page
            : SlideTransition(
                position: position,
                child: RepaintBoundary(child: page),
              );
      },
    ),
  );
  final interactive =
      animation.status == AnimationStatus.completed &&
      secondaryAnimation.status == AnimationStatus.dismissed;
  // Record a quiet page layer while sliding; skeletons and child animations
  // resume with input and semantics only after both route motions finish.
  return _buildPageActivity(transition, interactive: interactive);
}

Widget _buildPageActivity(Widget child, {required bool interactive}) {
  return TickerMode(
    enabled: interactive,
    child: ExcludeFocus(
      excluding: !interactive,
      child: ExcludeSemantics(
        excluding: !interactive,
        child: IgnorePointer(ignoring: !interactive, child: child),
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

class PlaceholderContentTransition extends StatefulWidget {
  const PlaceholderContentTransition({
    super.key,
    required this.showPlaceholder,
    required this.placeholder,
    required this.content,
    this.duration = kPlaceholderContentTransitionDuration,
    this.fadeContent = true,
    this.fadePlaceholder = true,
    this.fit = StackFit.expand,
  });

  final bool showPlaceholder;
  final Widget placeholder;
  final Widget content;
  final Duration duration;
  final bool fadeContent;
  final bool fadePlaceholder;
  final StackFit fit;

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

  bool get _skipMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      !TickerMode.valuesOf(context).enabled ||
      ModalRoute.isCurrentOf(context) == false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_skipMotion) {
      _fadingPlaceholder = false;
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant PlaceholderContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.showPlaceholder && !widget.showPlaceholder) {
      if (_skipMotion) {
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
      fit: widget.fit,
      children: [
        if (_fadingPlaceholder)
          IgnorePointer(
            child: widget.fadePlaceholder
                ? FadeTransition(
                    opacity: _placeholderOpacity,
                    child: widget.placeholder,
                  )
                : widget.placeholder,
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
    this.separateHeader = false,
    this.prepareAdjacentPage = false,
    this.duration = const Duration(milliseconds: 350),
    this.onTransitionCompleted,
  }) : itemCount = children.length,
       itemBuilder = null,
       contentRevision = null;

  AppFadeThroughIndexedStack.lazy({
    super.key,
    required this.indexListenable,
    required this.itemCount,
    required IndexedWidgetBuilder this.itemBuilder,
    this.contentRevision,
    this.separateHeader = false,
    this.prepareAdjacentPage = false,
    this.duration = const Duration(milliseconds: 350),
    this.onTransitionCompleted,
  }) : children = List<Widget>.filled(itemCount, const SizedBox.shrink());

  final ValueListenable<int> indexListenable;
  int get index => indexListenable.value;
  final List<Widget> children;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;

  /// Changed builder inputs are applied when retained pages become visible.
  /// Leave null to keep the initial widgets across parent rebuilds.
  final Object? contentRevision;
  final bool separateHeader;

  /// Prepare one neighbouring page after idle without selecting it.
  final bool prepareAdjacentPage;
  final Duration duration;
  final ValueChanged<int>? onTransitionCompleted;

  @override
  State<AppFadeThroughIndexedStack> createState() =>
      _AppFadeThroughIndexedStackState();
}

class _AppFadeThroughIndexedStackState extends State<AppFadeThroughIndexedStack>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late int _currentIndex;
  late int _targetIndex;
  int _transitionDirection = 1;
  bool _isAnimating = false;
  late List<Widget?> _lazyChildren;
  final Set<int> _dirtyChildren = {};
  late List<GlobalKey> _pageKeys;
  final Object _transitionInteraction = Object();
  final Set<int> _preparedPages = {};
  BoxConstraints? _preparedConstraints;
  int? _pendingIndex;
  int? _idlePreparationIndex;
  Timer? _adjacentPreparationTimer;
  bool _tickerEnabled = false;
  bool _animationsDisabled = false;

  bool get _isLazy => widget.itemBuilder != null;
  int get _itemCount => widget.itemCount;

  @override
  void initState() {
    super.initState();
    _currentIndex = _safeIndex(widget.indexListenable.value);
    _targetIndex = _currentIndex;
    _lazyChildren = List<Widget?>.filled(_itemCount, null);
    _pageKeys = List<GlobalKey>.generate(_itemCount, (_) => GlobalKey());
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.duration,
    )..addStatusListener(_handleStatusChanged);
    _controller.value = 1;
    widget.indexListenable.addListener(_handleIndexChanged);
    WidgetsBinding.instance.addObserver(this);
    UiInteractionCoordinator.instance.addListener(_scheduleAdjacentPreparation);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _animationsDisabled = MediaQuery.disableAnimationsOf(context);
    _scheduleAdjacentPreparation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _scheduleAdjacentPreparation();
  }

  int? get _adjacentIndex {
    if (_itemCount < 2) return null;
    return _currentIndex + 1 < _itemCount
        ? _currentIndex + 1
        : _currentIndex - 1;
  }

  void _scheduleAdjacentPreparation() {
    final coordinator = UiInteractionCoordinator.instance;
    _adjacentPreparationTimer?.cancel();
    _adjacentPreparationTimer = null;
    if (!_canPrepareAdjacentPage) {
      if (_idlePreparationIndex != null) {
        setState(() => _idlePreparationIndex = null);
      }
      return;
    }
    if (_idlePreparationIndex != null) return;
    final adjacent = _adjacentIndex;
    if (adjacent == null || _preparedPages.contains(adjacent)) return;
    // Keep startup and the navigation quiet tail free of speculative layout.
    // Only one neighbour is built; no index changes or feature activation occur.
    _adjacentPreparationTimer = Timer(coordinator.idleDelay, () {
      _adjacentPreparationTimer = null;
      if (!_canPrepareAdjacentPage || adjacent != _adjacentIndex) return;
      setState(() => _idlePreparationIndex = adjacent);
    });
  }

  bool get _canPrepareAdjacentPage {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        widget.prepareAdjacentPage &&
        widget.duration > Duration.zero &&
        !_isAnimating &&
        _pendingIndex == null &&
        !UiInteractionCoordinator.instance.isInteracting &&
        _tickerEnabled &&
        !_animationsDisabled &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  @override
  void didUpdateWidget(covariant AppFadeThroughIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isLazy && oldWidget.itemBuilder == null) {
      for (
        var index = 0;
        index < math.min(_itemCount, oldWidget.itemCount);
        index++
      ) {
        if (!Widget.canUpdate(
          oldWidget.children[index],
          widget.children[index],
        )) {
          _preparedPages.remove(index);
        }
      }
    }
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
      if (_isLazy != (oldWidget.itemBuilder != null)) {
        _preparedPages.clear();
      }
      _resetLazyChildren();
      _handleIndexChanged();
    } else if (_isLazy && widget.contentRevision != oldWidget.contentRevision) {
      for (var index = 0; index < _itemCount; index++) {
        if (_lazyChildren[index] != null) {
          _dirtyChildren.add(index);
          _preparedPages.remove(index);
        }
      }
    }
    _scheduleAdjacentPreparation();
  }

  void _resetLazyChildren() {
    final previousKeys = _pageKeys;
    final previousChildren = _lazyChildren;
    _lazyChildren = List<Widget?>.generate(
      _itemCount,
      (index) =>
          _isLazy &&
              index < previousChildren.length &&
              previousChildren[index] != null
          ? widget.itemBuilder!(context, index)
          : null,
    );
    _pageKeys = List<GlobalKey>.generate(
      _itemCount,
      (index) =>
          index < previousKeys.length ? previousKeys[index] : GlobalKey(),
    );
    _controller.stop();
    _dirtyChildren.clear();
    _pendingIndex = null;
    _idlePreparationIndex = null;
    _preparedPages.removeWhere((index) => index >= _itemCount);
    _isAnimating = false;
    _currentIndex = _safeIndex(widget.indexListenable.value);
    _targetIndex = _currentIndex;
    _controller.value = 1;
    UiInteractionCoordinator.instance.cancelNavigation(_transitionInteraction);
    widget.onTransitionCompleted?.call(_currentIndex);
  }

  int _safeIndex(int index) {
    if (_itemCount == 0) return 0;
    return index.clamp(0, _itemCount - 1);
  }

  void _handleIndexChanged() {
    if (!mounted || _itemCount == 0) return;
    final nextIndex = _safeIndex(widget.indexListenable.value);
    _adjacentPreparationTimer?.cancel();
    _adjacentPreparationTimer = null;
    if (_idlePreparationIndex != null) {
      setState(() => _idlePreparationIndex = null);
    }
    if (_pendingIndex != null) setState(() => _pendingIndex = null);
    if (nextIndex == _targetIndex) {
      if (_isAnimating && _preparedPages.contains(nextIndex)) {
        _controller.forward();
      }
      return;
    }
    UiInteractionCoordinator.instance.beginNavigation(_transitionInteraction);
    if (widget.duration == Duration.zero ||
        MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _currentIndex = nextIndex;
        _targetIndex = nextIndex;
        _isAnimating = false;
        _controller.value = 1;
      });
      widget.onTransitionCompleted?.call(_currentIndex);
      UiInteractionCoordinator.instance.endNavigation(_transitionInteraction);
      return;
    }

    // Keep the current two pages in place while a new target lays out outside
    // the viewport. Retarget only after that frame, preserving slide continuity.
    if (_isAnimating && !_preparedPages.contains(_targetIndex)) {
      _controller.stop();
      _isAnimating = false;
    }
    if (_isAnimating && !_preparedPages.contains(nextIndex)) {
      _controller.stop();
      setState(() => _pendingIndex = nextIndex);
      return;
    }

    if (_isAnimating) {
      if (nextIndex == _currentIndex) {
        _controller.reverse().then<void>((_) {
          if (mounted && _controller.status == AnimationStatus.dismissed) {
            _completeTransition(_currentIndex);
          }
        });
        return;
      }
      final direction = nextIndex > _currentIndex ? 1 : -1;
      if (direction == _transitionDirection) {
        setState(() => _targetIndex = nextIndex);
        _controller.forward();
        return;
      }
      // Swap the visible source when the new destination is on the other side.
      // Invert decelerate so its position survives the direction change.
      final progress = Curves.decelerate.transform(_controller.value);
      setState(() {
        _currentIndex = _targetIndex;
        _targetIndex = nextIndex;
        _transitionDirection = direction;
      });
      _controller.forward(from: 1 - math.sqrt(progress));
      return;
    }

    if (nextIndex == _currentIndex) {
      setState(() {
        _targetIndex = nextIndex;
        _isAnimating = false;
        _controller.value = 1;
      });
      widget.onTransitionCompleted?.call(_currentIndex);
      UiInteractionCoordinator.instance.endNavigation(_transitionInteraction);
      return;
    }

    setState(() {
      _targetIndex = nextIndex;
      _transitionDirection = _targetIndex > _currentIndex ? 1 : -1;
      _isAnimating = true;
    });
    if (_preparedPages.contains(nextIndex)) {
      _controller.forward(from: 0);
    } else {
      _controller.animateWith(
        _PreparedPageSimulation(
          duration: widget.duration,
          isPrepared: () => _preparedPages.contains(_targetIndex),
        ),
      );
    }
  }

  void _handleStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) _completeTransition(_targetIndex);
  }

  void _completeTransition(int index) {
    if (!_isAnimating || !mounted) return;
    setState(() {
      _currentIndex = index;
      _targetIndex = index;
      _isAnimating = false;
    });
    widget.onTransitionCompleted?.call(_currentIndex);
    UiInteractionCoordinator.instance.endNavigation(_transitionInteraction);
  }

  Widget _childAt(int index) {
    if (!_isLazy) return widget.children[index];
    final visible =
        index == _currentIndex ||
        index == _targetIndex ||
        index == _pendingIndex ||
        index == _idlePreparationIndex;
    if (!visible) {
      return _lazyChildren[index] ?? const SizedBox.shrink();
    }
    // Retain hidden elements, but apply changed query/selection inputs only
    // when they become visible, before their preparation layout.
    if (_dirtyChildren.remove(index)) {
      _lazyChildren[index] = widget.itemBuilder!(context, index);
    }
    return _lazyChildren[index] ??= widget.itemBuilder!(context, index);
  }

  @override
  void dispose() {
    widget.indexListenable.removeListener(_handleIndexChanged);
    WidgetsBinding.instance.removeObserver(this);
    UiInteractionCoordinator.instance.removeListener(
      _scheduleAdjacentPreparation,
    );
    _adjacentPreparationTimer?.cancel();
    UiInteractionCoordinator.instance.cancelNavigation(_transitionInteraction);
    _controller.dispose();
    super.dispose();
  }

  Widget _pageHost({
    required Widget child,
    required bool visible,
    required bool preparing,
    required bool idlePreparing,
  }) {
    final ticking = visible && !preparing;
    final interactive = ticking && !_isAnimating && _pendingIndex == null;
    return _AppPageOffstage(
      offstage: !visible || idlePreparing,
      prepareLayout: idlePreparing,
      onVisibleLayout: _handleVisiblePageLayout,
      child: TickerMode(
        enabled: ticking,
        child: ExcludeFocus(
          excluding: !interactive,
          child: ExcludeSemantics(
            excluding: !interactive,
            child: IgnorePointer(ignoring: !interactive, child: child),
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
    final preparing = index == _pendingIndex || index == _idlePreparationIndex;
    final visible =
        preparing ||
        outgoing ||
        incoming ||
        (!_isAnimating && index == _currentIndex);
    if (visible && !_preparedPages.contains(index)) {
      final pageKey = _pageKeys[index];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || index >= _itemCount || _pageKeys[index] != pageKey) {
          return;
        }
        final boundary = pageKey.currentContext?.findRenderObject();
        if (boundary is! RenderBox || !boundary.hasSize) return;
        _preparedPages.add(index);
        if (_idlePreparationIndex == index) {
          setState(() => _idlePreparationIndex = null);
        }
        if (_pendingIndex == index) {
          _handleIndexChanged();
        }
      });
    }
    final page = _pageHost(
      child: _childAt(index),
      visible: visible,
      preparing: preparing,
      idlePreparing: index == _idlePreparationIndex,
    );
    if (widget.duration == Duration.zero) {
      return KeyedSubtree(
        key: ValueKey<String>('app_indexed_page_$index'),
        child: RepaintBoundary(key: _pageKeys[index], child: page),
      );
    }
    final animation = preparing
        ? const AlwaysStoppedAnimation<double>(0)
        : outgoing || incoming
        ? _controller
        : const AlwaysStoppedAnimation<double>(1);
    final progress = animation.drive(CurveTween(curve: Curves.decelerate));
    final direction = _transitionDirection.toDouble();
    final position = progress.drive(
      Tween<Offset>(
        begin: incoming || preparing ? Offset(direction, 0) : Offset.zero,
        end: outgoing ? Offset(-direction, 0) : Offset.zero,
      ),
    );
    if (!widget.separateHeader) {
      return KeyedSubtree(
        key: ValueKey<String>('app_indexed_page_$index'),
        child: SlideTransition(
          position: position,
          child: RepaintBoundary(key: _pageKeys[index], child: page),
        ),
      );
    }
    return KeyedSubtree(
      key: ValueKey<String>('app_indexed_page_$index'),
      child: _AppPageMotionScope(
        configuration: (
          animation,
          outgoing,
          incoming,
          preparing,
          outgoing || incoming || preparing ? _transitionDirection : 0,
        ),
        contentBuilder: (context, content) => SlideTransition(
          position: position,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: RepaintBoundary(child: content),
          ),
        ),
        headerBuilder: (_, header) => FadeTransition(
          opacity: preparing
              ? const AlwaysStoppedAnimation<double>(0)
              : outgoing
              ? ReverseAnimation(progress)
              : incoming
              ? progress
              : const AlwaysStoppedAnimation<double>(1),
          child: header,
        ),
        child: RepaintBoundary(key: _pageKeys[index], child: page),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_itemCount == 0) return const SizedBox.shrink();
    final paintOrder = <int>[
      for (var index = 0; index < _itemCount; index++)
        if (index != _currentIndex &&
            index != _targetIndex &&
            index != _pendingIndex &&
            index != _idlePreparationIndex &&
            (!_isLazy || _lazyChildren[index] != null))
          index,
      _currentIndex,
      if (_isAnimating && _targetIndex != _currentIndex) _targetIndex,
      if (_pendingIndex != null &&
          _pendingIndex != _targetIndex &&
          _pendingIndex != _currentIndex)
        _pendingIndex!,
      if (_idlePreparationIndex != null &&
          _idlePreparationIndex != _currentIndex &&
          _idlePreparationIndex != _targetIndex &&
          _idlePreparationIndex != _pendingIndex)
        _idlePreparationIndex!,
    ];
    return IgnorePointer(
      ignoring: _isAnimating || _pendingIndex != null,
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

  void _handleVisiblePageLayout(BoxConstraints constraints) {
    // Hidden pages retain their old layout. After a resize, prepare them at
    // the new size before consuming their visible animation time.
    if (_preparedConstraints != constraints) {
      _preparedConstraints = constraints;
      _preparedPages.removeWhere(
        (index) =>
            index != _currentIndex &&
            index != _targetIndex &&
            index != _pendingIndex &&
            index != _idlePreparationIndex,
      );
      _scheduleAdjacentPreparation();
    }
  }
}

class _AppPageOffstage extends Offstage {
  const _AppPageOffstage({
    required super.offstage,
    required this.prepareLayout,
    required this.onVisibleLayout,
    required super.child,
  });

  final ValueChanged<BoxConstraints> onVisibleLayout;
  final bool prepareLayout;

  @override
  RenderOffstage createRenderObject(BuildContext context) =>
      _RenderAppPageOffstage(
        offstage: offstage,
        prepareLayout: prepareLayout,
        onVisibleLayout: onVisibleLayout,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAppPageOffstage renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    renderObject.onVisibleLayout = onVisibleLayout;
    renderObject.prepareLayout = prepareLayout;
  }
}

class _RenderAppPageOffstage extends RenderOffstage {
  _RenderAppPageOffstage({
    required super.offstage,
    required bool prepareLayout,
    required this.onVisibleLayout,
  }) : _prepareLayout = prepareLayout;

  bool _prepareLayout;
  set prepareLayout(bool value) {
    if (_prepareLayout == value) return;
    _prepareLayout = value;
    markNeedsLayout();
  }

  ValueChanged<BoxConstraints> onVisibleLayout;

  @override
  void performLayout() {
    // RenderOffstage normally lays out its child even when hidden. Retain the
    // element tree (scroll, expansion and provider state) without traversing a
    // cached list on each frame or window resize. Activation lays it out using
    // the latest constraints before painting or accepting input.
    if (!offstage || _prepareLayout) {
      onVisibleLayout(constraints);
      super.performLayout();
    }
  }
}

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => kAppMotionSlow;

  @override
  Duration get reverseTransitionDuration => kAppMotionSlow;

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
      contentKey: GlobalObjectKey(route),
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
  // Work details keep their smooth slide curve and paint the final exit frame.
  bool workDetailTransition = false,
  Duration duration = kAppMotionSlow,
  bool fullscreenDialog = false,
}) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  final contentKey = GlobalKey();
  return AppPreparedPageRoute<T>(
    settings: settings,
    fullscreenDialog: fullscreenDialog,
    transitionDuration: reducedMotion || duration == Duration.zero
        ? Duration.zero
        : duration,
    reverseTransitionDuration: reducedMotion || duration == Duration.zero
        ? Duration.zero
        : duration,
    deferExitFinalization: workDetailTransition,
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      if (duration == Duration.zero) return routedChild;
      if (MediaQuery.disableAnimationsOf(context)) return routedChild;
      return _buildCoveringPageTransition(
        context: context,
        contentKey: contentKey,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: routedChild,
        workDetailTransition: workDetailTransition,
      );
    },
  );
}

// Shared route lifecycle: record the first page before consuming entrance time,
// and retain a closing page until its final frame has painted.
class AppPreparedPageRoute<T> extends PageRouteBuilder<T> {
  AppPreparedPageRoute({
    required super.pageBuilder,
    required super.transitionsBuilder,
    required super.transitionDuration,
    required super.reverseTransitionDuration,
    super.settings,
    super.fullscreenDialog,
    required this.deferExitFinalization,
  });

  final bool deferExitFinalization;
  bool _prepared = false;
  bool _disposed = false;
  Timer? _exitCompletionTimer;

  // Material routes require a delegated transition to follow a custom route's
  // secondary animation. Keep their content still and pause it while covered.
  @override
  DelegatedTransitionBuilder get delegatedTransition =>
      (context, animation, secondaryAnimation, allowSnapshotting, child) =>
          _buildPageActivity(
            child!,
            interactive:
                animation.status == AnimationStatus.completed &&
                secondaryAnimation.status == AnimationStatus.dismissed,
          );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isActive) _prepared = true;
    });
    return super.buildPage(context, animation, secondaryAnimation);
  }

  @override
  Simulation? createSimulation({required bool forward}) {
    if (!forward &&
        deferExitFinalization &&
        controller!.reverseDuration != Duration.zero &&
        controller!.value > 0) {
      return _PostFrameExitSimulation(
        initialValue: controller!.value,
        duration: reverseTransitionDuration,
        onFinished: () {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_disposed) return;
            // Finalize after the offscreen frame has painted, outside the
            // animation callback that delivered its final position.
            _exitCompletionTimer = Timer(Duration.zero, () {
              if (!_disposed) controller!.value = 0;
            });
          });
        },
      );
    }
    if (!forward || _prepared || transitionDuration == Duration.zero) {
      return null;
    }
    return _PreparedPageSimulation(
      duration: transitionDuration,
      isPrepared: () => _prepared,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _exitCompletionTimer?.cancel();
    super.dispose();
  }
}

class _PostFrameExitSimulation extends Simulation {
  _PostFrameExitSimulation({
    required this.initialValue,
    required Duration duration,
    required this.onFinished,
  }) : _duration =
           duration.inMicroseconds /
           Duration.microsecondsPerSecond *
           initialValue;

  final double initialValue;
  final double _duration;
  final VoidCallback onFinished;
  bool _completionScheduled = false;

  @override
  double x(double time) {
    if (time >= _duration) {
      if (!_completionScheduled) {
        _completionScheduled = true;
        onFinished();
      }
      return 0;
    }
    return initialValue * (1 - time / _duration);
  }

  @override
  double dx(double time) => _duration == 0 ? 0 : -initialValue / _duration;

  @override
  bool isDone(double time) => false;
}

// Keep one continuous TickerFuture/status sequence while the first page frame
// lays out. A long preparation frame does not consume the visible animation.
class _PreparedPageSimulation extends Simulation {
  _PreparedPageSimulation({
    required Duration duration,
    required this.isPrepared,
  }) : _duration = duration.inMicroseconds / Duration.microsecondsPerSecond;

  final double _duration;
  final bool Function() isPrepared;
  double? _visibleStartTime;

  @override
  double x(double time) {
    if (!isPrepared()) {
      return 0;
    }
    // Anchor to the first prepared tick, not the preceding vsync: that gap
    // includes the actual first layout cost, which must not skip the entrance.
    _visibleStartTime ??= time;
    return ((time - _visibleStartTime!) / _duration).clamp(0.0, 1.0);
  }

  @override
  double dx(double time) => isPrepared() ? 1 / _duration : 0;

  @override
  bool isDone(double time) =>
      _visibleStartTime != null && time - _visibleStartTime! >= _duration;
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
