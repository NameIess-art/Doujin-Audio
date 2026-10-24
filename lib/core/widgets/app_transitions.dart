import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../ui/ui_interaction_coordinator.dart';
import 'app_edge_fade_mask.dart';

const kAppFadeDuration = Duration(milliseconds: 300);
const kAppFadeCurve = Curves.easeInOutCubic;
const kPlaceholderContentTransitionDuration = kAppFadeDuration;
const kAppMotionFast = Duration(milliseconds: 180);
const kAppMotionStandard = Duration(milliseconds: 220);
const kAppMotionSlow = Duration(milliseconds: 300);
const kAppSelectionDuration = Duration(milliseconds: 80);

/// Keeps the current badge until the preceding card motion has finished.
class AppDeferredFade extends StatefulWidget {
  const AppDeferredFade({
    super.key,
    required this.visible,
    required this.child,
    this.showDelay = Duration.zero,
    this.fadeInDuration = kAppFadeDuration,
    this.waitFor,
  });

  final bool visible;
  final Widget child;
  final Duration showDelay;
  final Duration fadeInDuration;
  final Animation<double>? waitFor;

  @override
  State<AppDeferredFade> createState() => _AppDeferredFadeState();
}

class _AppDeferredFadeState extends State<AppDeferredFade>
    with SingleTickerProviderStateMixin {
  late bool _visible;
  late bool _retained;
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  bool _delayComplete = true;
  bool _disableAnimations = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _visible = widget.visible && widget.waitFor?.isAnimating != true;
    _retained = _visible;
    _controller = AnimationController(
      vsync: this,
      duration: widget.fadeInDuration,
      reverseDuration: kAppFadeDuration,
      value: _visible ? 1 : 0,
    )..addStatusListener(_handleFadeStatus);
    _opacity = _controller.drive(CurveTween(curve: kAppFadeCurve));
    widget.waitFor?.addStatusListener(_handleMotionStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    if (_disableAnimations) {
      _timer?.cancel();
      _delayComplete = true;
      _visible = widget.visible;
      _retained = _visible;
      _controller.value = _visible ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(AppDeferredFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fadeInDuration != widget.fadeInDuration) {
      _controller.duration = widget.fadeInDuration;
    }
    if (oldWidget.waitFor != widget.waitFor) {
      oldWidget.waitFor?.removeStatusListener(_handleMotionStatus);
      widget.waitFor?.addStatusListener(_handleMotionStatus);
    }
    if (oldWidget.visible != widget.visible) {
      _timer?.cancel();
      _delayComplete =
          !widget.visible ||
          _retained ||
          _disableAnimations ||
          widget.showDelay == Duration.zero;
      if (_disableAnimations) {
        _visible = widget.visible;
        _retained = _visible;
        _controller.value = _visible ? 1 : 0;
      } else if (!_delayComplete) {
        // Material's color transition owns the highlight; no badge ticker is
        // needed while it is running. Cancelling selection cancels this wait.
        _timer = Timer(widget.showDelay, () {
          _delayComplete = true;
          _updateWhenReady();
        });
      }
    }
    _updateWhenReady();
  }

  void _handleMotionStatus(AnimationStatus status) {
    // Restarting a reorder passes through dismissed before moving forward.
    if (status == AnimationStatus.completed) _updateWhenReady();
  }

  void _updateWhenReady() {
    if (_visible != widget.visible &&
        _delayComplete &&
        (_disableAnimations || widget.waitFor?.isAnimating != true)) {
      setState(() {
        _visible = widget.visible;
        if (_visible) _retained = true;
      });
      if (_visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !_visible && _retained) {
      setState(() => _retained = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.waitFor?.removeStatusListener(_handleMotionStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: ExcludeFocus(
      excluding: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: _retained
            ? FadeTransition(opacity: _opacity, child: widget.child)
            : const SizedBox.shrink(),
      ),
    ),
  );
}

typedef _PageTransitionBuilder = Widget Function(BuildContext, Widget);

class AppNavigationInputLock extends StatefulWidget {
  const AppNavigationInputLock({
    super.key,
    required this.navigationAllowed,
    required this.child,
    this.onLockedKeyEvent,
  });

  final ValueListenable<bool> navigationAllowed;
  final Widget child;
  final ValueChanged<KeyEvent>? onLockedKeyEvent;

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

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (widget.navigationAllowed.value) return KeyEventResult.ignored;
    widget.onLockedKeyEvent?.call(event);
    return KeyEventResult.handled;
  }

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

// Headers keep their layout and inherited state inside the page. Only their
// painting moves above the navigator's sliding page backgrounds.
class AppPageTransitionHost extends SingleChildRenderObjectWidget {
  const AppPageTransitionHost({
    super.key,
    required super.child,
    this.enabled = true,
  });

  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPageTransitionHost(enabled);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPageTransitionHost).enabled = enabled;
  }
}

class _RenderPageTransitionHost extends RenderProxyBox {
  _RenderPageTransitionHost(this._enabled);

  final Set<_RenderPageHeader> headers = {};
  bool _enabled;

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    for (final header in headers) {
      header.markNeedsPaint();
    }
    markNeedsPaint();
  }

  int _comparePaintOrder(RenderObject first, RenderObject second) {
    List<RenderObject> path(RenderObject node) => [
      for (
        RenderObject? ancestor = node;
        ancestor != null;
        ancestor = ancestor.parent
      )
        ancestor,
    ];
    final firstPath = path(first).reversed.toList();
    final secondPath = path(second).reversed.toList();
    var index = 0;
    while (index < firstPath.length &&
        index < secondPath.length &&
        firstPath[index] == secondPath[index]) {
      index++;
    }
    if (index == firstPath.length || index == secondPath.length) {
      return firstPath.length.compareTo(secondPath.length);
    }
    final siblings = <RenderObject>[];
    firstPath[index - 1].visitChildren(siblings.add);
    return siblings
        .indexOf(firstPath[index])
        .compareTo(siblings.indexOf(secondPath[index]));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!enabled) return;
    // Cached tabs can reverse their Stack order without mounting new headers.
    final orderedHeaders = headers.toList()..sort(_comparePaintOrder);
    for (final header in orderedHeaders) {
      if (!header.attached || !header.hasSize || header.child == null) continue;
      header.updateAncestorAnimations();
      var visible = true;
      var prepared = false;
      var opacity = 1.0;
      for (
        RenderObject? ancestor = header.parent;
        ancestor != this;
        ancestor = ancestor.parent
      ) {
        if (ancestor == null ||
            ancestor is RenderOffstage && ancestor.offstage ||
            ancestor is RenderOpacity && ancestor.opacity == 0) {
          visible = false;
          break;
        }
        if (ancestor is RenderOpacity) opacity *= ancestor.opacity;
        if (ancestor is RenderAnimatedOpacity) {
          opacity *= ancestor.opacity.value;
          if (ancestor is _RenderPreparedHeaderOpacity) prepared = true;
        }
      }
      if (!visible || (opacity == 0 && !prepared)) continue;
      final viewport = header.viewport.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) continue;
      final clip = MatrixUtils.transformRect(
        viewport.getTransformTo(this),
        Offset.zero & viewport.size,
      );
      context.pushOpacity(offset, (opacity * 255).round(), (context, offset) {
        context.pushClipRect(needsCompositing, offset, clip, (context, offset) {
          context.pushTransform(
            needsCompositing,
            offset,
            header.getTransformTo(this),
            (context, offset) => context.paintChild(header.child!, offset),
          );
        });
      });
    }
  }
}

