import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';
import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../application/playback_session_snapshot.dart';
import 'playlist_shared_helpers.dart';

import 'session_detail_scaffold.dart';
export 'session_detail_route.dart'
    show SessionDetailRoute, buildSessionDetailRoute;

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({
    super.key,
    required this.sessionId,
    required this.revealBehindNotifier,
  });

  final String sessionId;
  final ValueNotifier<bool> revealBehindNotifier;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

// A projection of the existing snapshot; transport changes belong to controls.
class _DetailStructure {
  const _DetailStructure(this.session, this.coverGeneration);

  final PlaybackSessionSnapshot? session;
  final int coverGeneration;

  @override
  bool operator ==(Object other) =>
      other is _DetailStructure &&
      coverGeneration == other.coverGeneration &&
      session?.id == other.session?.id &&
      session?.currentTrackPath == other.session?.currentTrackPath &&
      session?.loadedPath == other.session?.loadedPath &&
      session?.currentQueueIndex == other.session?.currentQueueIndex &&
      session?.queueVersion == other.session?.queueVersion &&
      session?.playbackQueue == other.session?.playbackQueue &&
      session?.positionStream == other.session?.positionStream &&
      (identical(
            session?.customQueueTracks,
            other.session?.customQueueTracks,
          ) ||
          ((session?.queueVersion ?? 0) != 0 &&
              session?.queueVersion == other.session?.queueVersion) ||
          listEquals(
            session?.customQueueTracks,
            other.session?.customQueueTracks,
          ));

  @override
  int get hashCode => Object.hash(
    coverGeneration,
    session?.id,
    session?.currentTrackPath,
    session?.loadedPath,
    session?.currentQueueIndex,
    session?.queueVersion,
    session?.playbackQueue?.contentSignature ?? session?.playbackQueue,
    session?.positionStream,
  );
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _dismissController;
  late final AnimationController _contentEnterController;
  bool _contentEnterStarted = false;
  final ValueNotifier<bool> _transitionActive = ValueNotifier(true);
  int _dismissOperation = 0;
  bool _closing = false;
  final Object _dismissInteractionSource = Object();
  bool _dismissInteractionActive = false;
  final ValueNotifier<bool> _dismissInteractionNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _segmentPanelExpandedNotifier = ValueNotifier(
    false,
  );
  String? _cachedTrackPath;
  int? _cachedCoverGeneration;
  Future<String?>? _cachedCoverFuture;
  late final ActiveSessionDetailIdsNotifier _activeSessionDetailIdsNotifier;

