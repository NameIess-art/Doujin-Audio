import '../playback_providers.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/state/subtitle_settings_provider.dart';
import '../../../../core/ui/permission_action_controller.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../application/playback_session_snapshot.dart';
import '../../application/playback_subtitle_service.dart';
import '../../application/subtitle_overlay_controller.dart';
import 'playlist_feature_icons.dart';
import 'playlist_media_widgets.dart';
import 'playlist_shared_helpers.dart';
import 'session_detail_content.dart';

class SessionDetailScaffold extends ConsumerStatefulWidget {
  final ValueListenable<bool> transitionActive;
  final PlaybackSessionSnapshot session;
  final Future<String?> coverPathFuture;
  final Animation<double> dismissAnimation;
  final VoidCallback onClose;
  final ValueChanged<double>? onVerticalDragUpdate;
  final void Function(DragEndDetails)? onVerticalDragEnd;
  final VoidCallback? onVerticalDragCancel;
  final ValueNotifier<bool> segmentPanelExpandedNotifier;

  const SessionDetailScaffold({
    super.key,
    required this.transitionActive,
    required this.session,
    required this.coverPathFuture,
    required this.onClose,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
    required this.dismissAnimation,
    required this.segmentPanelExpandedNotifier,
  });

  @override
  ConsumerState<SessionDetailScaffold> createState() =>
      _SessionDetailScaffoldState();
}

class _SessionDetailScaffoldState extends ConsumerState<SessionDetailScaffold>
    with WidgetsBindingObserver {
  final _detailContentKey = GlobalKey<SessionDetailContentState>();
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  bool _isDismissGesture = false;
  late final PlaybackSubtitleService _subtitles;
  late bool _hasSubtitle;
  late final String _subtitlePresenceCommitKey =
      'detail_subtitle_presence_${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subtitles = ref.read(playbackSubtitleServiceProvider)
      ..addListener(_handleSubtitlePresenceChanged);
    _hasSubtitle = _subtitles.hasKnownSubtitle(widget.session.currentTrackPath);
    widget.transitionActive.addListener(_handleSubtitlePresenceChanged);
  }

  @override
  void didUpdateWidget(covariant SessionDetailScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transitionActive != widget.transitionActive) {
      oldWidget.transitionActive.removeListener(_handleSubtitlePresenceChanged);
      widget.transitionActive.addListener(_handleSubtitlePresenceChanged);
      _handleSubtitlePresenceChanged();
    }
    // Metadata can add a remote subtitle URL without changing the track path.
    _hasSubtitle = _subtitles.hasKnownSubtitle(widget.session.currentTrackPath);
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
    widget.transitionActive.removeListener(_handleSubtitlePresenceChanged);
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
    final paths = ref.read(audioPathCoordinatorProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final coverPathFuture = widget.coverPathFuture;
    final onClose = widget.onClose;
    final onVerticalDragUpdate = widget.onVerticalDragUpdate;
    final onVerticalDragEnd = widget.onVerticalDragEnd;
    final onVerticalDragCancel = widget.onVerticalDragCancel;
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;

    final track = paths.trackByPath(session.currentTrackPath);
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      animationDuration: Duration.zero,
      child: GestureDetector(
        key: const ValueKey('session_detail_dismiss_gesture'),
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: isWindows
            ? null
            : (details) {
                final detailState = _detailContentKey.currentState;
                final panelExpanded =
                    detailState?.isSegmentPanelExpanded ?? false;
                _isDismissGesture =
                    !panelExpanded && widget.dismissAnimation.value > 0.01;
              },
        onVerticalDragUpdate: isWindows
            ? null
            : (details) {
                final detailState = _detailContentKey.currentState;
                final panelExpanded =
                    detailState?.isSegmentPanelExpanded ?? false;
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
        onVerticalDragEnd: isWindows
            ? null
            : (details) {
                final detailState = _detailContentKey.currentState;
                final panelExpanded =
                    detailState?.isSegmentPanelExpanded ?? false;
                if (panelExpanded) return;

                if (_isDismissGesture) {
                  _isDismissGesture = false;
                  onVerticalDragEnd?.call(details);
                  return;
                }
              },
        onVerticalDragCancel: isWindows
            ? null
            : () {
                _isDismissGesture = false;
                onVerticalDragCancel?.call();
              },
        child: Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              top: false,
              child: AppPageContentTransition(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isLandscape =
                        isWindows ||
                        MediaQuery.orientationOf(context) ==
                            Orientation.landscape;
                    final topBarHeight = isWindows ? 48.0 : 40.0;

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Align(
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
                                      child: SizedBox(height: topBarHeight),
                                    ),
                                    if (_hasSubtitle &&
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
                            ),
                          ),
                        ),
                        Positioned.fill(
                          top: isLandscape ? 0 : topBarHeight,
                          child: Consumer(
                            builder: (context, ref, child) {
                              Widget artworkWidget = AnimatedSwitcher(
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : kAppFadeDuration,
                                reverseDuration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : kAppFadeDuration,
                                switchInCurve: kAppFadeCurve,
                                switchOutCurve: kAppFadeCurve,
                                transitionBuilder: (child, animation) =>
                                    MediaQuery.disableAnimationsOf(context)
                                    ? child
                                    : FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                layoutBuilder:
                                    (currentChild, previousChildren) {
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
                                isLandscape ? topBarHeight : 0,
                                isLandscape ? 8 : 28,
                                isLandscape ? 8 : 8,
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
                                key: _detailContentKey,
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
              top: MediaQuery.paddingOf(context).top + 6,
              left: 16,
              child: ValueListenableBuilder<bool>(
                valueListenable: widget.segmentPanelExpandedNotifier,
                builder: (context, expanded, child) =>
                    expanded ? const SizedBox.shrink() : child!,
                child: HeaderFloatingButton(
                  backgroundOpacity: 0.5,
                  child: IconButton(
                    key: const ValueKey('session_detail_close_button'),
                    onPressed: onClose,
                    tooltip: i18n.tr('close'),
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: sessionDetailForeground(
                        cs,
                        SessionDetailForegroundLevel.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
