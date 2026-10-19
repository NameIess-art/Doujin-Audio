import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_orientation_controller.dart';
import '../../../../core/widgets/app_transitions.dart';
import 'session_detail_page.dart';

PageRoute<void> buildSessionDetailRoute({required String sessionId}) {
  return SessionDetailRoute(sessionId: sessionId);
}

class SessionDetailRoute extends AppPreparedPageRoute<void> {
  SessionDetailRoute({required String sessionId})
    : this._(sessionId, ValueNotifier<bool>(false));

  SessionDetailRoute._(this.sessionId, this._revealBehindNotifier)
    : super(
        transitionDuration: kAppMotionSlow,
        reverseTransitionDuration: kAppMotionSlow,
        pageBuilder: (context, animation, secondaryAnimation) =>
            SessionDetailPage(
              sessionId: sessionId,
              revealBehindNotifier: _revealBehindNotifier,
              routeAnimation: animation,
            ),
        transitionsBuilder: (_, animation, secondaryAnimation, child) => child,
      ) {
    _revealBehindNotifier.addListener(_handleRevealBehindChanged);
  }

  final String sessionId;
  final ValueNotifier<bool> _revealBehindNotifier;
  bool _reducedMotion = false;
  FlutterView? _view;
  AppOrientationController? _orientationController;
  Completer<void>? _portraitReady;
  Future<void>? _exitPreparation;
  bool _popPending = false;

  bool get preparingForExit => _exitPreparation != null;

  bool get requiresPortraitRestore {
    final view = _view;
    if (defaultTargetPlatform != TargetPlatform.android || view == null) {
      return false;
    }
    final display = view.display;
    return AppOrientationPolicy.forDisplay(
              platform: TargetPlatform.android,
              shortestSide:
                  display.size.shortestSide / display.devicePixelRatio,
            ) ==
            AppOrientationPolicy.portrait &&
        view.physicalSize.width > view.physicalSize.height;
  }

  Future<void> prepareForExit() {
    if (!requiresPortraitRestore) return Future<void>.value();
    return _exitPreparation ??= _restorePortrait();
  }

  Future<void> _restorePortrait() async {
    final ready = _portraitReady = Completer<void>();
    try {
      await _orientationController!.setPlaybackDetailVisible(false);
      // The platform call acknowledges the request before Android resizes the
      // Flutter view. Keep the detail opaque until a portrait frame is laid out.
      if (requiresPortraitRestore) await ready.future;
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _portraitReady = null;
      _exitPreparation = null;
    }
  }

  void didChangeMetrics() {
    final ready = _portraitReady;
    if (ready != null && !ready.isCompleted && !requiresPortraitRestore) {
      ready.complete();
    }
  }

  @override
  bool didPop(void result) {
    if (!requiresPortraitRestore) return super.didPop(result);
    if (!_popPending) {
      _popPending = true;
      unawaited(
        prepareForExit().then((_) {
          _popPending = false;
          if (isCurrent) navigator?.pop();
        }),
      );
    }
    return false;
  }

  @override
  Duration get transitionDuration =>
      _reducedMotion ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _reducedMotion ? Duration.zero : super.reverseTransitionDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    _view = View.of(context);
    _orientationController = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appOrientationControllerProvider);
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    controller!.duration = transitionDuration;
    controller!.reverseDuration = _revealBehindNotifier.value
        ? Duration.zero
        : reverseTransitionDuration;
    if (_reducedMotion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isActive && controller?.status == AnimationStatus.forward) {
          controller!.value = 1;
        }
      });
    }
    return super.buildPage(context, animation, secondaryAnimation);
  }

  void _handleRevealBehindChanged() {
    controller?.reverseDuration = _revealBehindNotifier.value
        ? Duration.zero
        : reverseTransitionDuration;
    if (overlayEntries.isNotEmpty) {
      overlayEntries.first.opaque = opaque;
    }
    changedInternalState();
  }

  @override
  bool get opaque => !_revealBehindNotifier.value;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  void dispose() {
    final ready = _portraitReady;
    if (ready != null && !ready.isCompleted) ready.complete();
    _revealBehindNotifier.removeListener(_handleRevealBehindChanged);
    _revealBehindNotifier.dispose();
    super.dispose();
  }
}
