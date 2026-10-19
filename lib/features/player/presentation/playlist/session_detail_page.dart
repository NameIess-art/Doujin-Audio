import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../application/playback_session_snapshot.dart';
import 'playlist_shared_helpers.dart';

import 'session_detail_scaffold.dart';
import 'session_detail_route.dart';
import 'session_detail_theme.dart';
export 'session_detail_route.dart'
    show SessionDetailRoute, buildSessionDetailRoute;

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({
    super.key,
    required this.sessionId,
    required this.revealBehindNotifier,
    this.routeAnimation,
  });

  final String sessionId;
  final ValueNotifier<bool> revealBehindNotifier;
  final Animation<double>? routeAnimation;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

// A projection of the existing snapshot; transport changes belong to controls.
class _DetailStructure {
  const _DetailStructure(this.session);

  final PlaybackSessionSnapshot? session;

  @override
  bool operator ==(Object other) =>
      other is _DetailStructure &&
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _dismissController;
  Animation<double>? _routeAnimation;
  late Listenable _motion;
  final ValueNotifier<bool> _transitionActive = ValueNotifier(true);
  int _dismissOperation = 0;
  bool _closing = false;
  final Object _dismissInteractionSource = Object();
  bool _dismissInteractionActive = false;
  final ValueNotifier<bool> _segmentPanelExpandedNotifier = ValueNotifier(
    false,
  );
  String? _cachedTrackPath;
  String? _cachedCoverScope;
  ({int epoch, int revision})? _cachedCoverRevision;
  Future<String?>? _cachedCoverFuture;
  String get _coverCommitKey =>
      'session_detail_${identityHashCode(this)}_cover';
  late final ActiveSessionDetailIdsNotifier _activeSessionDetailIdsNotifier;

  SessionDetailRoute? get _detailRoute {
    final route = ModalRoute.of(context);
    return route is SessionDetailRoute ? route : null;
  }

