import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Gives a view that uses its implicit vertical controller its own wheel animation.
extension WindowsSmoothScroll on Widget {
  Widget withWindowsSmoothScroll() =>
      defaultTargetPlatform == TargetPlatform.windows
      ? _WindowsPrimaryScrollController(child: this)
      : this;
}

class _WindowsPrimaryScrollController extends StatefulWidget {
  const _WindowsPrimaryScrollController({required this.child});

  final Widget child;

  @override
  State<_WindowsPrimaryScrollController> createState() =>
      _WindowsPrimaryScrollControllerState();
}

class _WindowsPrimaryScrollControllerState
    extends State<_WindowsPrimaryScrollController> {
  final _controller = WindowsSmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PrimaryScrollController(
    controller: _controller,
    automaticallyInheritForPlatforms: const {TargetPlatform.windows},
    child: widget.child,
  );
}

/// Smooths Windows wheel input while retaining the standard scroll position elsewhere.
class WindowsSmoothScrollController extends ScrollController {
  WindowsSmoothScrollController({super.keepScrollOffset});

  bool get isWheelScrolling =>
      positions.length == 1 &&
      position is _WindowsSmoothScrollPosition &&
      (position as _WindowsSmoothScrollPosition).isWheelScrolling;

  /// Scrolls to a wheel-selected item whose offset is already known.
  void scrollWheelTo(double offset) {
    if (positions.length != 1) return;
    final current = position;
    if (current is _WindowsSmoothScrollPosition) {
      current.scrollWheelTo(offset);
    } else {
      current.jumpTo(offset);
    }
  }

  /// Flutter leaves an outward wheel event unclaimed at the visible edge.
  /// Claim it when it would cancel an inward scroll that is still pending.
  Widget handleWheelReversal(BuildContext context, Widget child) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent || positions.length != 1) return;
        final current = position;
        if (current is! _WindowsSmoothScrollPosition ||
            !current.isWheelScrolling ||
            !current.atEdge) {
          return;
        }
        var axis = current.axis;
        if (event.kind == PointerDeviceKind.mouse &&
            HardwareKeyboard.instance.logicalKeysPressed.any(
              ScrollConfiguration.of(context).pointerAxisModifiers.contains,
            )) {
          axis = flipAxis(axis);
        }
        var delta = axis == Axis.vertical
            ? event.scrollDelta.dy
            : event.scrollDelta.dx;
        if (axisDirectionIsReversed(current.axisDirection)) delta = -delta;
        if (current.isPendingEdgeReversal(delta)) {
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            current.pointerScroll(delta);
          });
        }
      },
      child: child,
    );
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return super.createScrollPosition(physics, context, oldPosition);
    }
    return _WindowsSmoothScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
    );
  }
}

class _WindowsSmoothScrollPosition extends ScrollPositionWithSingleContext {
  _WindowsSmoothScrollPosition({
    required super.physics,
    required super.context,
    required super.oldPosition,
    required super.initialPixels,
    required super.keepScrollOffset,
  });

  bool get isWheelScrolling => activity is _WheelScrollActivity;

  bool get _disableAnimations =>
      MediaQuery.maybeDisableAnimationsOf(context.storageContext) ?? false;

  bool isPendingEdgeReversal(double delta) {
    final current = activity;
    return current is _WheelScrollActivity &&
        (current.target - pixels) * delta < 0 &&
        (pixels + delta).clamp(minScrollExtent, maxScrollExtent) == pixels &&
        physics.shouldAcceptUserOffset(this);
  }

  @override
  void pointerScroll(double delta) {
    if (delta == 0 || _disableAnimations) {
      super.pointerScroll(delta);
      return;
    }

    final current = activity;
    if (current is DragScrollActivity) return;

    // A reversal starts from the visible offset and drops the untraveled
    // distance in the old direction.
    final base =
        current is _WheelScrollActivity && (current.target - pixels) * delta > 0
        ? current.target
        : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    scrollWheelTo(target);
  }

