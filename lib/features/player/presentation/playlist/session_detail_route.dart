import 'package:flutter/material.dart';
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
        deferExitFinalization: true,
        pageBuilder: (context, animation, secondaryAnimation) =>
            SessionDetailPage(
              sessionId: sessionId,
              revealBehindNotifier: _revealBehindNotifier,
            ),
        transitionsBuilder: (_, animation, secondaryAnimation, child) => child,
      ) {
    _revealBehindNotifier.addListener(_handleRevealBehindChanged);
  }

  final String sessionId;
  final ValueNotifier<bool> _revealBehindNotifier;
  bool _reducedMotion = false;

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
    _revealBehindNotifier.removeListener(_handleRevealBehindChanged);
    _revealBehindNotifier.dispose();
    super.dispose();
  }
}
