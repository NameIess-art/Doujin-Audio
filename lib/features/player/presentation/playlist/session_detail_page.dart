import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';
import '../../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/ui/permission_action_controller.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/subtitle_overlay_controller.dart';
import 'playlist_feature_icons.dart';
import 'playlist_media_widgets.dart';
import 'playlist_shared_helpers.dart';
import 'session_detail_content.dart';

PageRoute<void> buildSessionDetailRoute({required String sessionId}) {
  return SessionDetailRoute(sessionId: sessionId);
}

class SessionDetailRoute extends PageRoute<void> {
  SessionDetailRoute({required this.sessionId}) {
    _revealBehindNotifier.addListener(_handleRevealBehindChanged);
  }

  final String sessionId;
  final ValueNotifier<bool> _revealBehindNotifier = ValueNotifier<bool>(false);

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
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: SessionDetailPage(
        sessionId: sessionId,
        revealBehindNotifier: _revealBehindNotifier,
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }

  @override
  void dispose() {
    _revealBehindNotifier.removeListener(_handleRevealBehindChanged);
    _revealBehindNotifier.dispose();
    super.dispose();
  }
}

const double _kSessionDetailBackgroundBlurSigma = 32;
const int _kSessionDetailBackgroundCacheWidth = 300;
final ImageFilter _sessionDetailBackgroundFilter = ImageFilter.blur(
  sigmaX: _kSessionDetailBackgroundBlurSigma,
  sigmaY: _kSessionDetailBackgroundBlurSigma,
  tileMode: TileMode.decal,
);

ThemeData _createAsmrSessionDetailTheme(
  ThemeData base,
  AppDesignTokens tokens,
) {
  final scheme = base.colorScheme.copyWith(
    primary: tokens.asmrAccent,
    onPrimary: tokens.onAsmrAccent,
    primaryContainer: tokens.asmrContainer,
    onPrimaryContainer: tokens.onAsmrContainer,
    secondary: tokens.asmrAccent,
    onSecondary: tokens.onAsmrAccent,
    secondaryContainer: tokens.asmrContainer,
    onSecondaryContainer: tokens.onAsmrContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: tokens.asmrAccent,
      thumbColor: tokens.asmrAccent,
      overlayColor: tokens.asmrAccent.withValues(alpha: 0.15),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: tokens.asmrAccent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.asmrAccent,
        foregroundColor: tokens.onAsmrAccent,
      ),
    ),
  );
}

