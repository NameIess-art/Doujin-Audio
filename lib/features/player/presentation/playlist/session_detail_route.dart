import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_orientation_controller.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/presentation/audio_ui_controllers.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../playback_providers.dart';
import 'session_cover_transition.dart';
import 'session_detail_page.dart';

PageRoute<void> buildSessionDetailRoute({
  required String sessionId,
  BuildContext? coverOrigin,
}) {
  final source =
      coverOrigin == null || MediaQuery.disableAnimationsOf(coverOrigin)
      ? null
      : findSessionCoverAnchor(coverOrigin, sessionId);
  return SessionDetailRoute(
    sessionId: sessionId,
    source: source,
    sourceTrackPath: source == null
        ? null
        : ProviderScope.containerOf(source.context, listen: false)
              .read(playbackFacadeProvider)
              .sessionSnapshotById(sessionId)
              ?.currentTrackPath,
  );
}

class SessionDetailRoute extends AppPreparedPageRoute<void> {
  SessionDetailRoute({
    required this.sessionId,
    SessionCoverAnchorState? source,
    String? sourceTrackPath,
  })
    : _source = source,
      _sourceTrackPath = sourceTrackPath,
      _sourceBounds = source?.bounds(),
      super(
        transitionDuration: kAppFadeDuration,
        reverseTransitionDuration: kAppFadeDuration,
        pageBuilder: (context, animation, secondaryAnimation) =>
            SessionDetailPage(sessionId: sessionId, routeAnimation: animation),
        transitionsBuilder: (_, animation, secondaryAnimation, child) => child,
      ) {
    _sourceImage = _sourceBounds == null ? null : source?.decodedImage?.clone();
  }

  final String sessionId;
  final SessionCoverAnchorState? _source;
  final String? _sourceTrackPath;
  Rect? _sourceBounds;
  late final ui.Image? _sourceImage;
  final detailCoverKey = GlobalKey<SessionCoverAnchorState>();
  final _viewportKey = GlobalKey();
  final _fadeKey = GlobalKey();
  final _flight = ValueNotifier<SessionCoverFlight?>(null);
  SessionCoverAnchorState? _flightStart;
  SessionCoverAnchorState? _flightEnd;
  late final Animation<double> _progress = animation!.drive(
    CurveTween(curve: kAppFadeCurve),
  );

  bool _reducedMotion = false;
  bool _revealBehind = false;
  bool _entryPrepared = false;
  bool _closing = false;
  ui.FlutterView? _view;
  (Size, double)? _viewMetrics;
  AppOrientationController? _orientationController;
  late PlaylistUiController _playlist;
  late Set<SessionCoverAnchorState> _coverTargets;
  Completer<void>? _portraitReady;
  Future<void>? _exitPreparation;
  bool _popPending = false;

