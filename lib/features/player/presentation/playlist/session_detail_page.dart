import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_transitions.dart';
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
    this.routeAnimation,
  });

  final String sessionId;
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
    with WidgetsBindingObserver {
  Animation<double>? _routeAnimation;
  final ValueNotifier<bool> _transitionActive = ValueNotifier(true);
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
    final route = readAppRoute(context);
    return route is SessionDetailRoute ? route : null;
  }

  @override
  void initState() {
    super.initState();
    _activeSessionDetailIdsNotifier = ref.read(
      activeSessionDetailIdsProvider.notifier,
    );
    WidgetsBinding.instance.addObserver(this);
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
    }
    _handleEnterStatus(animation?.status ?? AnimationStatus.completed);
  }

  void _handleEnterStatus(AnimationStatus status) {
    _transitionActive.value = status != AnimationStatus.completed;
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_coverCommitKey);
    WidgetsBinding.instance.removeObserver(this);
    _segmentPanelExpandedNotifier.dispose();
    _transitionActive.dispose();
    _routeAnimation?.removeStatusListener(_handleEnterStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activeSessionDetailIdsNotifier.pop(widget.sessionId);
    });
    super.dispose();
  }

  @override
  void didChangeMetrics() => _detailRoute?.didChangeMetrics();

  void _close() {
    final route = _detailRoute;
    if (route == null) {
      Navigator.of(context).pop();
    } else {
      route.requestClose();
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
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const ValueKey('session_detail_close_button'),
            onPressed: _close,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
        ),
      );
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
      queueColorValue: session.playbackQueue?.colorValue,
      transitionActive: _transitionActive,
      child: ValueListenableBuilder<bool>(
        valueListenable: _transitionActive,
        builder: (context, isTransitioning, child) => IgnorePointer(
          ignoring: isTransitioning,
          child: TickerMode(
            enabled: !isTransitioning,
            child: MarqueePauseScope(isPaused: isTransitioning, child: child!),
          ),
        ),
        child: RepaintBoundary(
          key: const ValueKey('session_detail_content_cache'),
          child: SessionDetailScaffold(
            session: playback.sessionSnapshotById(widget.sessionId) ?? session,
            coverPathFuture: coverPathFuture,
            transitionActive: _transitionActive,
            detailCoverKey: _detailRoute?.detailCoverKey,
            coverPreview: _detailRoute?.coverPreviewFor(trackPath),
            deferCoverOverlays: _routeAnimation != null,
            segmentPanelExpandedNotifier: _segmentPanelExpandedNotifier,
            onClose: _close,
          ),
        ),
      ),
    );
  }
}