  @override
  void initState() {
    super.initState();
    _activeSessionDetailIdsNotifier = ref.read(
      activeSessionDetailIdsProvider.notifier,
    );
    WidgetsBinding.instance.addObserver(this);
    _systemUiRestored = false;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const [SystemUiOverlay.bottom],
        ),
      );
    }
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 0,
    );
    _contentEnterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addStatusListener(_handleEnterStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _activeSessionDetailIdsNotifier.push(widget.sessionId);
        ref
            .read(notificationFacadeProvider)
            .setFocusedSession(widget.sessionId);
      }
    });
  }

  void _handleEnterStatus(AnimationStatus status) {
    _transitionActive.value =
        status != AnimationStatus.completed ||
        _dismissInteractionActive ||
        _closing;
  }

  bool _systemUiRestored = false;

  void _restoreSystemUiMode() {
    if (_systemUiRestored) return;
    _systemUiRestored = true;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _restoreSystemUiMode();
    _dismissOperation++;
    UiInteractionCoordinator.instance.cancelInteraction(
      _dismissInteractionSource,
    );
    widget.revealBehindNotifier.value = false;
    _dismissInteractionNotifier.dispose();
    _segmentPanelExpandedNotifier.dispose();
    _transitionActive.dispose();
    _dismissController.dispose();
    _contentEnterController.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeSessionDetailIdsNotifier.pop(widget.sessionId);
    });
    super.dispose();
  }

  void _ensureContentEnterStarted() {
    if (_contentEnterStarted) return;
    _contentEnterStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _contentEnterController.value = 1;
        return;
      }
      unawaited(_contentEnterController.forward());
    });
  }

  void _setRevealBehind(bool value) {
    if (widget.revealBehindNotifier.value == value) return;
    widget.revealBehindNotifier.value = value;
  }

  void _beginDismissInteraction() {
    if (_dismissInteractionActive) return;
    _dismissInteractionActive = true;
    _transitionActive.value = true;
    UiInteractionCoordinator.instance.beginInteraction(
      _dismissInteractionSource,
    );
    _dismissInteractionNotifier.value = true;
    _setRevealBehind(true);
  }

  void _endDismissInteraction() {
    if (!_dismissInteractionActive) return;
    _dismissInteractionActive = false;
    if (_dismissController.value <= 0.001) {
      _setRevealBehind(false);
    }
    _dismissInteractionNotifier.value = false;
    _transitionActive.value = !_contentEnterController.isCompleted || _closing;
    UiInteractionCoordinator.instance.endInteraction(_dismissInteractionSource);
  }

  void _resetInterruptedDismiss() {
    if (!_dismissInteractionActive && !_closing) return;
    _dismissOperation++;
    _closing = false;
    _dismissController.stop();
    _dismissController.value = 0;
    _endDismissInteraction();
    _setRevealBehind(false);
  }

  @override
  void didChangeMetrics() => _resetInterruptedDismiss();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _resetInterruptedDismiss();
  }

  Future<void> _handleVerticalDragEnd(
    DragEndDetails details,
    BuildContext context,
  ) async {
    final navigator = Navigator.of(context);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissController.value >= (1 / 3) || velocity > 500;
    if (shouldDismiss) {
      await _dismissAndPop(velocity: velocity, navigator: navigator);
      return;
    }
    if (_dismissController.value <= 0.001) {
      _endDismissInteraction();
      return;
    }
    await _returnFromDismiss();
  }

  Future<void> _returnFromDismiss() async {
    if (_closing) return;
    final operation = ++_dismissOperation;
    _beginDismissInteraction();
    try {
      await _animateDismissBack();
    } on TickerCanceled {
      // A new drag owns the animation and its interaction lifetime.
    } finally {
      if (mounted && operation == _dismissOperation) _endDismissInteraction();
    }
  }

  Future<void> _animateDismissToEnd({double velocity = 0}) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _dismissController.value = 1;
      return Future<void>.value();
    }
    final normalizedVelocity = (velocity / MediaQuery.sizeOf(context).height)
        .clamp(-4.0, 4.0);
    return _dismissController
        .animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 420, damping: 34),
            _dismissController.value,
            1,
            normalizedVelocity,
          ),
        )
        .orCancel;
  }

  Future<void> _animateDismissBack() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _dismissController.value = 0;
      return Future<void>.value();
    }
    return _dismissController
        .animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 420, damping: 34),
            _dismissController.value,
            0,
            0,
          ),
        )
        .orCancel;
  }

  Future<void> _dismissAndPop({
    double velocity = 0,
    required NavigatorState navigator,
  }) async {
    if (_closing) return;
    _closing = true;
    final operation = ++_dismissOperation;
    ref
        .read(playlistUiControllerProvider)
        .requestCarouselSnap(widget.sessionId);
    _beginDismissInteraction();
    try {
      await _animateDismissToEnd(velocity: velocity);
      if (mounted && operation == _dismissOperation) {
        await navigator.maybePop();
      }
    } on TickerCanceled {
      // Disposal or replacement invalidates the pending close.
    } finally {
      if (mounted && operation == _dismissOperation) {
        _closing = false;
        _endDismissInteraction();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.read(playbackFacadeProvider);
    final paths = ref.read(audioPathCoordinatorProvider);
    final structure = ref.watch(
      playbackStateProvider.select((_) {
        final state = playback.state;
        return _DetailStructure(
          state.activeSessions
              .where((session) => session.id == widget.sessionId)
              .firstOrNull,
          state.coverGeneration,
        );
      }),
    );
    ref.watch(
      libraryStateProvider.select((state) => state.value?.contentRevision),
    );
    if (structure.session == null) {
      return const Scaffold(body: SizedBox.shrink());
    }

    _ensureContentEnterStarted();
    final routeAnimation = MediaQuery.disableAnimationsOf(context)
        ? null
        : ModalRoute.of(context)?.animation;
    final animatedListenable = Listenable.merge([
      ?routeAnimation,
      _contentEnterController,
      _dismissController,
    ]);

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: animatedListenable,
        builder: (context, child) {
          final rawEnterProgress = min(
            (routeAnimation?.value ?? 1).clamp(0.0, 1.0),
            _contentEnterController.value.clamp(0.0, 1.0),
          );
          final enterProgress = Curves.easeOutCubic.transform(rawEnterProgress);
          final dismissProgress = _dismissController.value.clamp(0.0, 1.0);
          final screenHeight = MediaQuery.sizeOf(context).height;
          final dragDistance = screenHeight * dismissProgress;
          final enterOffset = (1 - enterProgress) * screenHeight;
          final revealProgress = (dismissProgress * 3).clamp(0.0, 1.0);
          final backdropOpacity = 1 - revealProgress;
          final backdropProgress = backdropOpacity * backdropOpacity;
          final showBackdrop = dismissProgress > 0.01 && backdropProgress > 0;
          return Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: ModalBarrier(
                  dismissible: false,
                  color: Colors.transparent,
                ),
              ),
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(0, enterOffset),
                  child: IgnorePointer(
                    child: Opacity(
                      key: const ValueKey<String>(
                        'session_detail_backdrop_paint_gate',
                      ),
                      opacity: showBackdrop ? 1 : 0,
                      child: showBackdrop
                          ? _SessionDetailBackdrop(progress: backdropProgress)
                          : const _SessionDetailBackdrop(),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: 1.0,
                  child: Transform.translate(
                    offset: Offset(0, enterOffset + dragDistance),
                    child: Transform.scale(
                      scale: 1 - (0.03 * revealProgress),
                      alignment: Alignment.topCenter,
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(24 * revealProgress),
                        ),
                        child: child!,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: _dismissInteractionNotifier,
          builder: (context, isDismissing, child) {
            return TickerMode(
              enabled: !isDismissing,
              child: MarqueePauseScope(isPaused: isDismissing, child: child!),
            );
          },
          child: RepaintBoundary(
            child: Builder(
              builder: (context) {
                final coverGen = ref.watch(coverGenerationProvider);
                final pageSession = playback.sessionSnapshotById(
                  widget.sessionId,
                );
                if (pageSession == null) {
                  return const SizedBox.shrink();
                }
                final trackPath = pageSession.currentTrackPath;
                if (_cachedCoverFuture == null ||
                    _cachedTrackPath != trackPath ||
                    _cachedCoverGeneration != coverGen) {
                  _cachedTrackPath = trackPath;
                  _cachedCoverGeneration = coverGen;
                  final detailTrack = paths.trackByPath(trackPath);
                  _cachedCoverFuture = coverFutureForTrack(
                    ref.read(libraryFacadeProvider),
                    detailTrack,
                  );
                }
                final coverPathFuture = _cachedCoverFuture!;

                return SessionDetailScaffold(
                  session: pageSession,
                  coverPathFuture: coverPathFuture,
                  transitionActive: _transitionActive,
                  dismissAnimation: _dismissController,
                  segmentPanelExpandedNotifier: _segmentPanelExpandedNotifier,
                  onClose: () =>
                      _dismissAndPop(navigator: Navigator.of(context)),
                  onVerticalDragUpdate: (delta) {
                    if (_closing) return;
                    if (_dismissController.isAnimating) {
                      _dismissOperation++;
                      _dismissController.stop();
                    }
                    final screenHeight = MediaQuery.sizeOf(context).height;
                    if (screenHeight <= 0) return;
                    final nextValue =
                        _dismissController.value + (delta / screenHeight);
                    if (nextValue > 0.001) {
                      _beginDismissInteraction();
                    }
                    _dismissController.value = nextValue.clamp(0.0, 1.0);
                  },
                  onVerticalDragEnd: (details) =>
                      _handleVerticalDragEnd(details, context),
                  onVerticalDragCancel: () {
                    if (_dismissController.value <= 0.001) {
                      _endDismissInteraction();
                      return;
                    }
                    unawaited(_returnFromDismiss());
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDetailBackdrop extends StatelessWidget {
  const _SessionDetailBackdrop({this.progress = 1.0});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gradientAlpha = (lerpDouble(0, 0.8, progress) ?? 0).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          key: const ValueKey<String>('session_detail_backdrop_surface'),
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: progress.clamp(0.0, 1.0)),
          ),
        ),
        if (gradientAlpha > 0)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cs.surface.withValues(alpha: 0.2 * gradientAlpha),
                  cs.surface.withValues(alpha: 0.5 * gradientAlpha),
                  cs.surface.withValues(alpha: 0.85 * gradientAlpha),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
      ],
    );
  }
}