class _PageHeaderPaint extends SingleChildRenderObjectWidget {
  const _PageHeaderPaint({
    required this.host,
    required this.animation,
    required this.viewport,
    required super.child,
  });

  final _RenderPageTransitionHost host;
  final Listenable animation;
  final GlobalKey viewport;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPageHeader(host, animation, viewport);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPageHeader renderObject,
  ) {
    renderObject.update(host, animation, viewport);
  }
}

class _RenderPageHeader extends RenderProxyBox {
  _RenderPageHeader(this.host, this.animation, this.viewport);

  _RenderPageTransitionHost host;
  Listenable animation;
  GlobalKey viewport;
  final Set<Animation<double>> _ancestorAnimations = {};

  void updateAncestorAnimations() {
    final animations = <Animation<double>>{};
    for (
      RenderObject? ancestor = parent;
      ancestor != null && ancestor != host;
      ancestor = ancestor.parent
    ) {
      if (ancestor is RenderAnimatedOpacity) animations.add(ancestor.opacity);
    }
    for (final animation in _ancestorAnimations.difference(animations)) {
      animation.removeListener(host.markNeedsPaint);
    }
    for (final animation in animations.difference(_ancestorAnimations)) {
      animation.addListener(host.markNeedsPaint);
    }
    _ancestorAnimations
      ..clear()
      ..addAll(animations);
  }

  void update(
    _RenderPageTransitionHost nextHost,
    Listenable nextAnimation,
    GlobalKey nextViewport,
  ) {
    if (host == nextHost &&
        animation == nextAnimation &&
        viewport == nextViewport) {
      if (attached) updateAncestorAnimations();
      return;
    }
    if (attached) _unregister();
    host = nextHost;
    animation = nextAnimation;
    viewport = nextViewport;
    if (attached) _register();
    markNeedsPaint();
  }