ThemeData _createPlaybackQueueSessionDetailTheme(
  ThemeData base,
  Color queueColor,
) {
  final generated = ColorScheme.fromSeed(
    seedColor: queueColor,
    brightness: base.brightness,
  );
  final onQueueColor =
      ThemeData.estimateBrightnessForColor(queueColor) == Brightness.dark
      ? Colors.white
      : const Color(0xFF1B1B1F);
  final scheme = base.colorScheme.copyWith(
    primary: queueColor,
    onPrimary: onQueueColor,
    primaryContainer: generated.primaryContainer,
    onPrimaryContainer: generated.onPrimaryContainer,
    secondary: queueColor,
    onSecondary: onQueueColor,
    secondaryContainer: generated.primaryContainer,
    onSecondaryContainer: generated.onPrimaryContainer,
    surfaceTint: queueColor,
  );
  return base.copyWith(
    colorScheme: scheme,
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: queueColor,
      thumbColor: queueColor,
      overlayColor: queueColor.withValues(alpha: 0.15),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: queueColor),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: queueColor,
        foregroundColor: onQueueColor,
      ),
    ),
  );
}


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
      session?.playbackQueue == other.session?.playbackQueue &&
      session?.positionStream == other.session?.positionStream &&
      listEquals(session?.customQueueTracks, other.session?.customQueueTracks);

  @override
  int get hashCode => Object.hash(
    coverGeneration,
    session?.id,
    session?.currentTrackPath,
    session?.loadedPath,
    session?.currentQueueIndex,
    session?.playbackQueue,
    session?.positionStream,
    Object.hashAll(session?.customQueueTracks ?? const []),
  );
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage>
    with TickerProviderStateMixin {
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

  @override
  void initState() {
    super.initState();
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

                return _SessionDetailScaffold(
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

class _SessionDetailScaffold extends ConsumerStatefulWidget {
  final ValueListenable<bool> transitionActive;
  final PlaybackSessionSnapshot session;
  final Future<String?> coverPathFuture;
  final Animation<double> dismissAnimation;
  final VoidCallback onClose;
  final ValueChanged<double>? onVerticalDragUpdate;
  final void Function(DragEndDetails)? onVerticalDragEnd;
  final VoidCallback? onVerticalDragCancel;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;

  const _SessionDetailScaffold({
    required this.transitionActive,
    required this.session,
    required this.coverPathFuture,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
    required this.dismissAnimation,
    this.segmentPanelExpandedNotifier,
  });

  @override
  ConsumerState<_SessionDetailScaffold> createState() =>
      _SessionDetailScaffoldState();
}

class _SessionDetailScaffoldState extends ConsumerState<_SessionDetailScaffold>
    with WidgetsBindingObserver {
  final _detailContentKey = GlobalKey<SessionDetailContentState>();
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  ThemeData? _cachedBaseTheme;
  AppDesignTokens? _cachedDesignTokens;
  ThemeData? _cachedAsmrTheme;
  ThemeData? _cachedQueueBaseTheme;
  int? _cachedQueueColorValue;
  ThemeData? _cachedQueueTheme;
  bool _isDismissGesture = false;

  ThemeData _detailThemeForSession(
    BuildContext context,
    PlaybackSessionSnapshot session,
    MusicTrack? track,
  ) {
    final base = Theme.of(context);
    final queueColorValue = session.playbackQueue?.colorValue;
    if (queueColorValue != null) {
      if (identical(_cachedQueueBaseTheme, base) &&
          _cachedQueueColorValue == queueColorValue &&
          _cachedQueueTheme != null) {
        return _cachedQueueTheme!;
      }
      _cachedQueueBaseTheme = base;
      _cachedQueueColorValue = queueColorValue;
      return _cachedQueueTheme = _createPlaybackQueueSessionDetailTheme(
        base,
        Color(queueColorValue),
      );
    }
    if (track?.usesAsmrVisualTheme != true) return base;
    final tokens = AppDesignTokens.of(context);
    if (identical(_cachedBaseTheme, base) &&
        identical(_cachedDesignTokens, tokens) &&
        _cachedAsmrTheme != null) {
      return _cachedAsmrTheme!;
    }
    _cachedBaseTheme = base;
    _cachedDesignTokens = tokens;
    return _cachedAsmrTheme = _createAsmrSessionDetailTheme(base, tokens);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _permissionActionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_permissionActionController.handleAppResumed());
    }
  }

  Future<void> _toggleGlobalSubtitleDisplay(
    SubtitleSettingsNotifier notifier,
    SubtitleSettingsState settings,
    String sessionId,
  ) async {
    final isEnabling = !settings.isGlobalEnabled(sessionId);
    if (!isEnabling) {
      notifier.toggleGlobalSubtitles(sessionId);
      return;
    }
    if (!shouldRequestSubtitleOverlayPermission(
      isAndroid: Platform.isAndroid,
    )) {
      notifier.toggleGlobalSubtitles(sessionId);
      return;
    }

    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    await _permissionActionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('overlay_permission_title'),
      message: i18n.tr('overlay_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('cancel'),
      isGranted: ref.read(subtitleOverlayControllerProvider).canDrawOverlays,
      openSettings: ref
          .read(subtitleOverlayControllerProvider)
          .openOverlaySettings,
      onGranted: () async {
        notifier.toggleGlobalSubtitles(sessionId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final paths = ref.read(audioPathCoordinatorProvider);
    final library = ref.read(libraryFacadeProvider);
    final coverPathFuture = widget.coverPathFuture;
    final onClose = widget.onClose;
    final onVerticalDragUpdate = widget.onVerticalDragUpdate;
    final onVerticalDragEnd = widget.onVerticalDragEnd;
    final onVerticalDragCancel = widget.onVerticalDragCancel;

    final track = paths.trackByPath(session.currentTrackPath);
    final detailTheme = _detailThemeForSession(context, session, track);
    final cs = detailTheme.colorScheme;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.blurPlayerBackgroundEnabled ?? true,
      ),
    );
    return Theme(
      data: detailTheme,
      child: Material(
        color: cs.surface,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (details) {
            final detailState = _detailContentKey.currentState;
            final panelExpanded = detailState?.isSegmentPanelExpanded ?? false;
            _isDismissGesture =
                !panelExpanded && widget.dismissAnimation.value > 0.01;
          },
          onVerticalDragUpdate: (details) {
            final detailState = _detailContentKey.currentState;
            final panelExpanded = detailState?.isSegmentPanelExpanded ?? false;
            if (panelExpanded) return;

            final delta = details.primaryDelta ?? 0;
            final detailFullyOpen = widget.dismissAnimation.value <= 0.01;

            if (!_isDismissGesture && delta > 0 && detailFullyOpen) {
              _isDismissGesture = true;
              onVerticalDragUpdate?.call(delta);
              return;
            }

            if (_isDismissGesture) {
              onVerticalDragUpdate?.call(delta);
              return;
            }
          },
          onVerticalDragEnd: (details) {
            final detailState = _detailContentKey.currentState;
            final panelExpanded = detailState?.isSegmentPanelExpanded ?? false;
            if (panelExpanded) return;

            if (_isDismissGesture) {
              _isDismissGesture = false;
              onVerticalDragEnd?.call(details);
              return;
            }
          },
          onVerticalDragCancel: () {
            _isDismissGesture = false;
            onVerticalDragCancel?.call();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (blurEnabled)
                Positioned.fill(
                  child: FadeTransition(
                    opacity: ReverseAnimation(widget.dismissAnimation),
                    child: ClipRect(
                      child: RepaintBoundary(
                        child: AnimatedSwitcher(
                          duration: kAppMotionSlow,
                          reverseDuration: kAppMotionStandard,
                          transitionBuilder: (child, animation) =>
                              buildAppFadeTransition(
                                context: context,
                                animation: animation,
                                child: child,
                              ),
                          child: KeyedSubtree(
                            key: ValueKey('session_detail_blur_${session.id}'),
                            child: ImageFiltered(
                              key: const ValueKey(
                                'session_detail_background_blur',
                              ),
                              imageFilter: _sessionDetailBackgroundFilter,
                              child: AsyncCoverImage(
                                future: coverPathFuture,
                                requestKey: (
                                  session.id,
                                  session.currentTrackPath,
                                ),
                                initialPath: library
                                    .resolvedPlaybackCoverPathForTrack(track),
                                retryFutureBuilder: () => coverFutureForTrack(
                                  ref.read(libraryFacadeProvider),
                                  track,
                                ),
                                fallbackBuilder: (_) => CoverFallbackArtwork(
                                  seed:
                                      track?.displayName ??
                                      session.currentTrackPath,
                                ),
                                imageBuilder: (context, coverPath) {
                                  return RetryingFileImage(
                                    path: coverPath,
                                    cacheWidth:
                                        _kSessionDetailBackgroundCacheWidth,
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.low,
                                    color: cs.surface.withValues(alpha: 0.45),
                                    colorBlendMode: BlendMode.darken,
                                    fallbackBuilder: (_) =>
                                        CoverFallbackArtwork(
                                          seed:
                                              track?.displayName ??
                                              session.currentTrackPath,
                                        ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // Content
              SafeArea(
                top: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isWindows =
                        defaultTargetPlatform == TargetPlatform.windows;
                    final isLandscape =
                        isWindows ||
                        MediaQuery.orientationOf(context) ==
                            Orientation.landscape;
                    final topBarHeight = isWindows ? 40.0 : 24.0;
                    final closeIconSize = isWindows ? 28.0 : 22.0;
                    final closeConstraints = isWindows
                        ? const BoxConstraints(minWidth: 40, minHeight: 40)
                        : const BoxConstraints(minWidth: 32, minHeight: 24);

                    return Column(
                      children: [
                        // Top Bar — outside drag GestureDetector so taps work
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Builder(
                            builder: (context) {
                              final i18n = ProviderScope.containerOf(
                                context,
                                listen: false,
                              ).read(appLanguageProviderInstanceProvider);
                              final subtitles = ref.read(
                                playbackSubtitleServiceProvider,
                              );
                              return ListenableBuilder(
                                listenable: subtitles,
                                builder: (context, _) {
                                  final hasSubtitle = subtitles
                                      .hasKnownSubtitle(
                                        session.currentTrackPath,
                                      );
                                  final settings = ref.watch(
                                    subtitleSettingsProvider.select(
                                      (state) => (
                                        state.isShowEnabled(session.id),
                                        state.isGlobalEnabled(session.id),
                                      ),
                                    ),
                                  );

                                  return Row(
                                    children: [
                                      IconButton(
                                        onPressed: onClose,
                                        tooltip: i18n.tr('close'),
                                        padding: isWindows
                                            ? const EdgeInsets.all(8)
                                            : EdgeInsets.zero,
                                        constraints: closeConstraints,
                                        visualDensity: isWindows
                                            ? VisualDensity.standard
                                            : VisualDensity.compact,
                                        icon: Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          color: sessionDetailForeground(
                                            cs,
                                            SessionDetailForegroundLevel.muted,
                                          ),
                                          size: closeIconSize,
                                        ),
                                      ),
                                      Expanded(
                                        child: SizedBox(height: topBarHeight),
                                      ),
                                      if (hasSubtitle &&
                                          settings.$1 &&
                                          settings.$2) ...[
                                        Icon(
                                          Icons.subtitles_rounded,
                                          color: sessionDetailForeground(
                                            cs,
                                            SessionDetailForegroundLevel.muted,
                                          ),
                                          size: isLandscape ? 20 : 18,
                                        ),
                                        SizedBox(width: isLandscape ? 8 : 6),
                                      ],
                                      Consumer(
                                        builder: (context, ref, child) {
                                          final transport = ref.watch(
                                            sessionDetailTransportProvider(
                                              session.id,
                                            ),
                                          );
                                          final featureIcons =
                                              sessionFeatureBadgeIcons(
                                                showSubtitles: false,
                                                channelSwapEnabled:
                                                    transport
                                                        ?.channelSwapEnabled ??
                                                    session.channelSwapEnabled,
                                                audioEffects:
                                                    transport?.audioEffects ??
                                                    session.audioEffects,
                                                speed:
                                                    transport?.speed ??
                                                    session.speed,
                                              );
                                          if (featureIcons.isEmpty) {
                                            return const SizedBox.shrink();
                                          }
                                          return Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SessionFeatureIconRow(
                                                featureIcons: featureIcons,
                                                color: sessionDetailForeground(
                                                  cs,
                                                  SessionDetailForegroundLevel
                                                      .muted,
                                                ),
                                                iconSize: isLandscape ? 20 : 18,
                                                spacing: isLandscape ? 8 : 6,
                                                alignment: WrapAlignment.end,
                                              ),
                                              SizedBox(
                                                width: isLandscape ? 8 : 6,
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        // Content area
                        Expanded(
                          child: Builder(
                            builder: (context) {

                              Widget artworkWidget = AnimatedSwitcher(
                                duration: kAppMotionSlow,
                                reverseDuration: kAppMotionStandard,
                                transitionBuilder: (child, animation) =>
                                    buildAppFadeTransition(
                                      context: context,
                                      animation: animation,
                                      child: child,
                                    ),
                                layoutBuilder: (currentChild, previousChildren) {
                                  return Stack(
                                    alignment: Alignment.center,
                                    fit: StackFit.expand,
                                    children: [
                                      ...previousChildren,
                                      ?currentChild,
                                    ],
                                  );
                                },
                                child: KeyedSubtree(
                                  key: ValueKey('artwork_${session.id}'),
                                  child: SessionHeroArtwork(
                                    session: session,
                                    height: constraints.maxHeight,
                                    track: track,
                                    coverPathFuture: coverPathFuture,
                                  ),
                                ),
                              );

                              final artwork = artworkWidget;

                              final detailPadding = EdgeInsets.fromLTRB(
                                isLandscape ? 8 : 28,
                                0,
                                isLandscape ? 8 : 28,
                                isLandscape ? 8 : 8,
                              );
                              final subtitles = ref.read(
                                playbackSubtitleServiceProvider,
                              );
                              final subtitleSettings = ref.watch(
                                subtitleSettingsProvider.select(
                                  (state) => (
                                    state.isShowEnabled(session.id),
                                    state.isGlobalEnabled(session.id),
                                  ),
                                ),
                              );
                              return ListenableBuilder(
                                listenable: subtitles,
                                builder: (context, _) {
                                  final hasSubtitle = subtitles
                                      .hasKnownSubtitle(
                                        session.currentTrackPath,
                                      );

                                  return SessionDetailContent(
                                    transitionActive: widget.transitionActive,
                                    key: _detailContentKey,
                                    session: session,
                                    segmentPanelExpandedNotifier:
                                        widget.segmentPanelExpandedNotifier,
                                    isLandscape: isLandscape,
                                    artworkWidget: artwork,
                                    detailPadding: detailPadding,
                                    hasSubtitle: hasSubtitle,
                                    subtitleEnabled: subtitleSettings.$1,
                                    subtitleGlobalEnabled: subtitleSettings.$2,
                                    onToggleSubtitle: hasSubtitle
                                        ? () {
                                            ref
                                                .read(
                                                  subtitleSettingsProvider
                                                      .notifier,
                                                )
                                                .toggleShowSubtitles(
                                                  session.id,
                                                );
                                          }
                                        : null,
                                    onToggleGlobalSubtitle: () {
                                      final notifier = ref.read(
                                        subtitleSettingsProvider.notifier,
                                      );
                                      unawaited(
                                        _toggleGlobalSubtitleDisplay(
                                          notifier,
                                          ref.read(subtitleSettingsProvider),
                                          session.id,
                                        ),
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
