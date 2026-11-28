import '../playback_providers.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui show Image, ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/presentation/windows_window_title_bar.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/ui/permission_action_controller.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../../application/subtitle_overlay_controller.dart';
import '../bedtime_canvas_page.dart';
import '../timer_tab.dart';
import 'playlist_media_widgets.dart';
import 'playlist_progress_widgets.dart';
import 'playlist_volume_timer_widgets.dart';
import '../../../../core/media/music_track.dart';
import '../../../library/presentation/library_providers.dart';
import '../../../../core/widgets/async_cover_image.dart';
import 'playlist_shared_helpers.dart';
import 'session_detail_content.dart';
import 'session_detail_route.dart';
import 'session_cover_transition.dart';

class SessionDetailScaffold extends ConsumerStatefulWidget {
  final ValueListenable<bool> transitionActive;
  final PlaybackSessionSnapshot session;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;
  final String? initialCoverPath;
  final GlobalKey<SessionCoverAnchorState>? detailCoverKey;
  final ui.Image? coverPreview;
  final bool deferCoverOverlays;
  final VoidCallback onClose;
  final ValueNotifier<bool> segmentPanelExpandedNotifier;

  const SessionDetailScaffold({
    super.key,
    required this.transitionActive,
    required this.session,
    required this.track,
    required this.coverPathFuture,
    this.initialCoverPath,
    required this.onClose,
    this.detailCoverKey,
    this.coverPreview,
    this.deferCoverOverlays = false,
    required this.segmentPanelExpandedNotifier,
  });

  @override
  ConsumerState<SessionDetailScaffold> createState() =>
      _SessionDetailScaffoldState();
}

