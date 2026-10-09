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
  }) : _builder = null,
       _placeholder = null;

  const AppPageContentTransition.deferred({
    super.key,
    required WidgetBuilder builder,
    required Widget placeholder,
    this.backgroundColor,
  }) : child = const SizedBox.shrink(),
       _builder = builder,
       _placeholder = placeholder;

  final Widget child;
  final Color? backgroundColor;
  final WidgetBuilder? _builder;
  final Widget? _placeholder;

  @override
  Widget build(BuildContext context) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    final body = _builder == null
        ? child
        : _DeferredPageContent(builder: _builder, placeholder: _placeholder!);
    final content = backgroundColor == null
        ? body
        : ColoredBox(color: backgroundColor!, child: body);
    if (motion == null) return content;
    return motion.contentBuilder(context, content);
  }
}

class _DeferredPageContent extends StatefulWidget {
  const _DeferredPageContent({
    required this.builder,
    required this.placeholder,
  });

  final WidgetBuilder builder;
  final Widget placeholder;

  @override
  State<_DeferredPageContent> createState() => _DeferredPageContentState();
}

class _DeferredPageContentState extends State<_DeferredPageContent>
    with SingleTickerProviderStateMixin {
  final _coordinator = UiInteractionCoordinator.instance;
  late final _commitKey = 'page_content_${identityHashCode(this)}';
  Animation<double>? _routeAnimation;
  bool _firstFrameBuilt = false;
  bool _active = false;
  bool _ready = false;
  bool _commitScheduled = false;
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: kAppMotionFast)
      ..addStatusListener(_handleFadeStatus);
    _coordinator.addListener(_scheduleContent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _firstFrameBuilt = true;
      _scheduleContent();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready && MediaQuery.disableAnimationsOf(context)) _fade.value = 1;
    if (_ready) return;
    final route = ModalRoute.of(context);
    _active =
        TickerMode.valuesOf(context).enabled &&
        (route == null || route.isCurrent);
    final animation = route?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_handleRouteStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_handleRouteStatus);
    }
    _scheduleContent();
  }

  void _handleRouteStatus(AnimationStatus _) => _scheduleContent();

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  @override
  void deactivate() {
    _active = false;
    _coordinator.cancelCommit(_commitKey);
    _commitScheduled = false;
    _coordinator.removeListener(_scheduleContent);
    _routeAnimation?.removeStatusListener(_handleRouteStatus);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (!_ready) {
      _coordinator.addListener(_scheduleContent);
      _routeAnimation?.addStatusListener(_handleRouteStatus);
    }
  }

  bool get _routeReady =>
      _routeAnimation == null ||
      _routeAnimation!.status == AnimationStatus.completed;

  void _scheduleContent() {
    if (!_firstFrameBuilt ||
        !_active ||
        !_routeReady ||
        _ready ||
        _commitScheduled) {
      return;
    }
    _commitScheduled = true;
    _coordinator.scheduleCommit(
      key: _commitKey,
      allowDuringScroll: true,
      commit: () {
        _commitScheduled = false;
        if (!mounted ||
            !_active ||
            !_routeReady ||
            _coordinator.isVisualUpdateDeferred) {
          return;
        }
        // Preparing only the shell lets entrance motion start without laying
        // out cached lists. Later visits keep the mounted content and its state.
        setState(() => _ready = true);
        if (MediaQuery.disableAnimationsOf(context)) {
          _fade.value = 1;
        } else {
          _fade.forward();
        }
        _coordinator.removeListener(_scheduleContent);
        _routeAnimation?.removeStatusListener(_handleRouteStatus);
      },
    );
  }

  @override
  void dispose() {
    _coordinator.cancelCommit(_commitKey);
    _coordinator.removeListener(_scheduleContent);
    _routeAnimation?.removeStatusListener(_handleRouteStatus);
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (!_ready || !_fade.isCompleted)
        IgnorePointer(
          key: const ValueKey('deferred_placeholder'),
          child: TickerMode(enabled: false, child: widget.placeholder),
        ),
      FadeTransition(
        key: const ValueKey('deferred_content'),
        opacity: _fade,
        child: _ready ? widget.builder(context) : const SizedBox.shrink(),
      ),
    ],
  );
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

class _CoveringPageTransition extends StatefulWidget {
  const _CoveringPageTransition({
    required this.contentKey,
    required this.animation,
    required this.secondaryAnimation,
    this.workDetailTransition = false,
    required this.child,
  });

