import '../playback_providers.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui show Image, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/presentation/app_orientation_controller.dart';
import '../../../../app/presentation/windows_window_title_bar.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/ui/permission_action_controller.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/app_entry_ink_well.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../../application/subtitle_overlay_controller.dart';
import '../bedtime_canvas_page.dart';
import '../timer_tab.dart';
import 'playlist_feature_icons.dart';
import 'playlist_media_widgets.dart';
import 'playlist_volume_timer_widgets.dart';
import '../../../../core/media/music_track.dart';
import '../../../library/presentation/library_providers.dart';
import '../../../../core/widgets/async_cover_image.dart';
import 'playlist_shared_helpers.dart';
import 'session_detail_content.dart';
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
    with WidgetsBindingObserver {
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  late final PlaybackSubtitleService _subtitles;
  late bool _hasSubtitle;
  late bool _coverOverlaysVisible;
  late final String _subtitlePresenceCommitKey =
      'detail_subtitle_presence_${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _subtitles.removeListener(_handleSubtitlePresenceChanged);
    widget.transitionActive.removeListener(_handleTransitionChanged);
    UiInteractionCoordinator.instance.cancelCommit(_subtitlePresenceCommitKey);
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
    ref.watch(appLanguageStateProvider);
    final session = widget.session;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final coverPathFuture = widget.coverPathFuture;
    final onClose = widget.onClose;
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final isLandscape =
        isWindows || MediaQuery.orientationOf(context) == Orientation.landscape;
    final phoneLandscape =
        isLandscape &&
        AppOrientationPolicy.forDisplay(
              platform: defaultTargetPlatform,
              shortestSide: MediaQuery.sizeOf(context).shortestSide,
            ) ==
            AppOrientationPolicy.portrait;
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
    final closeButton = SessionOverlayIconButton(
      key: const ValueKey('session_detail_close_button'),
      onPressed: onClose,
      tooltip: i18n.tr('close'),
      icon: Icons.chevron_left_rounded,
    );
    final headerActionStyle =
        AppEntryInkWell.entryButtonStyle(Theme.of(context)).merge(
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

    final track = widget.track;
    final cs = Theme.of(context).colorScheme;
    final library = ref.read(libraryFacadeProvider);
    return Material(
      color: cs.surface,
      animationDuration: Duration.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _SessionDetailBlurredCoverBackground(
            requestKey: (session.id, track?.path ?? session.currentTrackPath),
            coverPathFuture: coverPathFuture,
            initialCoverPath: widget.initialCoverPath,
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

                          return Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: isLandscape ? topBarHeight : 18,
                                ),
                              ),
                              if (_hasSubtitle &&
                                  settings.$1 &&
                                  settings.$2) ...[
                                Icon(
                                  Icons.subtitles_rounded,
                                  color: isLandscape
                                      ? sessionDetailForeground(
                                          cs,
                                          SessionDetailForegroundLevel.muted,
                                        )
                                      : Colors.white,
                                  size: isLandscape ? 20 : 18,
                                ),
                                SizedBox(width: isLandscape ? 8 : 6),
                              ],
                              Consumer(
                                builder: (context, ref, child) {
                                  final transport = ref.watch(
                                    sessionDetailTransportProvider(session.id),
                                  );
                                  final featureIcons = sessionFeatureBadgeIcons(
                                    showSubtitles: false,
                                    channelSwapEnabled:
                                        transport?.channelSwapEnabled ??
                                        session.channelSwapEnabled,
                                    audioEffects:
                                        transport?.audioEffects ??
                                        session.audioEffects,
                                    speed: transport?.speed ?? session.speed,
                                  );
                                  if (featureIcons.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SessionFeatureIconRow(
                                        featureIcons: featureIcons,
                                        color: isLandscape
                                            ? sessionDetailForeground(
                                                cs,
                                                SessionDetailForegroundLevel
                                                    .muted,
                                              )
                                            : Colors.white,
                                        iconSize: isLandscape ? 20 : 18,
                                        spacing: isLandscape ? 8 : 6,
                                        alignment: WrapAlignment.end,
                                      ),
                                      SizedBox(width: isLandscape ? 8 : 6),
                                    ],
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
                        top: isLandscape
                            ? 0
                            : headerTop + AppPageHeaderMetrics.buttonSize + 8,
                        child: Consumer(
                          builder: (context, ref, child) {
                            final artworkWidget = SessionHeroArtwork(
                              key: ValueKey('artwork_${session.id}'),
                              session: session,
                              height: constraints.maxHeight,
                              track: track,
                              coverPathFuture: coverPathFuture,
                              initialCoverPath: widget.initialCoverPath,
                              coverAnchorKey: widget.detailCoverKey,
                              coverPreview: widget.coverPreview,
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
                  expanded ? const SizedBox.shrink() : child!,
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

                              if (timer.hasTimer) {
                                return TimerCountdownCapsule(
                                  key: const ValueKey(
                                    'session_detail_timer_capsule',
                                  ),
                                  showBackground: false,
                                  remaining:
                                      timer.timerRemaining ??
                                      timer.timerDuration ??
                                      Duration.zero,
                                  active: timer.timerActive,
                                  autoResumeAt: timer.autoResumeAt,
                                  onTap: openTimer,
                                );
                              }
                              return IconButton(
                                key: const ValueKey(
                                  'session_detail_timer_button',
                                ),
                                onPressed: openTimer,
                                style: headerActionStyle,
                                icon: const Icon(Icons.alarm_rounded),
                                tooltip: i18n.tr('timer'),
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                              );
                            },
                          ),
                          if (!isWindows) ...[
                            const SizedBox(width: 8),
                            Consumer(
                              builder: (context, ref, _) {
                                final hasPlayingAudio = ref.watch(
                                  playlistHeaderUiProvider.select(
                                    (state) => state.hasPlayingAudioSession,
                                  ),
                                );
                                return IconButton(
                                  key: const ValueKey(
                                    'session_detail_sleep_button',
                                  ),
                                  style: headerActionStyle,
                                  onPressed: hasPlayingAudio
                                      ? () => Navigator.of(
                                          context,
                                        ).push(BedtimeCanvasPage.route(context))
                                      : null,
                                  icon: const Icon(Icons.bedtime_outlined),
                                  tooltip: i18n.tr('sleep_mode'),
                                  iconSize: 20,
                                  padding: EdgeInsets.zero,
                                );
                              },
                            ),
                          ],
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionDetailBlurredCoverBackground extends StatelessWidget {
  const _SessionDetailBlurredCoverBackground({
    required this.requestKey,
    required this.coverPathFuture,
    required this.initialCoverPath,
    required this.onImageError,
  });

  final Object requestKey;
  final Future<String?> coverPathFuture;
  final String? initialCoverPath;
  final ValueChanged<String>? onImageError;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final isDark = theme.brightness == Brightness.dark;

    return Positioned.fill(
      child: IgnorePointer(
        child: AsyncCoverImage(
          future: coverPathFuture,
          requestKey: requestKey,
          initialPath: initialCoverPath,
          fallbackBuilder: _emptyBackground,
          loadingBuilder: _emptyBackground,
          imageBuilder: (_, path) => ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  // Palette changes repaint the tint without invalidating
                  // the filtered artwork layer.
                  child: Transform.scale(
                    scale: isDark ? 1.12 : 1.08,
                    child: ImageFiltered(
                      imageFilter: isDark ? _darkBlur : _lightBlur,
                      child: RetryingFileImage(
                        path: path,
                        deferLoadDuringInteraction: true,
                        onImageError: onImageError,
                        cacheWidth: 200,
                        useDefaultCacheWidth: false,
                        fit: BoxFit.cover,
                        fallbackBuilder: _emptyBackground,
                        loadingBuilder: _emptyBackground,
                      ),
                    ),
                  ),
                ),
                ColoredBox(
                  color: surface.withValues(alpha: isDark ? 0.70 : 0.80),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        surface.withValues(alpha: isDark ? 0.35 : 0.25),
                        Colors.transparent,
                        surface.withValues(alpha: isDark ? 0.50 : 0.40),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _emptyBackground(BuildContext _) => const SizedBox.shrink();
}
