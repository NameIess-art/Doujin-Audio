import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_edit_panel.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_glass_surface.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session.dart' show PlaybackPositionSample;
import '../../application/playback_session_snapshot.dart';
import 'playlist_loop_widgets.dart';
import 'playlist_shared_helpers.dart';
import 'session_detail_theme.dart';

const double _kPlaybackPrimaryControlsWidth = 366;
// Six 46x40px capsule buttons and 3px concentric insets on each side
// yield a 46px-tall (23px-radius) bar around the 20px-radius end caps.
const double playbackSecondaryControlsWidth = 282;

class TransportPlaybackControlPanel extends StatelessWidget {
  const TransportPlaybackControlPanel({
    super.key,
    required this.session,
    required this.playback,
    required this.hasSiblings,
    required this.segmentPanelExpanded,
    required this.hasSubtitle,
    required this.subtitleEnabled,
    required this.subtitleGlobalEnabled,
    required this.onShowTrackSwitcher,
    required this.onToggleSegments,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onShowSubtitleMenu,
    this.onShowWorkDetail,
    this.isLandscape = false,
    this.showPrimaryControls = true,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final bool hasSiblings;
  final bool segmentPanelExpanded;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback onShowTrackSwitcher;
  final VoidCallback onToggleSegments;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onShowSubtitleMenu;
  final VoidCallback? onShowWorkDetail;
  final bool isLandscape;
  final bool showPrimaryControls;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showPrimaryControls)
          PrimaryPlaybackControls(
            session: session,
            playback: playback,
            isLandscape: isLandscape,
          ),
        if (isLandscape || !segmentPanelExpanded)
          AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : kAppFadeDuration,
            reverseDuration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : kAppFadeDuration,
            switchInCurve: kAppFadeCurve,
            switchOutCurve: kAppFadeCurve,
            child: KeyedSubtree(
              key: ValueKey('secondary_${session.id}'),
              child: _PlaybackSecondaryControls(
                session: session,
                playback: playback,
                hasSiblings: hasSiblings,
                segmentPanelExpanded: segmentPanelExpanded,
                hasSubtitle: hasSubtitle,
                subtitleEnabled: subtitleEnabled,
                subtitleGlobalEnabled: subtitleGlobalEnabled,
                onShowTrackSwitcher: onShowTrackSwitcher,
                onToggleSegments: onToggleSegments,
                onToggleSubtitle: onToggleSubtitle,
                onToggleGlobalSubtitle: onToggleGlobalSubtitle,
                onShowSubtitleMenu: onShowSubtitleMenu,
                onShowWorkDetail: onShowWorkDetail,
              ),
            ),
          ),
      ],
    );
  }
}