  final GlobalKey contentKey;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final bool workDetailTransition;
  final Widget child;

  @override
  State<_CoveringPageTransition> createState() =>
      _CoveringPageTransitionState();
}

class _CoveringPageTransitionState extends State<_CoveringPageTransition> {
  late Animation<Offset> _position;
  late Listenable _headerAnimation;
  late bool _interactive;
  Widget? _transition;

  bool get _isInteractive =>
      widget.animation.status == AnimationStatus.completed &&
      widget.secondaryAnimation.status == AnimationStatus.dismissed;

  @override
  void initState() {
    super.initState();
    _updateAnimations();
    _interactive = _isInteractive;
    _listenToStatus(widget);
  }

  void _listenToStatus(_CoveringPageTransition transition) {
    transition.animation.addStatusListener(_handleStatusChanged);
    transition.secondaryAnimation.addStatusListener(_handleStatusChanged);
  }

  void _stopListeningToStatus(_CoveringPageTransition transition) {
    transition.animation.removeStatusListener(_handleStatusChanged);
    transition.secondaryAnimation.removeStatusListener(_handleStatusChanged);
  }

  void _updateAnimations() {
    _position = widget.animation.drive(
      Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).chain(
        CurveTween(
          curve: widget.workDetailTransition
              ? const Cubic(0.215, 0.61, 0.355, 1)
              : Curves.easeOutCubic,
        ),
      ),
    );
    _headerAnimation = Listenable.merge([
      widget.animation,
      widget.secondaryAnimation,
    ]);
  }

  @override
  void didUpdateWidget(_CoveringPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final animationsChanged =
        oldWidget.animation != widget.animation ||
        oldWidget.secondaryAnimation != widget.secondaryAnimation;
    if (animationsChanged) {
      _stopListeningToStatus(oldWidget);
      _listenToStatus(widget);
      _interactive = _isInteractive;
    }
    if (animationsChanged ||
        oldWidget.workDetailTransition != widget.workDetailTransition) {
      _updateAnimations();
      _transition = null;
    }
    if (oldWidget.contentKey != widget.contentKey ||
        oldWidget.child != widget.child) {
      _transition = null;
    }
  }

  void _handleStatusChanged(AnimationStatus _) {
    final interactive = _isInteractive;
    if (_interactive == interactive) return;
    setState(() => _interactive = interactive);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _transition = null;
  }

  @override
  void dispose() {
    _stopListeningToStatus(widget);
    super.dispose();
  }

  Widget _buildTransition() =>
      ClipRect(child: LayoutBuilder(builder: _buildPage));

  Widget _buildPage(BuildContext context, BoxConstraints constraints) {
    final page = _AppPageMotionScope(
      key: widget.contentKey,
      configuration: (
        widget.animation,
        widget.secondaryAnimation,
        constraints.maxWidth,
        widget.workDetailTransition,
      ),
      contentBuilder: (context, content) => widget.workDetailTransition
          ? AnimatedBuilder(
              animation: _position,
              child: RepaintBoundary(child: content),
              builder: (context, content) => Transform.translate(
                offset: Offset(constraints.maxWidth * _position.value.dx, 0),
                child: content,
              ),
            )
          : RepaintBoundary(child: content),
      headerBuilder: (context, header) => AnimatedBuilder(
        animation: _headerAnimation,
        child: widget.workDetailTransition
            ? RepaintBoundary(child: header)
            : header,
        builder: (context, header) {
          final incoming = Curves.easeOutCubic.transform(
            (widget.animation.value / 0.6).clamp(0.0, 1.0),
          );
          final outgoing = Curves.easeOutCubic.transform(
            (widget.secondaryAnimation.value / 0.6).clamp(0.0, 1.0),
          );
          final fadedHeader = Opacity(
            opacity: incoming * (1 - outgoing),
            child: header,
          );
          if (widget.workDetailTransition) return fadedHeader;
          // Generic routes translate the whole page; cancel that motion
          // for headers narrower than the page so menus change in place.
          return Transform.translate(
            offset: Offset(-constraints.maxWidth * _position.value.dx, 0),
            child: fadedHeader,
          );
        },
      ),
      child: widget.child,
    );
    // Keep header fades out of the moving content's recording/cache layer.
    // Every detail region moves in route coordinates, including overlays.
    return widget.workDetailTransition
        ? page
        : SlideTransition(
            position: _position,
            child: RepaintBoundary(child: page),
          );
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    // Route builders run on every tick. Reuse the region tree and animations;
    // only its transform/fade render objects need to observe animation values.
    return _buildPageActivity(
      _transition ??= _buildTransition(),
      interactive: _interactive,
    );
  }
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