  void _register() {
    host.headers.add(this);
    animation.addListener(host.markNeedsPaint);
    // Ancestor fades normally update only their own composited opacity layer.
    // Lifted headers paint outside that layer and must repaint on those ticks.
    updateAncestorAnimations();
    host.markNeedsPaint();
  }

  void _unregister() {
    for (final animation in _ancestorAnimations) {
      animation.removeListener(host.markNeedsPaint);
    }
    _ancestorAnimations.clear();
    host.headers.remove(this);
    animation.removeListener(host.markNeedsPaint);
    host.markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _register();
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }

  @override
  void markNeedsPaint() {
    super.markNeedsPaint();
    if (attached) host.markNeedsPaint();
  }

  @override
  void markNeedsLayout() {
    super.markNeedsLayout();
    if (attached) host.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Layout, semantics and hit testing stay in the page; modal routes use the
    // original paint location so their barrier can cover the header.
    if (!host.enabled) super.paint(context, offset);
  }
}

// Animation ownership stays with the route/tab; regions only choose which
// transition to display, without moving header state out of its page.
class _AppPageMotionScope extends InheritedWidget {
  const _AppPageMotionScope({
    super.key,
    required this.contentBuilder,
    required this.headerBuilder,
    required this.headerAnimation,
    required this.headerViewport,
    this.configuration,
    required super.child,
  });

  final _PageTransitionBuilder contentBuilder;
  final _PageTransitionBuilder headerBuilder;
  final Listenable headerAnimation;
  final GlobalKey headerViewport;
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
       _placeholder = null,
       prepared = false,
       isReady = true;

  const AppPageContentTransition.deferred({
    super.key,
    required WidgetBuilder builder,
    required Widget placeholder,
    this.backgroundColor,
    this.isReady = true,
    this.prepared = false,
  }) : child = const SizedBox.shrink(),
       _builder = builder,
       _placeholder = placeholder;

  final Widget child;
  final Color? backgroundColor;

  /// Gates the first content mount; later visits retain the loaded subtree.
  final bool isReady;

  /// A valid cached snapshot may mount in the existing route preparation frame.
  final bool prepared;
  final WidgetBuilder? _builder;
  final Widget? _placeholder;

  @override
  Widget build(BuildContext context) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    final body = _builder == null
        ? child
        : _DeferredPageContent(
            builder: _builder,
            placeholder: _placeholder!,
            isReady: isReady,
            prepared: prepared,
          );
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
    required this.isReady,
    required this.prepared,
  });

  final WidgetBuilder builder;
  final Widget placeholder;
  final bool isReady;
  final bool prepared;

  @override
  State<_DeferredPageContent> createState() => _DeferredPageContentState();
}

class _DeferredPageContentState extends State<_DeferredPageContent> {
  final _coordinator = UiInteractionCoordinator.instance;
  late final _commitKey = 'page_content_${identityHashCode(this)}';
  late Builder _content;
  Animation<double>? _routeAnimation;
  bool _firstFrameBuilt = false;
  bool _active = false;
  bool _ready = false;
  bool _commitScheduled = false;

  @override
  void initState() {
    super.initState();
    // Motion changes reuse this element; its own inherited dependencies still
    // rebuild the body when theme or layout inputs change.
    _content = Builder(builder: widget.builder);
    if (widget.prepared && widget.isReady) {
      _ready = true;
      return;
    }
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

  @override
  void didUpdateWidget(_DeferredPageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.builder != widget.builder) {
      _content = Builder(builder: widget.builder);
    }
    if (oldWidget.isReady != widget.isReady) _scheduleContent();
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
        !widget.isReady ||
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
      structural: true,
      commit: () {
        _commitScheduled = false;
        if (!mounted ||
            !widget.isReady ||
            !_active ||
            !_routeReady ||
            _coordinator.isVisualUpdateDeferred) {
          return;
        }
        // Preparing only the shell lets entrance motion start without laying
        // out cached lists. Later visits keep the mounted content and its state.
        setState(() => _ready = true);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlaceholderContentTransition(
      showPlaceholder: !_ready,
      placeholder: TickerMode(
        key: const ValueKey('deferred_placeholder'),
        enabled: false,
        child: widget.placeholder,
      ),
      content: _ready
          ? KeyedSubtree(
              key: const ValueKey('deferred_content'),
              child: _content,
            )
          : const SizedBox.shrink(),
    );
  }
}

class AppPageHeaderTransition extends StatelessWidget {
  const AppPageHeaderTransition({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    // Transparent gaps belong to the header too; stop sibling hit testing
    // without competing with gestures owned by its controls or ancestors.
    final hitRegion = Listener(behavior: HitTestBehavior.opaque, child: child);
    if (motion == null) return hitRegion;
    final header = motion.headerBuilder(context, hitRegion);
    final host = context
        .findAncestorRenderObjectOfType<_RenderPageTransitionHost>();
    if (host == null) return header;
    return _PageHeaderPaint(
      host: host,
      animation: motion.headerAnimation,
      viewport: motion.headerViewport,
      child: RepaintBoundary(child: header),
    );
  }
}

class _CoveringPageTransition extends StatefulWidget {
  const _CoveringPageTransition({
    required this.contentKey,
    required this.animation,
    required this.secondaryAnimation,
    this.animatePage = true,
    this.slide = true,
    this.separateHeader = false,
    required this.child,
  });