class PrimaryPlaybackControls extends ConsumerStatefulWidget {
  const PrimaryPlaybackControls({
    super.key,
    required this.session,
    required this.playback,
    this.isLandscape = false,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final bool isLandscape;

  @override
  ConsumerState<PrimaryPlaybackControls> createState() =>
      _PrimaryPlaybackControlsState();
}

class _PrimaryPlaybackControlsState
    extends ConsumerState<PrimaryPlaybackControls> {
  static const _rewindOffset = Duration(seconds: -5);
  static const _forwardOffset = Duration(seconds: 5);
  static const _seekRepeatInterval = Duration(milliseconds: 300);

  late final AppLifecycleListener _lifecycle;
  Timer? _seekRepeatTimer;
  Duration? _heldSeekOffset;
  bool _repeatSeekInFlight = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _stopSeekRepeat();
      },
    );
  }

  @override
  void didUpdateWidget(covariant PrimaryPlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playback != oldWidget.playback ||
        widget.session.id != oldWidget.session.id ||
        widget.session.currentTrackPath != oldWidget.session.currentTrackPath ||
        widget.session.currentQueueIndex !=
            oldWidget.session.currentQueueIndex) {
      _stopSeekRepeat();
    }
  }

  @override
  void deactivate() {
    _stopSeekRepeat();
    super.deactivate();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _stopSeekRepeat();
    super.dispose();
  }

  void _seekOnce(Duration offset) {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    unawaited(widget.playback.seekSessionByOffset(widget.session.id, offset));
  }

  void _startSeekRepeat(Duration offset) {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (_seekRepeatTimer != null ||
        (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    final playback = widget.playback;
    final session = playback.sessionById(widget.session.id);
    if (session == null ||
        session.isDisposed ||
        session.currentTrackPath.isEmpty ||
        session.currentTrackPath != widget.session.currentTrackPath ||
        session.currentQueueIndex != widget.session.currentQueueIndex) {
      return;
    }
    final trackPath = session.currentTrackPath;
    final queueIndex = session.currentQueueIndex;
    final loadGeneration = session.loadGeneration;

    Future<void> repeatSeek() async {
      final duration = session.duration;
      final atBoundary = offset.isNegative
          ? session.position <= Duration.zero
          : duration != null &&
                duration > Duration.zero &&
                session.position >= duration;
      if (ModalRoute.isCurrentOf(context) == false ||
          !identical(playback.sessionById(session.id), session) ||
          session.isDisposed ||
          session.currentTrackPath != trackPath ||
          session.currentQueueIndex != queueIndex ||
          session.loadGeneration != loadGeneration ||
          atBoundary) {
        _stopSeekRepeat();
        return;
      }
      if (_repeatSeekInFlight) return;
      _repeatSeekInFlight = true;
      try {
        await playback.seekSessionByOffset(session.id, offset);
      } finally {
        _repeatSeekInFlight = false;
      }
    }

    _heldSeekOffset = offset;
    _seekRepeatTimer = Timer.periodic(
      _seekRepeatInterval,
      (_) => unawaited(repeatSeek()),
    );
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    unawaited(repeatSeek());
  }

  void _finishSeekRepeat(Duration offset) {
    if (_heldSeekOffset == offset) _stopSeekRepeat();
  }

  void _stopSeekRepeat() {
    _seekRepeatTimer?.cancel();
    _seekRepeatTimer = null;
    _heldSeekOffset = null;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final playback = widget.playback;
    final isLandscape = widget.isLandscape;
    final transport = ref.watch(
      sessionDetailTransportProvider(session.id).select(
        (state) => (
          state?.showPauseIcon,
          state == null
              ? null
              : state.isPlaybackLoading || state.playbackError != null,
        ),
      ),
    );
    final showPauseIcon = transport.$1 ?? session.playbackRequested;
    final isLoading =
        transport.$2 ??
        (session.isPlaybackLoading || session.playbackError != null);
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final enabled = session.currentTrackPath.isNotEmpty;
    final primaryColor = cs.primary;
    final onPrimaryColor = cs.onPrimary;
    final hasPrevious = playback.hasSessionAdjacentTrack(
      session.id,
      forward: false,
    );
    final hasNext = playback.hasSessionAdjacentTrack(session.id, forward: true);
    final canNext = enabled && hasNext;

    final primaryRow = SizedBox(
      height: isLandscape ? 48 : 92,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 400;

          final skipIconSize = compact ? 28.0 : 32.0;
          final sideButtonSize = compact ? 48.0 : 54.0;
          final portraitPlayIconSize = compact ? 50.0 : 58.0;
          final portraitPlayButtonSize = compact ? 72.0 : 80.0;
          final playIconSize = isLandscape
              ? skipIconSize / 0.75
              : portraitPlayIconSize;
          final playButtonSize = isLandscape
              ? sideButtonSize
              : portraitPlayButtonSize;
          final sideBox = BoxConstraints.tightFor(
            width: sideButtonSize,
            height: sideButtonSize,
          );

          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _PreviousTrackButton(
                tooltip: i18n.tr('previous_track'),
                constraints: sideBox,
                session: session,
                enabled: enabled,
                hasPrevious: hasPrevious,
                iconSize: skipIconSize,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionToPrev(session.id);
                },
              ),
              PrimaryTransportButton(
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.replay_5_rounded,
                iconSize: skipIconSize * 0.85,
                nudgeX: -4,
                onPressed: () => _seekOnce(_rewindOffset),
                onHold: () => _startSeekRepeat(_rewindOffset),
                onHoldEnd: () => _finishSeekRepeat(_rewindOffset),
              ),
              Container(
                decoration: sessionDetailPlayButtonDecoration(
                  context,
                  primaryColor,
                  enabled: enabled,
                ),
                child: IconButton(
                  key: const ValueKey('session_detail_play_pause_button'),
                  tooltip: showPauseIcon ? i18n.tr('pause') : i18n.tr('play'),
                  constraints: BoxConstraints.tightFor(
                    width: playButtonSize,
                    height: playButtonSize,
                  ),
                  padding: EdgeInsets.zero,
                  style: appTransportIconButtonStyle(
                    const ButtonStyle(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  onPressed: enabled
                      ? () {
                          AppInteractionFeedback.trigger(
                            AppInteractionFeedbackType.confirmation,
                          );
                          playback.toggleSessionPlayPause(session.id);
                        }
                      : null,
                  iconSize: playIconSize,
                  icon: AppPlaybackIconTransition(
                    child: isLoading
                        ? SizedBox(
                            key: const ValueKey('loading'),
                            width: playIconSize * 0.48,
                            height: playIconSize * 0.48,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: enabled
                                  ? onPrimaryColor
                                  : cs.onSurface.withValues(alpha: 0.35),
                            ),
                          )
                        : Icon(
                            showPauseIcon
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            key: ValueKey(showPauseIcon),
                            size: playIconSize * 0.75,
                            color: enabled
                                ? onPrimaryColor
                                : cs.onSurface.withValues(alpha: 0.35),
                          ),
                  ),
                ),
              ),
              PrimaryTransportButton(
                constraints: sideBox,
                enabled: enabled,
                icon: Icons.forward_5_rounded,
                iconSize: skipIconSize * 0.8,
                nudgeX: 4,
                onPressed: () => _seekOnce(_forwardOffset),
                onHold: () => _startSeekRepeat(_forwardOffset),
                onHoldEnd: () => _finishSeekRepeat(_forwardOffset),
              ),
              PrimaryTransportButton(
                tooltip: i18n.tr('next_track'),
                constraints: sideBox,
                enabled: canNext,
                icon: Icons.skip_next_rounded,
                iconSize: skipIconSize,
                nudgeX: 4,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionToNext(session.id);
                },
              ),
            ],
          );
        },
      ),
    );

    if (isLandscape) {
      return ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: _kPlaybackPrimaryControlsWidth,
        ),
        child: SizedBox(
          width: _kPlaybackPrimaryControlsWidth,
          child: primaryRow,
        ),
      );
    }

    return primaryRow;
  }
}