class AppMenuContentTransition extends StatefulWidget {
  const AppMenuContentTransition({
    super.key,
    required this.primary,
    this.secondary,
  });

  final Widget primary;
  final Widget? secondary;

  @override
  State<AppMenuContentTransition> createState() =>
      _AppMenuContentTransitionState();
}

class _AppMenuContentTransitionState extends State<AppMenuContentTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  Widget? _secondary;

  @override
  void initState() {
    super.initState();
    _secondary = widget.secondary;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: _secondary == null ? 0 : 1,
    )..addStatusListener(_handleStatus);
    _opacity = _controller.drive(CurveTween(curve: Curves.easeInOutCubic));
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _secondary != null) {
      setState(() => _secondary = null);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.secondary == null ? 0 : 1;
    }
  }

  @override
  void didUpdateWidget(AppMenuContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.secondary != null) _secondary = widget.secondary;
    if (MediaQuery.disableAnimationsOf(context)) {
      _secondary = widget.secondary;
      _controller.value = _secondary == null ? 0 : 1;
    } else if (oldWidget.secondary == null && widget.secondary != null) {
      unawaited(_controller.forward());
    } else if (oldWidget.secondary != null && widget.secondary == null) {
      unawaited(_controller.reverse());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topLeft,
      children: [
        _buildPageActivity(widget.primary, interactive: _secondary == null),
        if (_secondary != null)
          Positioned.fill(
            child: FadeTransition(
              opacity: _opacity,
              child: _buildPageActivity(
                _secondary!,
                interactive: widget.secondary != null,
              ),
            ),
          ),
      ],
    );
  }
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
      child: child,
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
    final crossFade = _controller.drive(
      CurveTween(curve: Curves.easeInOutCubic),
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
  late final CurvedAnimation _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.hidden ? 0.0 : 1.0,
    );
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
      _animation.curve = widget.reverseCurve;
      _animation.reverseCurve = widget.curve;
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
    _animation.dispose();
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
  return _AppFadeTransition(
    animation: animation,
    curve: curve,
    reverseCurve: reverseCurve,
    beginScale: beginScale,
    child: child,
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
  return _AppFadeTransition(
    animation: animation,
    curve: curve,
    reverseCurve: reverseCurve,
    child: child,
  );
}

// The route can outlive many parent rebuilds. Own its curve listener here,
// rather than adding another listener each time a transition is built.
class _AppFadeTransition extends StatefulWidget {
  const _AppFadeTransition({
    required this.animation,
    required this.curve,
    required this.reverseCurve,
    required this.child,
    this.beginScale,
  });

  final Animation<double> animation;
  final Curve curve;
  final Curve reverseCurve;
  final double? beginScale;
  final Widget child;

  @override
  State<_AppFadeTransition> createState() => _AppFadeTransitionState();
}

class _AppFadeTransitionState extends State<_AppFadeTransition> {
  CurvedAnimation? _curved;
  late Animation<double> _opacity;
  Animation<double>? _scale;

  @override
  void initState() {
    super.initState();
    _updateAnimations();
  }

  void _updateAnimations() {
    _curved?.dispose();
    _curved = widget.curve == widget.reverseCurve
        ? null
        : CurvedAnimation(
            parent: widget.animation,
            curve: widget.curve,
            reverseCurve: widget.reverseCurve,
          );
    _opacity =
        _curved ?? widget.animation.drive(CurveTween(curve: widget.curve));
    _updateScale();
  }

  void _updateScale() {
    _scale = widget.beginScale == null
        ? null
        : _opacity.drive(Tween<double>(begin: widget.beginScale!, end: 1));
  }

  @override
  void didUpdateWidget(_AppFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _updateAnimations();
    } else if (oldWidget.curve != widget.curve ||
        oldWidget.reverseCurve != widget.reverseCurve) {
      if (_curved != null && widget.curve != widget.reverseCurve) {
        // Retain CurvedAnimation's direction while an early dismissal reverses.
        _curved!.curve = widget.curve;
        _curved!.reverseCurve = widget.reverseCurve;
        _updateScale();
      } else {
        _updateAnimations();
      }
    } else if (oldWidget.beginScale != widget.beginScale) {
      _updateScale();
    }
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: _scale == null
        ? widget.child
        : ScaleTransition(scale: _scale!, child: widget.child),
  );
}

