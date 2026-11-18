import 'dart:async';
import 'dart:math';

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
const double _kPlaybackSecondaryControlsWidth = 282;

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

class PrimaryPlaybackControls extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionByOffset(
                    session.id,
                    const Duration(seconds: -5),
                  );
                },
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
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  );
                  playback.seekSessionByOffset(
                    session.id,
                    const Duration(seconds: 5),
                  );
                },
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
  double? _dragVolume;
  double? _preMuteVolume;

  IconData _getIconForVolume(double volume) {
    return volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.45
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
  }

  void _toggleMute() {
    final currentVolume = (_dragVolume ?? _currentVolume)
        .clamp(0.0, PlaybackFacade.maxSessionVolume)
        .toDouble();
    if (currentVolume > 0.001) {
      _preMuteVolume = currentVolume;
      setState(() => _dragVolume = null);
      widget.playback.setSessionVolume(widget.session.id, 0.0);
    } else {
      final restored = (_preMuteVolume != null && _preMuteVolume! > 0.001)
          ? _preMuteVolume!
          : 1.0;
      _preMuteVolume = null;
      setState(() => _dragVolume = null);
      widget.playback.setSessionVolume(widget.session.id, restored);
    }
  }

  Future<void> _showVolumeInput(BuildContext context) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final sessionId = widget.session.id;
    final queueColor = widget.session.playbackQueue?.colorValue;
    final initialVolume = sessionVolumeDisplayValueFromGain(
      _dragVolume ?? _currentVolume,
    );
    final percent = await showAppTextInputPanel<int>(
      context: context,
      barrierLabel: i18n.tr('close'),
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
    if (!mounted || widget.session.id != sessionId || percent == null) return;
    final volumeGain = sessionVolumeGainFromDisplayValue(percent / 100);
    setState(() => _dragVolume = null);
    await widget.playback.setSessionVolume(sessionId, volumeGain);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);

    ref.watch(
      sessionDetailTransportProvider(
        widget.session.id,
      ).select((state) => state?.volume),
    );
    final volumeGain = (_dragVolume ?? _currentVolume)
        .clamp(0.0, PlaybackFacade.maxSessionVolume)
        .toDouble();
    final displayVolume = sessionVolumeDisplayValueFromGain(volumeGain);
    final isBoosted = volumeGain > 1.0;

    Widget buildVolumeBar() {
      return Padding(
        key: const ValueKey('playback_volume_controls_row'),
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Row(
          children: [
            _buildSecondaryControlSlot(
              _SecondaryControlButton(
                buttonKey: const ValueKey('session_volume_exit_button'),
                icon: Icons.arrow_back_rounded,
                tooltip: i18n.tr('back'),
                onPressed: () {
                  setState(() {
                    _volumeMode = false;
                    _dragVolume = null;
                  });
                },
              ),
            ),
            _buildSecondaryControlSlot(
              _SecondaryControlButton(
                buttonKey: const ValueKey('session_volume_mute_button'),
                icon: _getIconForVolume(volumeGain),
                tooltip: volumeGain == 0 ? i18n.tr('unmute') : i18n.tr('mute'),
                foregroundColor: isBoosted ? cs.primary : null,
                onPressed: _toggleMute,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: sessionDetailVolumeSliderTheme(
                  context,
                  isBoosted: isBoosted,
                ),
                child: Slider(
                  key: const ValueKey('session_volume_slider'),
                  value: displayVolume,
                  max: sessionVolumeDisplayMaximum,
                  onChanged: (displayValue) {
                    final newGain = sessionVolumeGainFromDisplayValue(
                      displayValue,
                    );
                    setState(() => _dragVolume = newGain);
                    AppInteractionFeedback.continuous(
                      (displayValue * 100).round(),
                    );
                    UiInteractionCoordinator.instance.scheduleThrottledCommit(
                      key: 'session_volume:${widget.session.id}',
                      commit: () => widget.playback.setSessionVolume(
                        widget.session.id,
                        newGain,
                        persist: false,
                      ),
                    );
                  },
                  onChangeEnd: (displayValue) {
                    final newGain = sessionVolumeGainFromDisplayValue(
                      displayValue,
                    );
                    setState(() => _dragVolume = null);
                    AppInteractionFeedback.resetContinuous();
                    UiInteractionCoordinator.instance.cancelThrottledCommit(
                      'session_volume:${widget.session.id}',
                    );
                    widget.playback.setSessionVolume(
                      widget.session.id,
                      newGain,
                    );
                  },
                ),
              ),
            ),
            InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              key: const ValueKey('session_volume_percent_text'),
              onTap: () => _showVolumeInput(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${(displayVolume * 100).round()}%',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    color: isBoosted ? cs.primary : null,
                    decoration: TextDecoration.underline,
                    decorationColor: (isBoosted ? cs.primary : cs.onSurface)
                        .withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget buildButtonsRow() {
      final buttons = <Widget>[
        SessionLoopModeButton(
          session: widget.session,
          playback: widget.playback,
        ),
        _SecondaryControlButton(
          key: const ValueKey('session_volume_button_anchor'),
          icon: _getIconForVolume(_currentVolume),
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final glassEnabled = AppDesignTokens.of(context).barGlassEnabled;
    const double capsuleHeight = 46;
    final borderRadius = BorderRadius.circular(capsuleHeight / 2);

    final capsuleSurface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.55),
          width: 0.5,
        ),
      ),
      child: AnimatedSwitcher(
        switchOutCurve: kAppFadeCurve,
        switchInCurve: kAppFadeCurve,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppFadeDuration,
        child: _volumeMode ? buildVolumeBar() : buildButtonsRow(),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
      child: SizedBox(
        key: const ValueKey('playback_secondary_controls'),
        width: _kPlaybackSecondaryControlsWidth,
        height: capsuleHeight,
        child: AppGlassSurface(
          enabled: glassEnabled,
          backgroundColor: glassEnabled
              ? background.withValues(alpha: background.a * 0.9)
              : background,
          borderRadius: borderRadius,
          child: capsuleSurface,
        ),
      ),
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
    this.tooltip,
    this.nudgeX = 0,
  });

  final BoxConstraints constraints;
  final bool enabled;
  final IconData icon;
  final double iconSize;
  final VoidCallback onPressed;
  final String? tooltip;
  final double nudgeX;

  @override
  State<PrimaryTransportButton> createState() => _PrimaryTransportButtonState();
}

class _PrimaryTransportButtonState extends State<PrimaryTransportButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _nudgeController;
  late Animation<double> _nudgeOffset;

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

    return Container(
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