class _PlaybackSecondaryControls extends ConsumerStatefulWidget {
  const _PlaybackSecondaryControls({
    required this.session,
    required this.playback,
    required this.hasSiblings,
    required this.segmentPanelExpanded,
    required this.hasSubtitle,
    required this.subtitleEnabled,
    required this.subtitleGlobalEnabled,
    required this.onShowTrackSwitcher,
    required this.onToggleSegments,
    this.onToggleSubtitle,
    this.onToggleGlobalSubtitle,
    this.onShowSubtitleMenu,
    this.onShowWorkDetail,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final bool hasSiblings;
  final bool segmentPanelExpanded;
  final bool hasSubtitle;
  final bool subtitleEnabled;
  final bool subtitleGlobalEnabled;
  final VoidCallback onShowTrackSwitcher;
  final VoidCallback onToggleSegments;
  final VoidCallback? onToggleSubtitle;
  final VoidCallback? onToggleGlobalSubtitle;
  final VoidCallback? onShowSubtitleMenu;
  final VoidCallback? onShowWorkDetail;

  @override
  ConsumerState<_PlaybackSecondaryControls> createState() =>
      _PlaybackSecondaryControlsState();
}

class _PlaybackSecondaryControlsState
    extends ConsumerState<_PlaybackSecondaryControls> {
  double get _currentVolume =>
      widget.playback.sessionById(widget.session.id)?.volume ??
      widget.session.volume;
  bool _volumeMode = false;
  final _volumePreview = ValueNotifier<double?>(null);

  @override
  void dispose() {
    final pendingVolume = _volumePreview.value;
    if (pendingVolume != null) {
      UiInteractionCoordinator.instance.cancelThrottledCommit(
        SessionVolumeControls.commitKey(widget.session.id),
      );
      AppInteractionFeedback.resetContinuous();
      unawaited(
        widget.playback.setSessionVolume(widget.session.id, pendingVolume),
      );
    }
    _volumePreview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    ref.watch(
      sessionDetailTransportProvider(
        widget.session.id,
      ).select((state) => state == null ? null : sessionVolumeIcon(state.volume)),
    );

    Widget buildButtonsRow() {
      final buttons = <Widget>[
        SessionLoopModeButton(
          session: widget.session,
          playback: widget.playback,
        ),
        _SecondaryControlButton(
          key: const ValueKey('session_volume_button_anchor'),
          icon: sessionVolumeIcon(_currentVolume),
          tooltip: i18n.tr('volume'),
          onPressed: () {
            setState(() => _volumeMode = true);
          },
        ),
        _SecondaryControlButton(
          key: const ValueKey('session_subtitle_menu_button'),
          icon: Icons.subtitles_rounded,
          tooltip: i18n.tr('subtitles'),
          active: widget.subtitleEnabled && widget.hasSubtitle,
          onPressed: widget.onShowSubtitleMenu,
        ),
        _SecondaryControlButton(
          icon: Icons.tune_rounded,
          tooltip: i18n.tr('audio_features'),
          active: widget.segmentPanelExpanded,
          onPressed: widget.onToggleSegments,
        ),
        _SecondaryControlButton(
          icon: Icons.queue_music_rounded,
          tooltip: i18n.tr('switch_audio'),
          onPressed: widget.hasSiblings ? widget.onShowTrackSwitcher : null,
        ),
        _SecondaryControlButton(
          key: const ValueKey('session_work_detail_button'),
          icon: Icons.info_outline_rounded,
          tooltip: i18n.tr('audio_detail'),
          onPressed: widget.onShowWorkDetail,
        ),
      ];
      return LayoutBuilder(
        key: const ValueKey('playback_buttons_row'),
        builder: (context, constraints) => WindowsHorizontalWheelScroll(
          builder: (scrollController) => SingleChildScrollView(
            key: const ValueKey(
              'playback_secondary_controls_horizontal_scroll',
            ),
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: max(0.0, constraints.maxWidth - 6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final button in buttons) _buildSecondaryControlSlot(button),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
      child: SizedBox(
        key: const ValueKey('playback_secondary_controls'),
        width: playbackSecondaryControlsWidth,
        child: PlaybackSecondaryControlSurface(
          child: AnimatedSwitcher(
            switchOutCurve: kAppFadeCurve,
            switchInCurve: kAppFadeCurve,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : kAppFadeDuration,
            child: _volumeMode
                ? SessionVolumeControls(
                    session: widget.session,
                    playback: widget.playback,
                    volumePreview: _volumePreview,
                    onBack: () => setState(() => _volumeMode = false),
                  )
                : buildButtonsRow(),
          ),
        ),
      ),
    );
  }
}

class PlaybackSecondaryControlSurface extends StatelessWidget {
  const PlaybackSecondaryControlSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final glassEnabled = AppDesignTokens.of(context).barGlassEnabled;
    const capsuleHeight = 46.0;
    const borderRadius = BorderRadius.all(Radius.circular(capsuleHeight / 2));
    return SizedBox(
      height: capsuleHeight,
      child: AppGlassSurface(
        enabled: glassEnabled,
        backgroundColor: glassEnabled
            ? background.withValues(alpha: background.a * 0.9)
            : background,
        borderRadius: borderRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.55),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class SessionVolumeControls extends ConsumerStatefulWidget {
  const SessionVolumeControls({
    super.key,
    required this.session,
    required this.playback,
    required this.volumePreview,
    this.onBack,
    this.onInteractionStart,
    this.onInteractionEnd,
    this.onOperationFailure,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final ValueNotifier<double?> volumePreview;
  final VoidCallback? onBack;
  final VoidCallback? onInteractionStart;
  final VoidCallback? onInteractionEnd;
  final VoidCallback? onOperationFailure;

  static String commitKey(String sessionId) => 'session_volume:$sessionId';

  @override
  ConsumerState<SessionVolumeControls> createState() =>
      _SessionVolumeControlsState();
}

class _SessionVolumeControlsState extends ConsumerState<SessionVolumeControls> {
  final _hoverPercent = ValueNotifier<int?>(null);

  String get _sessionId => widget.session.id;

  double get _currentVolume =>
      widget.volumePreview.value ??
      widget.playback.sessionById(_sessionId)?.volume ??
      widget.session.volume;

  @override
  void dispose() {
    _hoverPercent.dispose();
    super.dispose();
  }

  void _handleVolumeChange(double displayValue) {
    final gain = sessionVolumeGainFromDisplayValue(displayValue);
    widget.volumePreview.value = gain;
    AppInteractionFeedback.continuous((displayValue * 100).round());
    final playback = widget.playback;
    final sessionId = _sessionId;
    UiInteractionCoordinator.instance.scheduleThrottledCommit(
      key: SessionVolumeControls.commitKey(sessionId),
      commit: () => playback.setSessionVolume(sessionId, gain, persist: false),
    );
  }

  void _handleVolumeChangeEnd(double displayValue) {
    UiInteractionCoordinator.instance.cancelThrottledCommit(
      SessionVolumeControls.commitKey(_sessionId),
    );
    widget.volumePreview.value = null;
    AppInteractionFeedback.resetContinuous();
    widget.onInteractionEnd?.call();
    unawaited(_commitVolume(sessionVolumeGainFromDisplayValue(displayValue)));
  }

  Future<void> _commitVolume(double gain) async {
    final ok = await widget.playback.setSessionVolume(_sessionId, gain);
    if (!ok && mounted) widget.onOperationFailure?.call();
  }

  Future<void> _showVolumeInput() async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final sessionId = _sessionId;
    final queueColor = widget.session.playbackQueue?.colorValue;
    final initialVolume = sessionVolumeDisplayValueFromGain(_currentVolume);
    widget.onInteractionStart?.call();
    try {
      final percent = await showAppTextInputPanel<int>(
        context: context,
        header: AppEditPanelHeader(
          icon: Icons.volume_up_rounded,
          title: i18n.tr('volume'),
          accentColor: queueColor == null ? null : Color(queueColor),
        ),
        surfaceKey: const ValueKey('session_volume_input_surface'),
        inputKey: const ValueKey('session_volume_input'),
        initialValue: '${(initialVolume * 100).round()}',
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: i18n.tr('volume_range_hint')),
        cancelLabel: i18n.tr('cancel'),
        submitLabel: i18n.tr('confirm'),
        parse: (text) {
          final value = int.tryParse(text.trim());
          if (value == null ||
              value < 0 ||
              value > sessionVolumeDisplayMaximumPercent) {
            return null;
          }
          return value;
        },
      );
      if (!mounted || _sessionId != sessionId || percent == null) return;
      await _commitVolume(sessionVolumeGainFromDisplayValue(percent / 100));
    } finally {
      if (mounted) widget.onInteractionEnd?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      sessionDetailTransportProvider(
        _sessionId,
      ).select((state) => state?.volume),
    );
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ValueListenableBuilder<double?>(
      valueListenable: widget.volumePreview,
      builder: (context, _, _) {
        final gain = _currentVolume;
        final displayVolume = sessionVolumeDisplayValueFromGain(gain);
        final isBoosted = gain > 1;
        final labelStyle = theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w900,
          fontSize: 11,
          color: isBoosted ? cs.primary : null,
          decoration: TextDecoration.underline,
          decorationColor: (isBoosted ? cs.primary : cs.onSurface).withValues(
            alpha: 0.3,
          ),
        );
        return Padding(
          key: const ValueKey('playback_volume_controls_row'),
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Row(
            children: [
              if (widget.onBack case final onBack?)
                _buildSecondaryControlSlot(
                  _SecondaryControlButton(
                    buttonKey: const ValueKey('session_volume_exit_button'),
                    icon: Icons.arrow_back_rounded,
                    tooltip: i18n.tr('back'),
                    onPressed: onBack,
                  ),
                ),
              _buildSecondaryControlSlot(
                _SecondaryControlButton(
                  buttonKey: const ValueKey('session_volume_mute_button'),
                  icon: sessionVolumeIcon(gain),
                  tooltip: gain <= 0.001 ? i18n.tr('unmute') : i18n.tr('mute'),
                  foregroundColor: isBoosted ? cs.primary : null,
                  onPressed: () async {
                    final ok = await widget.playback.toggleSessionMute(
                      _sessionId,
                    );
                    if (!ok && mounted) widget.onOperationFailure?.call();
                  },
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: sessionDetailVolumeSliderTheme(
                    context,
                    isBoosted: isBoosted,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final trackWidth =
                          constraints.maxWidth -
                          2 * sessionDetailVolumeTrackInset;
                      final isRtl =
                          Directionality.of(context) == TextDirection.rtl;

                      void previewVolume(double x) {
                        if (widget.volumePreview.value != null ||
                            trackWidth <= 0) {
                          return;
                        }
                        final fraction =
                            ((x - sessionDetailVolumeTrackInset) / trackWidth)
                                .clamp(0.0, 1.0);
                        final ratio = isRtl ? 1 - fraction : fraction;
                        _hoverPercent.value =
                            (ratio * sessionVolumeDisplayMaximumPercent)
                                .round();
                      }

                      return MouseRegion(
                        onEnter: (event) =>
                            previewVolume(event.localPosition.dx),
                        onHover: (event) =>
                            previewVolume(event.localPosition.dx),
                        onExit: (_) => _hoverPercent.value = null,
                        child: Slider(
                          key: const ValueKey('session_volume_slider'),
                          semanticFormatterCallback: (value) =>
                              '${(value * 100).round()}%',
                          value: displayVolume,
                          max: sessionVolumeDisplayMaximum,
                          onChangeStart: (_) {
                            _hoverPercent.value = null;
                            widget.onInteractionStart?.call();
                          },
                          onChanged: _handleVolumeChange,
                          onChangeEnd: _handleVolumeChangeEnd,
                        ),
                      );
                    },
                  ),
                ),
              ),
              InkWell(
                mouseCursor: WidgetStateMouseCursor.clickable,
                key: const ValueKey('session_volume_percent_text'),
                onTap: _showVolumeInput,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(
                    // Keep the track width stable as the preview gains digits.
                    width: MediaQuery.textScalerOf(context).scale(30),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: ValueListenableBuilder<int?>(
                        valueListenable: _hoverPercent,
                        builder: (context, hoverPercent, _) => Text(
                          '${hoverPercent ?? (displayVolume * 100).round()}%',
                          style: labelStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class PrimaryTransportButton extends StatefulWidget {
  const PrimaryTransportButton({
    super.key,
    required this.constraints,
    required this.enabled,
    required this.icon,
    required this.iconSize,
    required this.onPressed,
    this.onHold,
    this.onHoldEnd,
    this.tooltip,
    this.nudgeX = 0,
  });

  final BoxConstraints constraints;
  final bool enabled;
  final IconData icon;
  final double iconSize;
  final VoidCallback onPressed;
  final VoidCallback? onHold;
  final VoidCallback? onHoldEnd;
  final String? tooltip;
  final double nudgeX;

  @override
  State<PrimaryTransportButton> createState() => _PrimaryTransportButtonState();
}

class _PrimaryTransportButtonState extends State<PrimaryTransportButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _nudgeController;
  late Animation<double> _nudgeOffset;
  int? _pressedPointer;

  @override
  void initState() {
    super.initState();
    _nudgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _rebuildNudgeAnimation();
  }

  @override
  void didUpdateWidget(covariant PrimaryTransportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nudgeX != widget.nudgeX) {
      _rebuildNudgeAnimation();
    }
    if (!widget.enabled && oldWidget.enabled) {
      _nudgeController.reset();
      _pressedPointer = null;
    }
  }

  @override
  void dispose() {
    _nudgeController.dispose();
    super.dispose();
  }

  void _rebuildNudgeAnimation() {
    if (widget.nudgeX == 0) {
      _nudgeOffset = const AlwaysStoppedAnimation<double>(0);
      return;
    }
    _nudgeOffset = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: widget.nudgeX,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: widget.nudgeX,
          end: 0,
        ).chain(CurveTween(curve: kAppSpringBackCurve)),
        weight: 65,
      ),
    ]).animate(_nudgeController);
  }

  void _handlePressed() {
    if (widget.nudgeX != 0 &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled) {
      _nudgeController.forward(from: 0);
    }
    widget.onPressed();
  }

  void _finishPointer(PointerEvent event) {
    if (event.pointer != _pressedPointer) return;
    _pressedPointer = null;
    widget.onHoldEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = sessionDetailForeground(
      cs,
      SessionDetailForegroundLevel.strong,
    );
    final plateColor = isDark
        ? cs.surfaceContainerHighest.withValues(
            alpha: widget.enabled ? 0.35 : 0.15,
          )
        : cs.surfaceContainerHighest.withValues(
            alpha: widget.enabled ? 0.50 : 0.20,
          );

    final iconWidget = Icon(widget.icon, size: widget.iconSize);

    final button = Container(
      constraints: widget.constraints,
      decoration: BoxDecoration(shape: BoxShape.circle, color: plateColor),
      child: IconButton(
        tooltip: widget.tooltip,
        constraints: widget.constraints,
        padding: EdgeInsets.zero,
        style: appTransportIconButtonStyle(
          IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: iconColor,
            disabledForegroundColor: iconColor.withValues(alpha: 0.35),
          ),
        ),
        onPressed: widget.enabled ? _handlePressed : null,
        onLongPress: widget.enabled && widget.onHold != null
            ? () {
                // Semantics can invoke long press without a pointer release.
                if (_pressedPointer == null) {
                  _handlePressed();
                } else {
                  widget.onHold!();
                }
              }
            : null,
        icon: widget.nudgeX == 0
            ? iconWidget
            : AnimatedBuilder(
                animation: _nudgeController,
                child: iconWidget,
                builder: (context, child) {
                  final dx = _nudgeOffset.value;
                  if (dx == 0) return child!;
                  return Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  );
                },
              ),
      ),
    );
    if (!widget.enabled || widget.onHold == null) return button;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kPrimaryButton) _pressedPointer ??= event.pointer;
      },
      onPointerMove: (event) {
        if ((event.buttons & kPrimaryButton) == 0) _finishPointer(event);
      },
      onPointerUp: _finishPointer,
      onPointerCancel: _finishPointer,
      child: button,
    );
  }
}

Widget _buildSecondaryControlSlot(Widget child) => SizedBox(
  width: playbackSecondaryControlButtonWidth,
  height: playbackSecondaryControlButtonHeight,
  child: ClipPath(
    clipper: const ShapeBorderClipper(shape: StadiumBorder()),
    child: child,
  ),
);

class _SecondaryControlButton extends StatelessWidget {
  const _SecondaryControlButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    this.active = false,
    this.foregroundColor,
    this.onPressed,
  });

  final Key? buttonKey;
  final IconData icon;
  final String tooltip;
  final bool active;
  final Color? foregroundColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      key: buttonKey,
      constraints: playbackSecondaryControlButtonConstraints,
      padding: EdgeInsets.zero,
      tooltip: tooltip,
      style: playbackSecondaryControlButtonStyle(
        backgroundColor: active
            ? cs.primaryContainer.withValues(alpha: 0.65)
            : Colors.transparent,
        foregroundColor: active
            ? cs.onPrimaryContainer
            : foregroundColor ??
                  sessionDetailForeground(
                    cs,
                    SessionDetailForegroundLevel.muted,
                  ),
        disabledForegroundColor: cs.onSurface.withValues(alpha: 0.35),
      ),
      onPressed: onPressed != null
          ? () {
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              );
              onPressed!();
            }
          : null,
      icon: AppPlaybackIconTransition(
        beginScale: 0.72,
        child: Icon(icon, key: ValueKey(icon), size: 20),
      ),
    );
  }
}