  ui.Image? coverPreviewFor(String trackPath) =>
      _sourceTrackPath == trackPath ? _sourceImage : null;

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
      // Android acknowledges orientation requests before it lays out the view.
      if (requiresPortraitRestore) await ready.future;
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _portraitReady = null;
      _exitPreparation = null;
    }
  }

  Future<void> requestClose() async {
    if (_closing ||
        !isCurrent ||
        animation?.status != AnimationStatus.completed) {
      return;
    }
    _closing = true;
    try {
      await prepareForExit();
      if (!isCurrent) return;
      _playlist.requestCarouselSnap(sessionId, immediately: true);
      if (!_reducedMotion) {
        // Lay out the previously covered page before measuring the destination.
        _setRevealBehind(true);
        await WidgetsBinding.instance.endOfFrame;
        if (!isCurrent) return;
        _prepareCoverExit();
      }
      navigator?.pop();
    } finally {
      if (isCurrent) {
        _clearFlight();
        _closing = false;
        _setRevealBehind(false);
      }
    }
  }

  void didChangeMetrics() {
    final view = _view;
    if (view != null) {
      final metrics = (view.physicalSize, view.devicePixelRatio);
      // Android also sends metrics when orientation policy/insets are applied
      // without resizing the view. Those events must not cancel the flight.
      if (_viewMetrics != metrics) {
        _viewMetrics = metrics;
        _sourceBounds = null;
        _clearFlight();
      }
    }
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
    _viewMetrics ??= (_view!.physicalSize, _view!.devicePixelRatio);
    final container = ProviderScope.containerOf(context, listen: false);
    _orientationController = container.read(appOrientationControllerProvider);
    _playlist = container.read(playlistUiControllerProvider);
    _coverTargets = container.read(sessionCoverTargetsProvider);
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    controller!.duration = transitionDuration;
    controller!.reverseDuration = reverseTransitionDuration;
    if (!_entryPrepared) {
      _entryPrepared = true;
      animation.addStatusListener(_handleFlightStatus);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isActive) return;
        if (_reducedMotion && controller?.status == AnimationStatus.forward) {
          controller!.value = 1;
        }
        _prepareCoverEntry(
          container
              .read(playbackFacadeProvider)
              .sessionSnapshotById(sessionId)
              ?.currentTrackPath,
        );
      });
    }
    final page = PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: defaultTargetPlatform == TargetPlatform.android
          ? (didPop, _) {
              // Use the same preparation as the close button before popping.
              if (!didPop) unawaited(requestClose());
            }
          : null,
      child: super.buildPage(context, animation, secondaryAnimation),
    );
    // Keep the fade and flight on the cached page subtree. ModalRoute rebuilds
    // its buildTransitions wrapper on every tick.
    return _buildMotion(page);
  }

  Widget _buildMotion(Widget child) => ValueListenableBuilder<SessionCoverFlight?>(
    valueListenable: _flight,
    child: FadeTransition(key: _fadeKey, opacity: _progress, child: child),
    builder: (context, flight, page) => SizedBox.expand(
      key: _viewportKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          page!,
          if (flight != null)
            IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('session_detail_cover_flight'),
                  painter: flight,
                ),
              ),
            ),
        ],
      ),
    ),
  );

  void _prepareCoverEntry(String? trackPath) {
    final source = _source;
    final sourceBounds = _sourceBounds;
    final image = trackPath == null ? null : coverPreviewFor(trackPath);
    final detail = detailCoverKey.currentState;
    final detailBounds = detail?.bounds(
      within: _fadeKey.currentContext?.findRenderObject(),
    );
    if (!_reducedMotion &&
        animation?.status == AnimationStatus.forward &&
        source != null &&
        sourceBounds != null &&
        image != null &&
        detail != null &&
        detailBounds != null) {
      // The destination can use the same decoded thumbnail while its own
      // image request is deferred or waiting for a larger decode.
      _startFlight(source, sourceBounds, detail, detailBounds, image.clone());
    }
  }

  void _prepareCoverExit() {
    final detail = detailCoverKey.currentState;
    final detailBounds = detail?.bounds();
    final image = detail?.decodedImage;
    if (detail == null || detailBounds == null || image == null) return;
    final source = _source;
    final mountedSource = source?.mounted == true ? source : null;
    final candidates = {
      if (mountedSource?.widget.isDock == true) mountedSource!,
      ..._targetsAt(SessionCoverLocation.routedDock),
      ..._targetsAt(SessionCoverLocation.dock),
      if (mountedSource?.widget.location == SessionCoverLocation.playlist)
        mountedSource!,
      ..._targetsAt(SessionCoverLocation.playlist),
    };
    for (final target in candidates) {
      if (!target.mounted || target.widget.sessionId != sessionId) continue;
      final bounds = target.bounds();
      if (bounds == null || target.decodedImage == null) continue;
      _startFlight(
        detail,
        detailBounds,
        target,
        bounds,
        image.clone(),
        reverse: true,
      );
      break;
    }
  }

  Iterable<SessionCoverAnchorState> _targetsAt(SessionCoverLocation location) =>
      _coverTargets.where((anchor) => anchor.widget.location == location);

  void _startFlight(
    SessionCoverAnchorState start,
    Rect from,
    SessionCoverAnchorState end,
    Rect to,
    ui.Image image, {
    bool reverse = false,
  }) {
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) {
      image.dispose();
      return;
    }
    Rect toViewport(Rect bounds) => Rect.fromPoints(
      viewport.globalToLocal(bounds.topLeft),
      viewport.globalToLocal(bounds.bottomRight),
    );
    _flightStart = start;
    _flightEnd = end;
    start.setInFlight(true);
    end.setInFlight(true);
    _flight.value = SessionCoverFlight(
      image: image,
      from: toViewport(from),
      to: toViewport(to),
      fromRadius: start.widget.radius,
      toRadius: end.widget.radius,
      progress: _progress,
      reverse: reverse,
    );
  }

  void _handleFlightStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _clearFlight();
    }
  }

  void _clearFlight() {
    final flight = _flight.value;
    if (flight == null) return;
    _flightStart?.setInFlight(false);
    _flightEnd?.setInFlight(false);
    _flightStart = null;
    _flightEnd = null;
    _flight.value = null;
    flight.image.dispose();
  }

  void _setRevealBehind(bool value) {
    if (_revealBehind == value) return;
    _revealBehind = value;
    if (overlayEntries.isNotEmpty) overlayEntries.first.opaque = opaque;
  }

  @override
  bool get opaque => !_revealBehind;

  @override
  void dispose() {
    final ready = _portraitReady;
    if (ready != null && !ready.isCompleted) ready.complete();
    animation?.removeStatusListener(_handleFlightStatus);
    _sourceImage?.dispose();
    _clearFlight();
    _flight.dispose();
    unawaited(_orientationController?.setPlaybackDetailVisible(false));
    super.dispose();
  }
}