class AppFadeThroughIndexedStack extends StatefulWidget {
  const AppFadeThroughIndexedStack({
    super.key,
    required this.indexListenable,
    required this.children,
    this.separateHeader = false,
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

  final Duration duration;
  final ValueChanged<int>? onTransitionCompleted;

  @override
  State<AppFadeThroughIndexedStack> createState() =>
      _AppFadeThroughIndexedStackState();
}

class _AppFadeThroughIndexedStackState extends State<AppFadeThroughIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  late final Animation<double> _reverseProgress;
  late final List<Animation<Offset>> _incomingPositions;
  late final List<Animation<Offset>> _outgoingPositions;
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
    _progress = _controller.drive(CurveTween(curve: Curves.decelerate));
    _reverseProgress = ReverseAnimation(_progress);
    _incomingPositions = [
      for (final direction in [-1.0, 1.0])
        _progress.drive(Tween(begin: Offset(direction, 0), end: Offset.zero)),
    ];
    _outgoingPositions = [
      for (final direction in [-1.0, 1.0])
        _progress.drive(Tween(begin: Offset.zero, end: Offset(-direction, 0))),
    ];
    widget.indexListenable.addListener(_handleIndexChanged);
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
        index == _pendingIndex;
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
    UiInteractionCoordinator.instance.cancelNavigation(_transitionInteraction);
    _controller.dispose();
    super.dispose();
  }

  Widget _pageHost({
    required Widget child,
    required bool visible,
    required bool preparing,
  }) {
    final interactive =
        visible && !preparing && !_isAnimating && _pendingIndex == null;
    return _AppPageOffstage(
      offstage: !visible,
      onVisibleLayout: _handleVisiblePageLayout,
      child: TickerMode(
        enabled: interactive,
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
    final preparing = index == _pendingIndex;
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
        if (_pendingIndex == index) {
          _handleIndexChanged();
        }
      });
    }
    final page = _pageHost(
      child: _childAt(index),
      visible: visible,
      preparing: preparing,
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
    final directionIndex = _transitionDirection < 0 ? 0 : 1;
    final Animation<Offset> position;
    if (preparing) {
      position = _transitionDirection < 0
          ? const AlwaysStoppedAnimation<Offset>(Offset(-1, 0))
          : const AlwaysStoppedAnimation<Offset>(Offset(1, 0));
    } else if (incoming) {
      position = _incomingPositions[directionIndex];
    } else if (outgoing) {
      position = _outgoingPositions[directionIndex];
    } else {
      position = const AlwaysStoppedAnimation<Offset>(Offset.zero);
    }
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
              ? _reverseProgress
              : incoming
              ? _progress
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
            (!_isLazy || _lazyChildren[index] != null))
          index,
      _currentIndex,
      if (_isAnimating && _targetIndex != _currentIndex) _targetIndex,
      if (_pendingIndex != null &&
          _pendingIndex != _targetIndex &&
          _pendingIndex != _currentIndex)
        _pendingIndex!,
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
            index != _pendingIndex,
      );
    }
  }
}

class _AppPageOffstage extends Offstage {
  const _AppPageOffstage({
    required super.offstage,
    required this.onVisibleLayout,
    required super.child,
  });

  final ValueChanged<BoxConstraints> onVisibleLayout;

  @override
  RenderOffstage createRenderObject(BuildContext context) =>
      _RenderAppPageOffstage(
        offstage: offstage,
        onVisibleLayout: onVisibleLayout,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAppPageOffstage renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    renderObject.onVisibleLayout = onVisibleLayout;
  }
}

class _RenderAppPageOffstage extends RenderOffstage {
  _RenderAppPageOffstage({
    required super.offstage,
    required this.onVisibleLayout,
  });

  ValueChanged<BoxConstraints> onVisibleLayout;

  @override
  void performLayout() {
    // RenderOffstage normally lays out its child even when hidden. Retain the
    // element tree (scroll, expansion and provider state) without traversing a
    // cached list on each frame or window resize. Activation lays it out using
    // the latest constraints before painting or accepting input.
    if (!offstage) {
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
    return _CoveringPageTransition(
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
      return _CoveringPageTransition(
        contentKey: contentKey,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        workDetailTransition: workDetailTransition,
        child: routedChild,
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