class _PreviousTrackButton extends StatefulWidget {
  const _PreviousTrackButton({
    required this.tooltip,
    required this.constraints,
    required this.session,
    required this.enabled,
    required this.hasPrevious,
    required this.iconSize,
    required this.onPressed,
  });

  final String tooltip;
  final BoxConstraints constraints;
  final PlaybackSessionSnapshot session;
  final bool enabled;
  final bool hasPrevious;
  final double iconSize;
  final VoidCallback onPressed;

  @override
  State<_PreviousTrackButton> createState() => _PreviousTrackButtonState();
}

class _PreviousTrackButtonState extends State<_PreviousTrackButton> {
  StreamSubscription<PlaybackPositionSample>? _positionSub;
  bool _pastRestartThreshold = false;

  bool get _needsThresholdWatch => widget.enabled && !widget.hasPrevious;

  @override
  void initState() {
    super.initState();
    _pastRestartThreshold = widget.session.position.inSeconds > 3;
    _syncSubscription();
  }

  @override
  void didUpdateWidget(covariant _PreviousTrackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextThreshold = widget.session.position.inSeconds > 3;
    if (widget.session.id != oldWidget.session.id ||
        widget.session.progressStream != oldWidget.session.progressStream ||
        _needsThresholdWatch != (oldWidget.enabled && !oldWidget.hasPrevious)) {
      _pastRestartThreshold = nextThreshold;
      _syncSubscription();
    } else if (_pastRestartThreshold != nextThreshold) {
      _pastRestartThreshold = nextThreshold;
    }
  }

  void _syncSubscription() {
    unawaited(_positionSub?.cancel());
    _positionSub = null;
    if (!_needsThresholdWatch) return;
    _positionSub = widget.session.progressStream.listen((sample) {
      final past = sample.position.inSeconds > 3;
      if (past != _pastRestartThreshold && mounted) {
        setState(() => _pastRestartThreshold = past);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_positionSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PrimaryTransportButton(
      tooltip: widget.tooltip,
      constraints: widget.constraints,
      enabled: widget.enabled && (widget.hasPrevious || _pastRestartThreshold),
      icon: Icons.skip_previous_rounded,
      iconSize: widget.iconSize,
      nudgeX: -4,
      onPressed: widget.onPressed,
    );
  }
}