  void scrollWheelTo(double target) {
    if (_disableAnimations) {
      jumpTo(target);
      return;
    }
    final current = activity;
    if (target == pixels) {
      if (current is _WheelScrollActivity) goIdle();
      return;
    }
    if (current is _WheelScrollActivity && current.target == target) return;

    updateUserScrollDirection(
      target < pixels ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    if (current is _WheelScrollActivity) {
      current.retarget(pixels, target);
      return;
    }
    beginActivity(
      _WheelScrollActivity(
        this,
        _WheelScrollSimulation(pixels, target),
        vsync: context.vsync,
      ),
    );
  }

  @override
  void correctPixels(double value) {
    final current = activity;
    if (current is _WheelScrollActivity) {
      current.shift(value - pixels);
    }
    super.correctPixels(value);
  }
}

class _WheelScrollActivity extends DrivenScrollActivity {
  _WheelScrollActivity(
    ScrollActivityDelegate delegate,
    this._simulation, {
    required super.vsync,
  }) : super.simulation(delegate, _simulation);

  final _WheelScrollSimulation _simulation;
  double get target => _simulation.target;

  void retarget(double from, double target) {
    final speed = velocity;
    _simulation.retarget(from, target, speed);
  }

  void shift(double offset) => _simulation.shift(offset);

  // Nested wheel regions and clickable rows must stay hit-testable in motion.
  @override
  bool get shouldIgnorePointer => false;
}

class _WheelScrollSimulation extends Simulation {
  _WheelScrollSimulation(this._from, this.target);

  static const _baseSeconds = 0.2;
  static const _maxRetargetSeconds = 0.25;
  static const _startingSlope = 1.62;
  double _from;
  double target;
  double _duration = _baseSeconds;
  double _initialSlope = _startingSlope;
  double _startTime = 0;
  double _lastSampleTime = 0;
  bool _hasMoved = false;
  double? _sameFrameVelocity;

  void retarget(double from, double nextTarget, double velocity) {
    final distance = nextTarget - from;
    // Anchor at the last rendered sample so the next tick advances immediately.
    _startTime = _lastSampleTime;
    _from = from;
    target = nextTarget;
    if (!_hasMoved) {
      // Multiple wheel ticks arriving before the first motion frame accumulate
      // into the same launch from rest; keep full starting slope instead of
      // diluting it by the larger combined distance.
      _duration = _baseSeconds;
      _initialSlope = _startingSlope;
      _sameFrameVelocity = null;
      return;
    }
    final incomingVelocity = _sameFrameVelocity ?? velocity;
    _sameFrameVelocity = incomingVelocity;
    if (incomingVelocity * distance > 0) {
      // Slightly extend duration when rapid notches stack large remaining
      // travel so cubic Hermite stays smooth without mid-step velocity pulsing,
      // while keeping exact C1 velocity continuity at t = 0.
      final absDistance = distance.abs();
      final extra = ((absDistance - 80.0) / 320.0).clamp(0.0, 1.0);
      _duration =
          _baseSeconds + (_maxRetargetSeconds - _baseSeconds) * extra;
      _initialSlope = (incomingVelocity * _duration / distance).clamp(
        0.0,
        3.0,
      );
    } else {
      _duration = _baseSeconds;
      _initialSlope = _startingSlope;
    }
  }

  void shift(double offset) {
    _from += offset;
    target += offset;
  }

  // Cubic Hermite interpolation joins the incoming velocity to a full stop.
  @override
  double x(double time) {
    if (time > _lastSampleTime) {
      _hasMoved = true;
      _sameFrameVelocity = null;
    }
    _lastSampleTime = time;
    if (isDone(time)) return target;
    final t = (time - _startTime) / _duration;
    final remaining = 1 - t;
    final progress =
        t * t * (3 - 2 * t) + _initialSlope * t * remaining * remaining;
    return _from + (target - _from) * progress;
  }

  @override
  double dx(double time) {
    if (isDone(time)) return 0;
    final t = (time - _startTime) / _duration;
    final slope = (1 - t) * (6 * t + _initialSlope * (1 - 3 * t));
    return (target - _from) * slope / _duration;
  }

  @override
  bool isDone(double time) => time >= _startTime + _duration;
}