  final GlobalKey contentKey;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final bool animatePage;
  final bool slide;
  final bool separateHeader;
  final Widget child;

  @override
  State<_CoveringPageTransition> createState() =>
      _CoveringPageTransitionState();
}

// Record headers in the preparation frame even at zero opacity, so their first
// visible fade tick does not introduce the glass and control paint work.
class _PreparedHeaderFadeTransition extends FadeTransition {
  const _PreparedHeaderFadeTransition({
    required super.opacity,
    required super.child,
  });

  @override
  RenderAnimatedOpacity createRenderObject(BuildContext context) =>
      _RenderPreparedHeaderOpacity(opacity: opacity);
}

class _RenderPreparedHeaderOpacity extends RenderAnimatedOpacity {
  _RenderPreparedHeaderOpacity({required super.opacity});

  @override
  bool get isRepaintBoundary => child != null;

  @override
  bool paintsChild(RenderObject child) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null) context.paintChild(child!, offset);
  }
}

class _CoveringPageTransitionState extends State<_CoveringPageTransition> {
  CurvedAnimation? _motion;
  late final ValueNotifier<Widget> _pageChild;
  final _headerViewport = GlobalKey();
  late Animation<Offset> _position;
  late Animation<double> _opacity;
  late Listenable _headerAnimation;
  Animation<double>? _routeSecondaryAnimation;
  late bool _interactive;
  Widget? _transition;

  bool get _isInteractive =>
      widget.animation.status == AnimationStatus.completed &&
      _secondaryAnimation.status == AnimationStatus.dismissed;

  Animation<double> get _secondaryAnimation =>
      _routeSecondaryAnimation ?? widget.secondaryAnimation;

  @override
  void initState() {
    super.initState();
    _pageChild = ValueNotifier(widget.child);
    _updateAnimations();
    _interactive = _isInteractive;
    widget.animation.addStatusListener(_handleStatusChanged);
    _secondaryAnimation.addStatusListener(_handleStatusChanged);
  }