  @override
  void initState() {
    super.initState();
    _activeSessionDetailIdsNotifier = ref.read(
      activeSessionDetailIdsProvider.notifier,
    );
    WidgetsBinding.instance.addObserver(this);
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 0,
    );
    _motion = _dismissController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _activeSessionDetailIdsNotifier.push(widget.sessionId);
        ref
            .read(notificationFacadeProvider)
            .setFocusedSession(widget.sessionId);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRouteAnimation();
  }

  @override
  void didUpdateWidget(covariant SessionDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.routeAnimation, widget.routeAnimation)) {
      _syncRouteAnimation();
    }
  }

  void _syncRouteAnimation() {
    final animation = MediaQuery.disableAnimationsOf(context)
        ? null
        : widget.routeAnimation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_handleEnterStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_handleEnterStatus);
      _motion = Listenable.merge([?animation, _dismissController]);
    }
    _handleEnterStatus(animation?.status ?? AnimationStatus.completed);
  }

  void _handleEnterStatus(AnimationStatus status) {
    _transitionActive.value =
        status != AnimationStatus.completed ||
        _dismissInteractionActive ||
        _closing;
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_coverCommitKey);
    WidgetsBinding.instance.removeObserver(this);
    _dismissOperation++;
    UiInteractionCoordinator.instance.cancelInteraction(
      _dismissInteractionSource,
    );
    widget.revealBehindNotifier.value = false;
    _segmentPanelExpandedNotifier.dispose();
    _transitionActive.dispose();
    _dismissController.dispose();
    _routeAnimation?.removeStatusListener(_handleEnterStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeSessionDetailIdsNotifier.pop(widget.sessionId);
    });
    super.dispose();
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
    _setRevealBehind(_detailRoute?.requiresPortraitRestore != true);
  }

  void _endDismissInteraction() {
    if (!_dismissInteractionActive) return;
    _dismissInteractionActive = false;
    if (_dismissController.value <= 0.001) {
      _setRevealBehind(false);
    }
    _transitionActive.value =
        (_routeAnimation != null &&
            _routeAnimation!.status != AnimationStatus.completed) ||
        _closing;
    UiInteractionCoordinator.instance.endInteraction(_dismissInteractionSource);
  }

  void _resetInterruptedDismiss() {
    if (_detailRoute?.preparingForExit == true) return;
    if (!_dismissInteractionActive && !_closing) return;
    _dismissOperation++;
    _closing = false;
    _dismissController.stop();
    _dismissController.value = 0;
    _endDismissInteraction();
    _setRevealBehind(false);
  }

  @override
  void didChangeMetrics() {
    final route = _detailRoute;
    route?.didChangeMetrics();
    _resetInterruptedDismiss();
  }

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
    try {
      final route = _detailRoute;
      if (route?.requiresPortraitRestore == true) {
        _dismissController.value = 0;
        await route!.prepareForExit();
        if (!mounted || operation != _dismissOperation) return;
      }
      final prepareBehind = !_dismissInteractionActive;
      _beginDismissInteraction();
      _setRevealBehind(true);
      // Reveal and lay out the cached underlying page before the spring starts.
      if (prepareBehind) await WidgetsBinding.instance.endOfFrame;
      if (!mounted || operation != _dismissOperation) return;
      await _animateDismissToEnd(velocity: velocity);
      // Keep the final translated frame alive before the zero-duration pop.
      await WidgetsBinding.instance.endOfFrame;
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
    final session = ref
        .watch(
          playbackSessionProvider(
            widget.sessionId,
          ).select((value) => _DetailStructure(value)),
        )
        .session;
    ref.watch(
      libraryStateProvider.select((state) => state.value?.contentRevision),
    );
    if (session == null) {
      return const Scaffold(body: SizedBox.shrink());
    }

    final trackPath = session.currentTrackPath;
    final library = ref.read(libraryFacadeProvider);
    final detailTrack = paths.trackByPath(trackPath);
    final coverCache = library.coverArtworkCacheService;
    final coverScope =
        coverCache.coverSearchKeyForTrack(detailTrack, trackPath: trackPath) ??
        trackPath;
    final coverRevision = ref.watch(
      coverGenerationProvider.select(
        (_) => coverCache.revisionForScope(coverScope),
      ),
    );
    if (_cachedCoverFuture == null ||
        _cachedTrackPath != trackPath ||
        _cachedCoverScope != coverScope ||
        _cachedCoverRevision != coverRevision) {
      _cachedTrackPath = trackPath;
      _cachedCoverScope = coverScope;
      _cachedCoverRevision = coverRevision;
      _cachedCoverFuture = coverFutureForTrack(
        library,
        detailTrack,
        cachedOnly: true,
      );
      // Display indexed artwork first; discovery and extraction must
      // not compete with the route's moving first frames.
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _coverCommitKey,
        commit: () {
          if (!mounted) return;
          final coverFuture = coverFutureForTrack(library, detailTrack);
          setState(() {
            _cachedCoverFuture = coverFuture;
          });
        },
      );
    }
    final coverPathFuture = _cachedCoverFuture!;

    final routeAnimation = MediaQuery.disableAnimationsOf(context)
        ? null
        : _routeAnimation;
    return SessionDetailTheme(
      coverPathFuture: coverPathFuture,
      initialCoverPath: ref
          .read(libraryFacadeProvider)
          .resolvedPlaybackCoverPathForTrack(detailTrack),
      requestKey: (session.id, trackPath),
      coverRevision: (
        scope: coverScope,
        epoch: coverRevision.epoch,
        revision: coverRevision.revision,
      ),
      isAsmr: detailTrack?.usesAsmrVisualTheme ?? false,
      queueColorValue: session.playbackQueue?.colorValue,
      transitionActive: _transitionActive,
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: _motion,
          builder: (context, child) {
            final rawEnterProgress = (routeAnimation?.value ?? 1).clamp(
              0.0,
              1.0,
            );
            final enterProgress = Curves.easeOutCubic.transform(
              rawEnterProgress,
            );
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
                if (_detailRoute?.requiresPortraitRestore == true)
                  ColoredBox(color: Theme.of(context).colorScheme.surface),
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
            valueListenable: _transitionActive,
            builder: (context, isTransitioning, child) {
              return TickerMode(
                enabled: !isTransitioning,
                child: MarqueePauseScope(
                  isPaused: isTransitioning,
                  child: child!,
                ),
              );
            },
            child: RepaintBoundary(
              key: const ValueKey('session_detail_content_cache'),
              child: Builder(
                builder: (context) {
                  final pageSession = playback.sessionSnapshotById(
                    widget.sessionId,
                  );
                  if (pageSession == null) {
                    return const SizedBox.shrink();
                  }

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