class _SessionDetailScaffoldState extends ConsumerState<SessionDetailScaffold>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const double _dragDismissThreshold = 110;
  static const double _dragDismissVelocity = 650;
  final Object _dragDismissInteraction = Object();
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  late final PlaybackSubtitleService _subtitles;
  late bool _hasSubtitle;
  late bool _coverOverlaysVisible;
  late final String _subtitlePresenceCommitKey =
      'detail_subtitle_presence_${identityHashCode(this)}';
  late final AnimationController _dragResetController;
  Animation<double>? _dragResetAnimation;
  final ValueNotifier<double> _dragOffset = ValueNotifier(0);
  bool _dragThresholdReached = false;
  bool _dragDismissClosing = false;
  bool _dragDismissCanStart = false;
  bool _dragDismissInteractionActive = false;
  SessionDetailRoute? get _detailRoute {
    final route = readAppRoute(context);
    return route is SessionDetailRoute ? route : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dragResetController =
        AnimationController(vsync: this, duration: kAppMotionStandard)
          ..addListener(() {
            final animation = _dragResetAnimation;
            if (animation != null && mounted) {
              _dragOffset.value = animation.value;
            }
          })
          ..addStatusListener((status) {
            if ((status == AnimationStatus.completed ||
                    status == AnimationStatus.dismissed) &&
                _dragOffset.value == 0 &&
                mounted) {
              _detailRoute?.endInteractiveDismiss();
            }
          });
    _subtitles = ref.read(playbackSubtitleServiceProvider)
      ..addListener(_handleSubtitlePresenceChanged);
    _hasSubtitle = _subtitles.hasKnownSubtitle(widget.session.currentTrackPath);
    // Offstage route measurement temporarily reports a completed animation.
    _coverOverlaysVisible = !widget.deferCoverOverlays;
    widget.transitionActive.addListener(_handleTransitionChanged);
  }

  @override
  void didUpdateWidget(covariant SessionDetailScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionActive != widget.transitionActive) {
      oldWidget.transitionActive.removeListener(_handleTransitionChanged);
      widget.transitionActive.addListener(_handleTransitionChanged);
      _handleTransitionChanged();
    }
    // Metadata can add a remote subtitle URL without changing the track path.
    _hasSubtitle = _subtitles.hasKnownSubtitle(widget.session.currentTrackPath);
  }

  void _handleTransitionChanged() {
    // The flying cover paints above these overlays. Reveal them after landing,
    // then retain them so the route owns their fade on exit.
    if (!_coverOverlaysVisible && !widget.transitionActive.value) {
      setState(() => _coverOverlaysVisible = true);
    }
    _handleSubtitlePresenceChanged();
  }

  void _handleSubtitlePresenceChanged() {
    // Generation progress and other tracks do not change this page's controls.
    if (widget.transitionActive.value ||
        _hasSubtitle ==
            _subtitles.hasKnownSubtitle(widget.session.currentTrackPath)) {
      return;
    }
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _subtitlePresenceCommitKey,
      commit: () {
        if (!mounted || widget.transitionActive.value) return;
        final hasSubtitle = _subtitles.hasKnownSubtitle(
          widget.session.currentTrackPath,
        );
        if (_hasSubtitle != hasSubtitle) {
          setState(() => _hasSubtitle = hasSubtitle);
        }
      },
    );
  }

  @override
  void dispose() {
    _dragDismissInteractionActive = false;
    UiInteractionCoordinator.instance.cancelInteraction(_dragDismissInteraction);
    _dragResetController.dispose();
    _dragOffset.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _subtitles.removeListener(_handleSubtitlePresenceChanged);
    widget.transitionActive.removeListener(_handleTransitionChanged);
    UiInteractionCoordinator.instance.cancelCommit(_subtitlePresenceCommitKey);
    _permissionActionController.dispose();
    super.dispose();
  }

  bool _shouldAllowDragDismissPointer(PointerEvent event) {
    return !widget.transitionActive.value &&
        !_dragDismissClosing &&
        !widget.segmentPanelExpandedNotifier.value &&
        !SessionProgressBar.isInteracting &&
        !SessionProgressBar.isInProgressOrBottomControlsZone(event.position);
  }

  void _handleDragDismissStart(DragStartDetails details) {
    if (widget.transitionActive.value ||
        _dragDismissClosing ||
        widget.segmentPanelExpandedNotifier.value ||
        SessionProgressBar.isInteracting ||
        SessionProgressBar.isInProgressOrBottomControlsZone(
          details.globalPosition,
        )) {
      _dragDismissCanStart = false;
      return;
    }
    _dragDismissCanStart = true;
    _dragResetController.stop();
  }

  void _handleDragDismissUpdate(DragUpdateDetails details) {
    if (!_dragDismissCanStart ||
        widget.transitionActive.value ||
        _dragDismissClosing ||
        (_dragOffset.value == 0 &&
            (widget.segmentPanelExpandedNotifier.value ||
                SessionProgressBar.isInteracting))) {
      return;
    }
    final delta = details.delta.dy;
    final offset = _dragOffset.value;
    final maxOffset = MediaQuery.sizeOf(context).height * 0.65;
    final double nextOffset;
    if (offset >= _dragDismissThreshold && delta > 0) {
      final overDrag = (offset - _dragDismissThreshold).clamp(0.0, 400.0);
      final damping = 1.0 + (overDrag / 180.0);
      nextOffset = (offset + delta / damping).clamp(0.0, maxOffset);
    } else {
      nextOffset = (offset + delta).clamp(0.0, maxOffset);
    }
    if (nextOffset == offset) return;
    if (nextOffset > 0 && offset == 0) {
      if (!_dragDismissInteractionActive) {
        _dragDismissInteractionActive = true;
        UiInteractionCoordinator.instance.beginInteraction(
          _dragDismissInteraction,
        );
      }
      _detailRoute?.beginInteractiveDismiss();
    }
    final crossed = nextOffset >= _dragDismissThreshold;
    if (crossed != _dragThresholdReached) {
      _dragThresholdReached = crossed;
      if (crossed) {
        unawaited(
          AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
        );
      }
    }
    _dragOffset.value = nextOffset;
  }

  void _handleDragDismissEnd(DragEndDetails details) {
    final wasCanStart = _dragDismissCanStart;
    _dragDismissCanStart = false;
    if (_dragDismissInteractionActive) {
      _dragDismissInteractionActive = false;
      UiInteractionCoordinator.instance.endInteraction(_dragDismissInteraction);
    }
    if (!wasCanStart && _dragOffset.value == 0) {
      return;
    }
    if (widget.transitionActive.value || _dragDismissClosing) {
      _animateDragDismissBack();
      return;
    }
    final velocity = details.velocity.pixelsPerSecond.dy;
    final offset = _dragOffset.value;
    final shouldDismiss =
        offset >= _dragDismissThreshold ||
        (offset > 20 && velocity >= _dragDismissVelocity);
    if (shouldDismiss) {
      _dragDismissClosing = true;
      final detailRoute = _detailRoute;
      final viewportHeight = MediaQuery.sizeOf(context).height;
      if (detailRoute != null && viewportHeight > 0 && velocity > 0) {
        detailRoute.setExitReleaseVelocity(
          (velocity / viewportHeight).clamp(0.4, 6.0),
        );
      }
      widget.onClose();
      return;
    }
    _animateDragDismissBack(velocity: velocity);
  }

  void _handleDragDismissCancel() {
    _dragDismissCanStart = false;
    if (_dragDismissInteractionActive) {
      _dragDismissInteractionActive = false;
      UiInteractionCoordinator.instance.endInteraction(_dragDismissInteraction);
    }
    _animateDragDismissBack();
  }

  void _animateDragDismissBack({double velocity = 0.0}) {
    _dragThresholdReached = false;
    final start = _dragOffset.value;
    if (start == 0) {
      _detailRoute?.endInteractiveDismiss();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _dragOffset.value = 0;
      _detailRoute?.endInteractiveDismiss();
      return;
    }
    _dragResetAnimation = _dragResetController;
    final spring = SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: 520.0,
      ratio: 0.92,
    );
    _dragResetController.value = 0;
    _dragResetAnimation = Tween<double>(begin: 0, end: 1).animate(
      _dragResetController,
    );
    final normalizedVelocity = start > 0
        ? (-velocity / start).clamp(-8.0, 8.0)
        : 0.0;
    _dragResetAnimation = _dragResetController.drive(
      Tween<double>(begin: start, end: 0),
    );
    unawaited(
      _dragResetController.animateWith(
        SpringSimulation(
          spring,
          0.0,
          1.0,
          normalizedVelocity,
          tolerance: const Tolerance(velocity: 0.01),
        ),
      ),
    );
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
    ref.watch(appLanguageStateProvider);
    final session = widget.session;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final coverPathFuture = widget.coverPathFuture;
    final onClose = widget.onClose;
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final isLandscape =
        isWindows || MediaQuery.orientationOf(context) == Orientation.landscape;
    final phoneLandscape =
        !isWindows &&
        isLandscape &&
        MediaQuery.sizeOf(context).shortestSide < 600;
    final showHeaderActions = !phoneLandscape;
    final topBarHeight = isWindows ? 48.0 : 40.0;
    // Portrait detail is immersive; the shell's retained status-bar inset
    // belongs to the page behind it, not this header and cover.
    final topInset = isLandscape ? MediaQuery.paddingOf(context).top : 0.0;
    final closeTop =
        (isWindows
            ? WindowsWindowTitleBar.height
            : topInset) +
        AppPageHeaderMetrics.padding.top;
    // Landscape keeps status icons above the added shortcuts.
    final headerTop = !isLandscape || phoneLandscape || isWindows
        ? closeTop
        : math.max(closeTop, topBarHeight + 8);
    final landscapeContentTop = showHeaderActions
        ? math.max(
            topBarHeight,
            headerTop + AppPageHeaderMetrics.buttonSize + 8,
          )
        : topBarHeight;
    final closeButton = AppOverlayIconButton(
      key: const ValueKey('session_detail_close_button'),
      onPressed: onClose,
      tooltip: i18n.tr('close'),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
    );
    final headerActionStyle = appIconButtonStyle(
      IconButton.styleFrom(
        fixedSize: const Size.square(38),
        minimumSize: const Size.square(38),
        maximumSize: const Size.square(38),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: Colors.transparent,
        shape: const CircleBorder(),
      ),
    );
    final sleepButton = Consumer(
      builder: (context, ref, _) {
        final hasPlayingAudio = ref.watch(
          playlistHeaderUiProvider.select(
            (state) => state.hasPlayingAudioSession,
          ),
        );
        return IconButton(
          key: const ValueKey('session_detail_sleep_button'),
          style: headerActionStyle,
          onPressed: hasPlayingAudio
              ? () => unawaited(BedtimeCanvasPage.open(context))
              : null,
          icon: const Icon(Icons.bedtime_outlined),
          tooltip: i18n.tr('sleep_mode'),
          iconSize: 20,
          padding: EdgeInsets.zero,
        );
      },
    );

    final track = widget.track;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final library = ref.read(libraryFacadeProvider);
    final allowVerticalDismiss = !isWindows && !isLandscape;
    final content = Material(
      color: cs.surface,
      animationDuration: Duration.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _SessionDetailBlurredCoverBackground(
            isDark: isDark,
            requestKey: (session.id, track?.path ?? session.currentTrackPath),
            coverPathFuture: coverPathFuture,
            initialCoverPath: widget.initialCoverPath,
            coverPreview: widget.coverPreview,
            onImageError:
                library.coverArtworkCacheService.reportArtworkReadFailure,
          ),
          // This route covers the drawn title bar; blank space moves the window.
          if (isWindows) const WindowsWindowDragArea(child: SizedBox.expand()),
          SafeArea(
            top: false,
            child: AppPageContentTransition(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final statusIndicators = Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Consumer(
                        builder: (context, ref, child) {
                          final settings = ref.watch(
                            subtitleSettingsProvider.select(
                              (state) => (
                                state.isShowEnabled(session.id),
                                state.isGlobalEnabled(session.id),
                              ),
                            ),
                          );
                          final transport = ref.watch(
                            sessionDetailTransportProvider(session.id).select(
                              (state) => state == null
                                  ? null
                                  : (
                                      channelSwapEnabled:
                                          state.channelSwapEnabled,
                                      audioEffects: state.audioEffects,
                                      speed: state.speed,
                                    ),
                            ),
                          );
                          final badges = sessionFeatureBadgeVisibility(
                            showSubtitles:
                                _hasSubtitle && settings.$1 && settings.$2,
                            channelSwapEnabled:
                                transport?.channelSwapEnabled ??
                                session.channelSwapEnabled,
                            audioEffects:
                                transport?.audioEffects ?? session.audioEffects,
                            speed: transport?.speed ?? session.speed,
                          );
                          final reducedMotion = MediaQuery.disableAnimationsOf(
                            context,
                          );
                          final iconSize = isLandscape ? 20.0 : 18.0;
                          final spacing = isLandscape ? 8.0 : 6.0;
                          final color = isLandscape
                              ? sessionDetailForeground(
                                  cs,
                                  SessionDetailForegroundLevel.muted,
                                )
                              : Colors.white;
                          Widget badgeIcon(IconData icon) => Padding(
                            padding: EdgeInsets.only(right: spacing),
                            child: Icon(icon, size: iconSize, color: color),
                          );

                          return Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: isLandscape ? topBarHeight : 18,
                                ),
                              ),
                              for (final badge in badges.entries)
                                if (reducedMotion) ...[
                                  if (badge.value) badgeIcon(badge.key),
                                ] else
                                  TweenAnimationBuilder<double>(
                                    key: ValueKey(badge.key),
                                    tween: Tween(
                                      begin: 0,
                                      end: badge.value ? 1 : 0,
                                    ),
                                    duration: kAppFadeDuration,
                                    curve: kAppFadeCurve,
                                    child: badgeIcon(badge.key),
                                    builder: (context, progress, child) {
                                      if (progress == 0) {
                                        return const SizedBox.shrink();
                                      }
                                      return ClipRect(
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          widthFactor: progress,
                                          heightFactor: 1,
                                          child: Opacity(
                                            opacity: progress,
                                            child: child,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                            ],
                          );
                        },
                      ),
                    ),
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (isLandscape) statusIndicators,
                      Positioned.fill(
                        key: const ValueKey('session_detail_content_layer'),
                        top: isLandscape
                            ? 0
                            : headerTop + AppPageHeaderMetrics.buttonSize + 8,
                        child: Consumer(
                          builder: (context, ref, child) {
                            final effectiveCoverPreview =
                                _detailRoute?.coverPreviewFor(
                                  session.currentTrackPath,
                                ) ??
                                widget.coverPreview;
                            final coverPreviewHighRes =
                                _detailRoute?.hasHighResCoverPreview(
                                  session.currentTrackPath,
                                ) ??
                                false;
                            final artworkWidget = SessionHeroArtwork(
                              key: ValueKey('artwork_${session.id}'),
                              session: session,
                              height: constraints.maxHeight,
                              track: track,
                              coverPathFuture: coverPathFuture,
                              initialCoverPath: widget.initialCoverPath,
                              coverAnchorKey: widget.detailCoverKey,
                              coverPreview: effectiveCoverPreview,
                              coverPreviewHighRes: coverPreviewHighRes,
                              coverLanded: _coverOverlaysVisible,
                              // Creating the Android platform view can contend
                              // with the entrance. Retain it for the exit.
                              mountVideoSurface:
                                  defaultTargetPlatform !=
                                      TargetPlatform.android ||
                                  _coverOverlaysVisible,
                            );

                            final artwork = Stack(
                              fit: StackFit.expand,
                              children: [
                                artworkWidget,
                                if (!isLandscape)
                                  Positioned(
                                    top: 8,
                                    left: 0,
                                    right: 0,
                                    child: IgnorePointer(
                                      child: AnimatedOpacity(
                                        opacity: _coverOverlaysVisible ? 1 : 0,
                                        duration:
                                            MediaQuery.disableAnimationsOf(
                                              context,
                                            )
                                            ? Duration.zero
                                            : kAppFadeDuration,
                                        curve: kAppFadeCurve,
                                        child: IconTheme.merge(
                                          data: const IconThemeData(
                                            shadows: [
                                              Shadow(
                                                color: Color(0xA6000000),
                                                blurRadius: 5,
                                              ),
                                            ],
                                          ),
                                          child: statusIndicators,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );

                            final detailPadding = EdgeInsets.fromLTRB(
                              isLandscape ? 8 : 28,
                              isLandscape ? landscapeContentTop : 0,
                              isLandscape ? 8 : 28,
                              isLandscape ? 16 : 8,
                            );
                            final subtitleSettings = ref.watch(
                              subtitleSettingsProvider.select(
                                (state) => (
                                  state.isShowEnabled(session.id),
                                  state.isGlobalEnabled(session.id),
                                ),
                              ),
                            );
                            return SessionDetailContent(
                              transitionActive: widget.transitionActive,
                              showCoverOverlays: _coverOverlaysVisible,
                              session: session,
                              segmentPanelExpandedNotifier:
                                  widget.segmentPanelExpandedNotifier,
                              isLandscape: isLandscape,
                              artworkWidget: artwork,
                              detailPadding: detailPadding,
                              hasSubtitle: _hasSubtitle,
                              subtitleEnabled: subtitleSettings.$1,
                              subtitleGlobalEnabled: subtitleSettings.$2,
                              onToggleSubtitle: _hasSubtitle
                                  ? () {
                                      ref
                                          .read(
                                            subtitleSettingsProvider.notifier,
                                          )
                                          .toggleShowSubtitles(session.id);
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
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Positioned(
            top: headerTop,
            left: isWindows ? AppSpacing.xl : AppPageHeaderMetrics.padding.left,
            right: showHeaderActions
                ? AppPageHeaderMetrics.padding.right
                : null,
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.segmentPanelExpandedNotifier,
              builder: (context, expanded, child) =>
                  (expanded && !isLandscape) ? const SizedBox.shrink() : child!,
              child: AnimatedOpacity(
                key: const ValueKey('session_detail_close_fade'),
                opacity: _coverOverlaysVisible ? 1 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : kAppFadeDuration,
                curve: kAppFadeCurve,
                child: !showHeaderActions
                    ? closeButton
                    : Row(
                        children: [
                          closeButton,
                          const Spacer(),
                          Consumer(
                            builder: (context, ref, _) {
                              final timer = ref.watch(playlistHeaderUiProvider);
                              void openTimer() {
                                showTimerSettingsPanel(
                                  context,
                                  initialCompactDetail:
                                      timer.timerDuration != null,
                                );
                              }

                              final Widget timerChild;
                              if (timer.hasTimer) {
                                timerChild = RepaintBoundary(
                                  key: const ValueKey<String>(
                                    'session_detail_timer_capsule_slot',
                                  ),
                                  child: Consumer(
                                    builder: (context, ref, _) {
                                      final timerRemaining = ref.watch(
                                        playlistTimerRemainingUiProvider,
                                      );
                                      return TimerCountdownCapsule(
                                        key: const ValueKey(
                                          'session_detail_timer_capsule',
                                        ),
                                        showBackground: false,
                                        remaining:
                                            timerRemaining ??
                                            timer.timerDuration ??
                                            Duration.zero,
                                        active: timer.timerActive,
                                        autoResumeAt: timer.autoResumeAt,
                                        onTap: openTimer,
                                      );
                                    },
                                  ),
                                );
                              } else {
                                timerChild = IconButton(
                                  key: const ValueKey(
                                    'session_detail_timer_button',
                                  ),
                                  onPressed: openTimer,
                                  style: headerActionStyle,
                                  icon: const Icon(Icons.timer_rounded),
                                  tooltip: i18n.tr('timer'),
                                  iconSize: 20,
                                  padding: EdgeInsets.zero,
                                );
                              }
                              return AnimatedSwitcher(
                                duration: MediaQuery.disableAnimationsOf(
                                  context,
                                )
                                    ? Duration.zero
                                    : kAppMotionFast,
                                switchInCurve: kAppSpringCurve,
                                switchOutCurve: Curves.easeInCubic,
                                child: timerChild,
                              );
                            },
                          ),
                          if (!isWindows) ...[
                            const SizedBox(width: 8),
                            sleepButton,
                          ],
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: allowVerticalDismiss
          ? <Type, GestureRecognizerFactory>{
              _DetailDismissVerticalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    _DetailDismissVerticalDragGestureRecognizer
                  >(
                    () => _DetailDismissVerticalDragGestureRecognizer(
                      shouldAllowPointer: _shouldAllowDragDismissPointer,
                      debugOwner: this,
                    ),
                    (instance) {
                      instance
                        ..shouldAllowPointer = _shouldAllowDragDismissPointer
                        ..onStart = _handleDragDismissStart
                        ..onUpdate = _handleDragDismissUpdate
                        ..onEnd = _handleDragDismissEnd
                        ..onCancel = _handleDragDismissCancel;
                    },
                  ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: ValueListenableBuilder<double>(
        valueListenable: _dragOffset,
        // Keep the subtitle scroll position and console state across drags and
        // orientation changes, and cache the full page inside ClipRRect so
        // animating the drag corner radius never repaints content.
        child: RepaintBoundary(
          key: const ValueKey('session_detail_content_cache'),
          child: content,
        ),
        builder: (context, offset, child) {
          final effectiveOffset = allowVerticalDismiss ? offset : 0.0;
          final dragFraction = (effectiveOffset / 320.0).clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: effectiveOffset > 0
                        ? 0.28 * (1.0 - dragFraction)
                        : 0,
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(0, effectiveOffset),
                child: Transform.scale(
                  scale: 1.0 - (0.045 * dragFraction),
                  alignment: Alignment.topCenter,
                  child: ClipRRect(
                    clipBehavior: effectiveOffset > 0
                        ? Clip.antiAlias
                        : Clip.none,
                    borderRadius: BorderRadius.circular(24.0 * dragFraction),
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DetailDismissVerticalDragGestureRecognizer
    extends VerticalDragGestureRecognizer {
  _DetailDismissVerticalDragGestureRecognizer({
    required this.shouldAllowPointer,
    super.debugOwner,
  });

  bool Function(PointerEvent event) shouldAllowPointer;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (!shouldAllowPointer(event)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}

class _SessionDetailBlurredCoverBackground extends StatefulWidget {
  const _SessionDetailBlurredCoverBackground({
    required this.isDark,
    required this.requestKey,
    required this.coverPathFuture,
    required this.initialCoverPath,
    required this.coverPreview,
    required this.onImageError,
  });

  final bool isDark;
  final Object requestKey;
  final Future<String?> coverPathFuture;
  final String? initialCoverPath;
  final ui.Image? coverPreview;
  final ValueChanged<String>? onImageError;

  @override
  State<_SessionDetailBlurredCoverBackground> createState() =>
      _SessionDetailBlurredCoverBackgroundState();
}

class _SessionDetailBlurredCoverBackgroundState
    extends State<_SessionDetailBlurredCoverBackground> {
  static final _lightBlur = ui.ImageFilter.blur(
    sigmaX: 18,
    sigmaY: 18,
    tileMode: TileMode.clamp,
  );
  static final _darkBlur = ui.ImageFilter.blur(
    sigmaX: 30,
    sigmaY: 30,
    tileMode: TileMode.clamp,
  );

  Widget? _cachedChild;

  @override
  void didUpdateWidget(
    covariant _SessionDetailBlurredCoverBackground oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isDark != widget.isDark ||
        oldWidget.requestKey != widget.requestKey ||
        oldWidget.coverPathFuture != widget.coverPathFuture ||
        oldWidget.initialCoverPath != widget.initialCoverPath ||
        oldWidget.coverPreview != widget.coverPreview ||
        oldWidget.onImageError != widget.onImageError) {
      _cachedChild = null;
    }
  }

  Widget _buildBackground(Widget image) {
    final isDark = widget.isDark;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Isolate the full-screen blur in its own RepaintBoundary so animated
        // surface color transitions repaint only the cheap tint/gradient veil.
        RepaintBoundary(
          key: const ValueKey('session_detail_blurred_cover_layer'),
          child: ClipRect(
            child: Transform.scale(
              scale: isDark ? 1.12 : 1.08,
              child: ImageFiltered(
                imageFilter: isDark ? _darkBlur : _lightBlur,
                child: image,
              ),
            ),
          ),
        ),
        const _SessionDetailBackgroundVeil(),
      ],
    );
  }

  Widget _buildPreview(BuildContext context) {
    final preview = widget.coverPreview;
    if (preview == null) return const SizedBox.shrink();
    // The route owns this decoded cover and only supplies it for its track.
    return _buildBackground(RawImage(image: preview, fit: BoxFit.cover));
  }

  @override
  Widget build(BuildContext context) {
    return _cachedChild ??= Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: AsyncCoverImage(
            key: ValueKey(widget.requestKey),
            future: widget.coverPathFuture,
            requestKey: widget.requestKey,
            initialPath: widget.initialCoverPath,
            fallbackBuilder: _buildPreview,
            loadingBuilder: _buildPreview,
            imageBuilder: (_, path) => RetryingFileImage(
              key: ValueKey(path),
              path: path,
              onImageError: widget.onImageError,
              cacheWidth: 200,
              useDefaultCacheWidth: false,
              gaplessPlayback: false,
              fit: BoxFit.cover,
              fallbackBuilder: _buildPreview,
              resolvedFrameBuilder: (context, image, frame, synchronous) =>
                  frame == null && !synchronous
                  ? _buildPreview(context)
                  : _buildBackground(image),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDetailBackgroundVeil extends StatelessWidget {
  const _SessionDetailBackgroundVeil();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final isDark = theme.brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: surface.withValues(alpha: isDark ? 0.62 : 0.68)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                surface.withValues(alpha: isDark ? 0.32 : 0.22),
                Colors.transparent,
                surface.withValues(alpha: isDark ? 0.48 : 0.36),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}