  void _updateAnimations() {
    _motion?.dispose();
    // Both directions settle with deceleration. CurvedAnimation retains the
    // entrance curve when an unfinished push reverses, avoiding a position jump.
    _motion = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic.flipped,
    );
    _position = _motion!.drive(
      Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero),
    );
    _opacity = widget.animation.drive(CurveTween(curve: kAppFadeCurve));
    _updateHeaderAnimation();
  }

  void _updateHeaderAnimation() {
    _headerAnimation = Listenable.merge([
      widget.animation,
      _secondaryAnimation,
    ]);
  }

  @override
  void didUpdateWidget(_CoveringPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Flutter refreshes its gesture-listening child wrapper on each route tick.
    // Update that leaf without invalidating the retained motion/activity tree.
    _pageChild.value = widget.child;
    // Material's delegated transition can supply a fresh dismissed proxy on
    // every tick. The route's real secondary animation still owns this page;
    // its proxy must not replace either the listeners or the retained tree.
    final primaryChanged = oldWidget.animation != widget.animation;
    final secondaryChanged =
        _routeSecondaryAnimation == null &&
        oldWidget.secondaryAnimation != widget.secondaryAnimation;
    if (primaryChanged) {
      oldWidget.animation.removeStatusListener(_handleStatusChanged);
      widget.animation.addStatusListener(_handleStatusChanged);
      _updateAnimations();
    }
    if (secondaryChanged) {
      oldWidget.secondaryAnimation.removeStatusListener(_handleStatusChanged);
      _secondaryAnimation.addStatusListener(_handleStatusChanged);
      if (!primaryChanged) _updateHeaderAnimation();
    }
    if (primaryChanged || secondaryChanged) {
      _interactive = _isInteractive;
      _transition = null;
    }
    if (oldWidget.animatePage != widget.animatePage ||
        oldWidget.slide != widget.slide ||
        oldWidget.separateHeader != widget.separateHeader ||
        oldWidget.contentKey != widget.contentKey) {
      _transition = null;
    }
  }

  void _handleStatusChanged(AnimationStatus _) {
    final interactive = _isInteractive;
    if (_interactive == interactive) return;
    setState(() {
      _interactive = interactive;
      _transition = null;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MaterialPageRoute replaces the original secondary animation with a
    // dismissed proxy when it delegates transitions to the incoming route.
    // Read the route's real animation so its header still fades when covered.
    final previousSecondary = _secondaryAnimation;
    final secondaryAnimation = ModalRoute.of(context)?.secondaryAnimation;
    _routeSecondaryAnimation = secondaryAnimation;
    if (identical(previousSecondary, _secondaryAnimation)) return;
    previousSecondary.removeStatusListener(_handleStatusChanged);
    _secondaryAnimation.addStatusListener(_handleStatusChanged);
    _interactive = _isInteractive;
    _updateHeaderAnimation();
    _transition = null;
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleStatusChanged);
    _secondaryAnimation.removeStatusListener(_handleStatusChanged);
    _motion?.dispose();
    _pageChild.dispose();
    super.dispose();
  }

  Widget _buildTransition() => _buildPageActivity(
    ClipRect(
      key: _headerViewport,
      child: LayoutBuilder(builder: _buildPage),
    ),
    interactive: _interactive,
  );

  Widget _buildPage(BuildContext context, BoxConstraints constraints) {
    final animatePage =
        widget.animatePage && !MediaQuery.disableAnimationsOf(context);
    final page = _AppPageMotionScope(
      key: widget.contentKey,
      headerAnimation: _headerAnimation,
      headerViewport: _headerViewport,
      configuration: (
        widget.animation,
        _secondaryAnimation,
        constraints.maxWidth,
        animatePage,
        widget.slide,
        widget.separateHeader,
      ),
      contentBuilder: (context, content) {
        final body = RepaintBoundary(child: content);
        if (!widget.separateHeader || !animatePage) return body;
        return widget.slide
            ? SlideTransition(position: _position, child: body)
            : FadeTransition(opacity: _opacity, child: body);
      },
      headerBuilder: (context, header) => AnimatedBuilder(
        animation: _headerAnimation,
        child: RepaintBoundary(child: header),
        builder: (context, header) {
          final outgoing = kAppFadeCurve.transform(_secondaryAnimation.value);
          final coveredHeader = Opacity(opacity: 1 - outgoing, child: header);
          if (!animatePage || (!widget.slide && !widget.separateHeader)) {
            return coveredHeader;
          }
          final fadedHeader = _PreparedHeaderFadeTransition(
            opacity: _opacity,
            child: coveredHeader,
          );
          if (widget.separateHeader || !widget.slide) {
            return fadedHeader;
          }
          // Unseparated pages slide as a whole; keep their header in place
          // while its own opacity follows the route instead of the body.
          return Transform.translate(
            offset: Offset(-constraints.maxWidth * _position.value.dx, 0),
            child: fadedHeader,
          );
        },
      ),
      child: ValueListenableBuilder<Widget>(
        valueListenable: _pageChild,
        builder: (_, child, _) => child,
      ),
    );
    if (!animatePage || widget.separateHeader) return page;
    return widget.slide
        ? SlideTransition(
            position: _position,
            child: RepaintBoundary(child: page),
          )
        : _PreparedHeaderFadeTransition(
            opacity: _opacity,
            child: RepaintBoundary(child: page),
          );
  }

  @override
  Widget build(BuildContext context) {
    // Route builders run on every tick. Reuse the region tree and animations;
    // only its transform/opacity render objects need animation updates.
    return _transition ??= _buildTransition();
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
      duration: kAppFadeDuration,
      value: _secondary == null ? 0 : 1,
    )..addStatusListener(_handleStatus);
    _opacity = _controller.drive(CurveTween(curve: kAppFadeCurve));
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
  const AppHeaderTransition({
    super.key,
    required this.child,
    this.showBackground = true,
  });

  final Widget child;
  final bool showBackground;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppFadeDuration;
    final controls = AnimatedSwitcher(
      duration: duration,
      switchInCurve: kAppFadeCurve,
      switchOutCurve: kAppFadeCurve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AppPageHeaderTransition(child: child),
      ),
      // Only the current header sets the target height. A taller outgoing
      // header must not postpone shrinking until its fade completes.
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.topLeft,
        clipBehavior: Clip.none,
        children: [
          for (final previous in previousChildren)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ExcludeSemantics(child: IgnorePointer(child: previous)),
            ),
          ?currentChild,
        ],
      ),
      child: child,
    );
    return Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.topLeft,
      children: [
        if (showBackground)
          const Positioned.fill(
            child: AppPageHeaderTransition(
              child: AppEdgeFadeMask(
                direction: AppEdgeFadeDirection.towardTop,
              ),
            ),
          ),
        if (duration == Duration.zero)
          controls
        else
          AnimatedSize(
            alignment: Alignment.topCenter,
            duration: duration,
            curve: kAppFadeCurve,
            clipBehavior: Clip.none,
            child: controls,
          ),
      ],
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
    this.fit = StackFit.expand,
  });

  final bool showPlaceholder;
  final Widget placeholder;
  final Widget content;
  final Duration duration;
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
  bool _fading = false;
  int _fadeGeneration = 0;
  Widget? _departingContent;
  final _interaction = UiInteractionCoordinator.instance;

  bool get _skipMotion =>
      widget.duration == Duration.zero ||
      MediaQuery.disableAnimationsOf(context) ||
      !TickerMode.valuesOf(context).enabled ||
      ModalRoute.isCurrentOf(context) == false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.showPlaceholder ? 0 : 1,
    )..addStatusListener(_handleAnimationStatus);
    _contentOpacity = _controller.drive(CurveTween(curve: kAppFadeCurve));
    _placeholderOpacity = ReverseAnimation(_contentOpacity);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (!_fading ||
        !mounted ||
        (status != AnimationStatus.completed &&
            status != AnimationStatus.dismissed)) {
      return;
    }
    _interaction.endInteraction(_controller);
    setState(() {
      _fading = false;
      _departingContent = null;
    });
  }

  void _cancelFade() {
    _fadeGeneration++;
    _fading = false;
    _controller.stop();
    _controller.value = widget.showPlaceholder ? 0 : 1;
    _departingContent = null;
    _interaction.cancelInteraction(_controller);
  }

  void _prepareFade() {
    final generation = ++_fadeGeneration;
    _fading = true;
    _controller.stop();
    // Mount and lay out the incoming subtree before its first visible tick.
    // Reversing keeps the current opacity instead of restarting either fade.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _fadeGeneration) return;
      if (_skipMotion) {
        setState(_cancelFade);
        return;
      }
      _interaction.beginInteraction(_controller, deferVisualUpdates: true);
      if (widget.showPlaceholder) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_skipMotion) _cancelFade();
  }

  @override
  void didUpdateWidget(covariant PlaceholderContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.showPlaceholder != widget.showPlaceholder) {
      _departingContent = widget.showPlaceholder ? oldWidget.content : null;
      if (_skipMotion) {
        _cancelFade();
      } else {
        _prepareFade();
      }
    }
  }

  @override
  void deactivate() {
    _cancelFade();
    super.deactivate();
  }

  @override
  void dispose() {
    _fadeGeneration++;
    _interaction.cancelInteraction(_controller);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _departingContent ?? widget.content;
    return Stack(
      fit: widget.fit,
      children: [
        if (widget.showPlaceholder || _fading)
          IgnorePointer(
            key: const ValueKey('placeholder_transition_placeholder'),
            ignoring: !widget.showPlaceholder,
            child: ExcludeFocus(
              excluding: !widget.showPlaceholder,
              child: ExcludeSemantics(
                excluding: !widget.showPlaceholder,
                child: FadeTransition(
                  opacity: _placeholderOpacity,
                  child: widget.placeholder,
                ),
              ),
            ),
          ),
        if (!widget.showPlaceholder || _fading)
          IgnorePointer(
            key: const ValueKey('placeholder_transition_content'),
            ignoring: widget.showPlaceholder,
            child: ExcludeFocus(
              excluding: widget.showPlaceholder,
              child: ExcludeSemantics(
                excluding: widget.showPlaceholder,
                child: FadeTransition(opacity: _contentOpacity, child: content),
              ),
            ),
          ),
      ],
    );
  }
}

class SecondaryOverlayConfig {
  const SecondaryOverlayConfig({
    this.backgroundOpacity = 0.80,
    this.transitionDuration = kAppFadeDuration,
    this.reverseTransitionDuration = kAppFadeDuration,
    this.curve = kAppFadeCurve,
    this.reverseCurve = kAppFadeCurve,
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
        duration: kAppFadeDuration,
        curve: kAppFadeCurve,
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
    this.duration = kAppFadeDuration,
    this.curve = kAppFadeCurve,
    this.reverseCurve = kAppFadeCurve,
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
  Curve curve = kAppFadeCurve,
  Curve reverseCurve = kAppFadeCurve,
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
  Curve curve = kAppFadeCurve,
  Curve reverseCurve = kAppFadeCurve,
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
  const AppFadeThroughIndexedStack.lazy({
    super.key,
    required this.indexListenable,
    required this.itemCount,
    required this.itemBuilder,
    this.contentRevision,
    this.separateHeader = false,
    this.duration = kAppFadeDuration,
    this.onTransitionCompleted,
  });

  final ValueListenable<int> indexListenable;
  int get index => indexListenable.value;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

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
  late Animation<double> _headerProgress;
  late Animation<double> _reverseProgress;
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
  final _headerViewport = GlobalKey();
  final Set<int> _preparedPages = {};
  BoxConstraints? _preparedConstraints;
  int? _pendingIndex;

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
    _headerProgress = _controller.drive(CurveTween(curve: kAppFadeCurve));
    _reverseProgress = ReverseAnimation(_headerProgress);
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
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
      _controller.reverseDuration = widget.duration;
    }
    if (!identical(oldWidget.indexListenable, widget.indexListenable)) {
      oldWidget.indexListenable.removeListener(_handleIndexChanged);
      widget.indexListenable.addListener(_handleIndexChanged);
      _handleIndexChanged();
    }
    if (_itemCount != oldWidget.itemCount) {
      _resetLazyChildren();
      _handleIndexChanged();
    } else if (widget.contentRevision != oldWidget.contentRevision) {
      for (var index = 0; index < _itemCount; index++) {
        if (_lazyChildren[index] != null) {
          _dirtyChildren.add(index);
          _preparedPages.remove(index);
        }
      }
    }
    if (widget.duration == Duration.zero &&
        (_isAnimating || _pendingIndex != null)) {
      _switchImmediately(_safeIndex(widget.indexListenable.value));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Hidden stacks have muted tickers. Finish immediately so a restore or
    // enclosing navigation cannot leave the global navigation lock held.
    if ((!TickerMode.valuesOf(context).enabled ||
            MediaQuery.disableAnimationsOf(context)) &&
        (_isAnimating || _pendingIndex != null)) {
      _switchImmediately(_safeIndex(widget.indexListenable.value));
    }
  }

  void _switchImmediately(int index) {
    _controller.stop();
    setState(() {
      _pendingIndex = null;
      _currentIndex = index;
      _targetIndex = index;
      _isAnimating = false;
      _controller.value = 1;
    });
    widget.onTransitionCompleted?.call(index);
    UiInteractionCoordinator.instance.endNavigation(_transitionInteraction);
  }

  void _resetLazyChildren() {
    final previousKeys = _pageKeys;
    final previousChildren = _lazyChildren;
    _lazyChildren = List<Widget?>.generate(
      _itemCount,
      (index) =>
          index < previousChildren.length && previousChildren[index] != null
          ? widget.itemBuilder(context, index)
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
        !TickerMode.getValuesNotifier(context).value.enabled ||
        MediaQuery.disableAnimationsOf(context)) {
      _switchImmediately(nextIndex);
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
      final nextValue = 1 - math.sqrt(progress);
      final fadeAnchor = 1 - _headerProgress.value;
      // Header fade and body slide use different curves. Preserve the visible
      // header's opacity when its incoming role becomes outgoing.
      _headerProgress = _controller.drive(
        nextValue > 0 && nextValue < 1
            ? TweenSequence<double>([
                TweenSequenceItem(
                  tween: Tween(
                    begin: 0.0,
                    end: fadeAnchor,
                  ).chain(CurveTween(curve: kAppFadeCurve)),
                  weight: nextValue,
                ),
                TweenSequenceItem(
                  tween: Tween(
                    begin: fadeAnchor,
                    end: 1.0,
                  ).chain(CurveTween(curve: kAppFadeCurve)),
                  weight: 1 - nextValue,
                ),
              ])
            : CurveTween(curve: kAppFadeCurve),
      );
      _reverseProgress = ReverseAnimation(_headerProgress);
      setState(() {
        _currentIndex = _targetIndex;
        _targetIndex = nextIndex;
        _transitionDirection = direction;
      });
      _controller.forward(from: nextValue);
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

    _headerProgress = _controller.drive(CurveTween(curve: kAppFadeCurve));
    _reverseProgress = ReverseAnimation(_headerProgress);
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
      _lazyChildren[index] = widget.itemBuilder(context, index);
    }
    return _lazyChildren[index] ??= widget.itemBuilder(context, index);
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
    final opacity = preparing
        ? const AlwaysStoppedAnimation<double>(0)
        : outgoing
        ? _reverseProgress
        : incoming
        ? _headerProgress
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
    final parentMotion = context
        .dependOnInheritedWidgetOfExactType<_AppPageMotionScope>();
    return KeyedSubtree(
      key: ValueKey<String>('app_indexed_page_$index'),
      child: _AppPageMotionScope(
        headerAnimation: Listenable.merge([
          _controller,
          parentMotion?.headerAnimation,
        ]),
        headerViewport: parentMotion?.headerViewport ?? _headerViewport,
        configuration: (
          animation,
          outgoing,
          incoming,
          preparing,
          opacity,
          outgoing || incoming || preparing ? _transitionDirection : 0,
          parentMotion?.configuration,
        ),
        contentBuilder: (context, content) {
          final animated = SlideTransition(
            position: position,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: RepaintBoundary(child: content),
            ),
          );
          // A nested retained stack owns its own switch, while its body still
          // participates when an enclosing navigation stack changes pages.
          return parentMotion?.contentBuilder(context, animated) ?? animated;
        },
        headerBuilder: (context, header) {
          final faded = _PreparedHeaderFadeTransition(
            opacity: opacity,
            child: header,
          );
          return parentMotion?.headerBuilder(context, faded) ?? faded;
        },
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
            _lazyChildren[index] != null)
          index,
      _currentIndex,
      if (_isAnimating && _targetIndex != _currentIndex) _targetIndex,
      if (_pendingIndex != null &&
          _pendingIndex != _targetIndex &&
          _pendingIndex != _currentIndex)
        _pendingIndex!,
    ];
    final pages = IgnorePointer(
      ignoring: _isAnimating || _pendingIndex != null,
      child: ClipRect(
        key: _headerViewport,
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
    return context
                .findAncestorRenderObjectOfType<_RenderPageTransitionHost>() ==
            null
        ? AppPageTransitionHost(child: pages)
        : pages;
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

// Keep the delegate transparent: adding activity wrappers here reparents the
// entire Material route when Flutter installs/removes its received transition.
// The existing page transition observes the real secondary animation instead.
Widget _coveredPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  bool allowSnapshotting,
  Widget? child,
) => child!;

/// Reads route identity for event handlers without subscribing their page to
/// isCurrent/canPop changes. Reactive visibility belongs in a local Builder.
ModalRoute<dynamic>? readAppRoute(BuildContext context) {
  final reference = context.getInheritedWidgetOfExactType<_AppRouteReference>();
  // A popup or an unmanaged route in a nested Navigator must not borrow the
  // surrounding Navigator's route. Its normal Flutter lookup remains valid.
  if (reference != null &&
      identical(reference.route.navigator, Navigator.maybeOf(context))) {
    return reference.route;
  }
  return ModalRoute.of(context);
}

class _AppRouteReference extends InheritedWidget {
  const _AppRouteReference({required this.route, required super.child});

  final ModalRoute<dynamic> route;

  @override
  bool updateShouldNotify(_AppRouteReference oldWidget) =>
      route != oldWidget.route;
}

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  DelegatedTransitionBuilder get delegatedTransition => _coveredPageTransition;

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
      child: _AppRouteReference(route: route, child: child),
    );
  }
}

PageRouteBuilder<T> buildAppPageRoute<T>({
  required BuildContext context,
  required Widget child,
  RouteSettings? settings,
  Duration duration = kAppMotionSlow,
  bool fullscreenDialog = false,
  bool slide = true,
  // Opt in only when the page marks its body with AppPageContentTransition.
  bool separateHeader = false,
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
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, routedChild) {
      // Instant pages still track their header when another route covers them.
      return _CoveringPageTransition(
        contentKey: contentKey,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        animatePage: duration != Duration.zero,
        slide: slide,
        separateHeader: separateHeader,
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
  });

  bool _prepared = false;
  bool _disposed = false;
  Timer? _exitCompletionTimer;

  // Match the theme delegate without introducing a second activity subtree.
  @override
  DelegatedTransitionBuilder get delegatedTransition => _coveredPageTransition;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isActive) _prepared = true;
    });
    return _AppRouteReference(
      route: this,
      child: super.buildPage(context, animation, secondaryAnimation),
    );
  }

  @override
  Simulation? createSimulation({required bool forward}) {
    if (!forward &&
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
    this.duration = kAppFadeDuration,
    this.curve = kAppFadeCurve,
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
