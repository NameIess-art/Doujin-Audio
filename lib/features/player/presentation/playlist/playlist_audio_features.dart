import '../../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/localization/app_language_provider.dart';
import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/ui/undoable_removal_service.dart';
import '../../../../core/widgets/app_edit_panel.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/unified_dropdown.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../../settings/application/settings_command_controller.dart';
import '../../application/playback_facade.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/audio_effects.dart';
import 'playlist_shared_helpers.dart';

Future<void> _stageEqualizerPresetRemoval(
  BuildContext context,
  WidgetRef ref,
  EqPreset preset,
) async {
  final commands = ref.read(settingsCommandControllerProvider);
  final service = ref.read(undoableRemovalServiceProvider);
  final staged = await service.stage(
    UndoableRemovalAction(
      key: equalizerPresetRemovalKey(preset.id),
      prepare: () => ref
          .read(settingsRepositoryProvider)
          .customEqPresets
          .any((value) => value.id == preset.id),
      undo: () {},
      commit: () => commands.deleteCustomEqPreset(preset.id),
    ),
  );
  if (staged && context.mounted) {
    showPlaybackRemovalFeedback(context, service, icon: Icons.equalizer_rounded);
  } else if (staged) {
    await service.commitPending();
  }
}

class AudioFeaturesPage extends ConsumerWidget {
  const AudioFeaturesPage({
    super.key,
    required this.session,
    required this.playback,
    required this.topInset,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final detail = ref.watch(
      sessionDetailTransportProvider(
        session.id,
      ).select((state) => (state?.audioEffects, state?.channelSwapEnabled)),
    );
    final effects = detail.$1 ?? session.audioEffects;
    final channelSwapEnabled = detail.$2 ?? session.channelSwapEnabled;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return ListView(
      padding: EdgeInsets.only(top: topInset + 6),
      children: [
        FeatureSwitchTile(
          title: i18n.tr('skip_silence'),
          subtitle: i18n.tr('skip_silence_desc'),
          icon: Icons.keyboard_double_arrow_right_rounded,
          value: effects.skipSilenceEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(playback.setSessionSkipSilence(session.id, value));
          },
        ),
        const SizedBox(height: 10),
        FeatureSwitchTile(
          title: i18n.tr('noise_reduction'),
          subtitle: i18n.tr('noise_reduction_desc'),
          icon: Icons.noise_control_off_rounded,
          value: effects.noiseReductionEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(playback.setSessionNoiseReduction(session.id, value));
          },
        ),
        const SizedBox(height: 10),
        FeatureSwitchTile(
          title: i18n.tr('volume_normalization'),
          subtitle: i18n.tr('volume_normalization_desc'),
          icon: Icons.compress_rounded,
          value: effects.volumeNormalizationEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(
              playback.setSessionVolumeNormalization(session.id, value),
            );
          },
        ),
        const SizedBox(height: 10),
        FeatureSwitchTile(
          title: i18n.tr('channel_swap'),
          subtitle: i18n.tr('channel_swap_desc'),
          icon: Icons.swap_horiz_rounded,
          value: channelSwapEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(playback.setSessionChannelSwap(session.id, value));
          },
        ),
      ],
    ).withWindowsSmoothScroll();
  }
}

class FeatureSwitchTile extends StatelessWidget {
  const FeatureSwitchTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 66,
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: value ? cs.primary : cs.onSurfaceVariant,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class VolumeBalancePage extends ConsumerStatefulWidget {
  const VolumeBalancePage({
    super.key,
    required this.session,
    required this.playback,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;

  @override
  ConsumerState<VolumeBalancePage> createState() => _VolumeBalancePageState();
}

class _VolumeBalancePageState extends ConsumerState<VolumeBalancePage> {
  static const _thumbSize = 24.0;
  static final _directions = {
    LogicalKeyboardKey.arrowLeft: const Offset(-0.1, 0),
    LogicalKeyboardKey.arrowRight: const Offset(0.1, 0),
    LogicalKeyboardKey.arrowUp: const Offset(0, 0.1),
    LogicalKeyboardKey.arrowDown: const Offset(0, -0.1),
  };

  final _padFocus = FocusNode();
  Offset? _dragPosition;
  int? _activePointer;

  @override
  void dispose() {
    _padFocus.dispose();
    super.dispose();
  }

  double _step(double value) => (value.clamp(-1, 1) * 10).round() / 10;

  Offset _quantize(Offset position) =>
      Offset(_step(position.dx), _step(position.dy));

  Offset _takeStep(Offset position, Offset change) => Offset(
    change.dx == 0 ? position.dx : _step(position.dx + change.dx),
    change.dy == 0 ? position.dy : _step(position.dy + change.dy),
  );

  void _commit(Offset position) {
    unawaited(
      widget.playback.setSessionSoundField(
        widget.session.id,
        panning: position.dx,
        frontBack: position.dy,
      ),
    );
  }

  void _cancelDrag() {
    _activePointer = null;
    if (_dragPosition == null) return;
    AppInteractionFeedback.resetContinuous();
    setState(() => _dragPosition = null);
  }

  Widget _buildPad({
    required Offset current,
    required String label,
    required String value,
  }) {
    final colors = Theme.of(context).colorScheme;
    final axisColor = colors.outlineVariant;
    final position = _dragPosition ?? current;
    return Focus(
      focusNode: _padFocus,
      onFocusChange: (_) => setState(() {}),
      onKeyEvent: (_, event) {
        final change = _directions[event.logicalKey];
        if (change == null) return KeyEventResult.ignored;
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final next = _takeStep(current, change);
          if (next != current && _dragPosition == null) _commit(next);
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: label,
        value: value,
        child: LayoutBuilder(
          builder: (context, constraints) {
            Offset positionAt(Offset local) {
              final width = constraints.maxWidth - _thumbSize;
              final height = constraints.maxHeight - _thumbSize;
              return _quantize(
                Offset(
                  width > 0 ? (2 * local.dx - constraints.maxWidth) / width : 0,
                  (constraints.maxHeight - 2 * local.dy) / height,
                ),
              );
            }

            void preview(Offset local) {
              final next = positionAt(local);
              if (_dragPosition == next) return;
              AppInteractionFeedback.continuous(next);
              setState(() => _dragPosition = next);
            }

            return MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: RawGestureDetector(
                key: const ValueKey('sound_field_pad'),
                excludeFromSemantics: true,
                // Reserve drags that start here before the vertical scroll view
                // applies its smaller drag threshold.
                gestures: {
                  EagerGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        EagerGestureRecognizer
                      >(
                        () => EagerGestureRecognizer(
                          allowedButtonsFilter: (buttons) =>
                              buttons == kPrimaryButton,
                        ),
                        (_) {},
                      ),
                },
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (_activePointer != null ||
                        event.buttons != kPrimaryButton) {
                      return;
                    }
                    _activePointer = event.pointer;
                    _padFocus.requestFocus();
                    preview(event.localPosition);
                  },
                  onPointerMove: (event) {
                    if (_activePointer == event.pointer) {
                      preview(event.localPosition);
                    }
                  },
                  onPointerUp: (event) {
                    if (_activePointer != event.pointer) return;
                    final target = positionAt(event.localPosition);
                    _cancelDrag();
                    if (target != current) _commit(target);
                  },
                  onPointerCancel: (event) {
                    if (_activePointer == event.pointer) _cancelDrag();
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _padFocus.hasFocus ? colors.primary : axisColor,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: Divider(
                            height: 1,
                            thickness: 1,
                            color: axisColor,
                          ),
                        ),
                        Center(
                          child: VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: axisColor,
                          ),
                        ),
                        Align(
                          alignment: Alignment(position.dx, -position.dy),
                          child: SizedBox.square(
                            dimension: _thumbSize,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.primary,
                                border: Border.all(
                                  color: colors.onPrimary,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final session = widget.session;
    final (panning, frontBack) = ref.watch(
      sessionDetailTransportProvider(session.id).select((state) {
        final effects = state?.audioEffects ?? session.audioEffects;
        return (effects.panning, effects.frontBack);
      }),
    );
    final current = Offset(panning, frontBack);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final left = i18n.tr('sound_field_left');
    final right = i18n.tr('sound_field_right');
    final front = i18n.tr('sound_field_front');
    final rear = i18n.tr('sound_field_rear');
    final preview = _dragPosition ?? current;
    final semanticValue = [
      if (preview.dx != 0)
        '${preview.dx < 0 ? left : right} ${(preview.dx.abs() * 100).round()}%',
      if (preview.dy != 0)
        '${preview.dy < 0 ? rear : front} ${(preview.dy.abs() * 100).round()}%',
    ];
    const buttonHeight = 48.0;

    Widget direction(String label, LogicalKeyboardKey key, {String? glyph}) {
      final next = _takeStep(current, _directions[key]!);
      return TextButton(
        onPressed: next == current
            ? null
            : () {
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.selection,
                );
                _commit(next);
              },
        style: TextButton.styleFrom(
          minimumSize: const Size(buttonHeight, buttonHeight),
        ),
        child: Text(glyph ?? label, semanticsLabel: label),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SizedBox(
          height: constraints.maxHeight.clamp(200.0, double.infinity),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(child: direction(front, LogicalKeyboardKey.arrowUp)),
              Expanded(
                child: Row(
                  children: [
                    direction(left, LogicalKeyboardKey.arrowLeft, glyph: 'L'),
                    Expanded(
                      child: _buildPad(
                        current: current,
                        label: i18n.tr('volume_balance'),
                        value: semanticValue.isEmpty
                            ? i18n.tr('sound_field_centered')
                            : semanticValue.join(', '),
                      ),
                    ),
                    direction(right, LogicalKeyboardKey.arrowRight, glyph: 'R'),
                  ],
                ),
              ),
              Center(child: direction(rear, LogicalKeyboardKey.arrowDown)),
              const SizedBox(height: 8),
              FilledButton.tonal(
                key: const ValueKey<String>('restore_volume_balance'),
                style: sessionDetailResetButtonStyle(context),
                onPressed: current == Offset.zero
                    ? null
                    : () {
                        _cancelDrag();
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.selection,
                        );
                        _commit(Offset.zero);
                      },
                child: Text(i18n.tr('restore_default')),
              ),
            ],
          ),
        ),
      ).withWindowsSmoothScroll(),
    );
  }
}

class EqualizerPage extends ConsumerWidget {
  const EqualizerPage({
    super.key,
    required this.session,
    required this.playback,
    required this.topInset,
  });

  final PlaybackSessionSnapshot session;
  final PlaybackFacade playback;
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final header = ref.watch(
      sessionDetailTransportProvider(session.id).select(
        (state) => (
          state?.audioEffects.eqEnabled,
          state?.audioEffects.eqPresetId,
          state?.eqCapabilities,
          Object.hashAll(
            (state?.audioEffects.eqBandLevels ?? session.audioEffects.eqBandLevels)
                .keys
                .where((freq) => !eqBandFrequencies.contains(freq)),
          ),
        ),
      ),
    );
    final eqEnabled = header.$1 ?? session.audioEffects.eqEnabled;
    final eqPresetValue = header.$2;
    final eqCapabilities = header.$3 ?? session.eqCapabilities;
    final initialEffects = ref
        .read(sessionDetailTransportProvider(session.id))
        ?.audioEffects ??
        session.audioEffects;
    // Keep the editor's frequencies stable before and after native preparation.
    // Android maps these gains to its supported bands when applying the effects.
    final frequencies = {
      ...eqBandFrequencies,
      ...initialEffects.eqBandLevels.keys,
    }.toList()..sort();

    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final removalState = ref.watch(undoableRemovalStateProvider);
    final customPresets =
        (ref.watch(
                  settingsStateProvider.select((s) => s.value?.customEqPresets),
                ) ??
                ref.read(settingsRepositoryProvider).customEqPresets)
            .where(
              (preset) =>
                  !removalState.isHidden(equalizerPresetRemovalKey(preset.id)),
            )
            .toList(growable: false);
    final presets = <EqPreset>[...builtInEqPresets, ...customPresets];
    final selectedPresetId =
        presets.any((preset) => preset.id == eqPresetValue)
        ? eqPresetValue
        : null;

    final isCustomPresetSelected = customPresets.any(
      (preset) => preset.id == selectedPresetId,
    );

    return ListView(
      padding: EdgeInsets.only(top: topInset + 2),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            i18n.tr('equalizer'),
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          value: eqEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(playback.setSessionEqEnabled(session.id, value));
          },
        ),
        UnifiedDropdownButtonFormField<String>(
          initialValue: selectedPresetId,
          expandWidth: true,
          decoration: InputDecoration(
            labelText: i18n.tr('eq_preset'),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          items: presets
              .map(
                (preset) => DropdownMenuItem<String>(
                  value: preset.id,
                  child: Text(_presetLabel(i18n, preset)),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            final preset = presets
                .where((item) => item.id == value)
                .firstOrNull;
            if (preset == null) return;
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(playback.applySessionEqPreset(session.id, preset));
          },
        ),
        const SizedBox(height: 12),
        ...frequencies.map(
          (frequencyHz) => Consumer(
            builder: (context, ref, _) {
              final value =
                  ref.watch(
                    sessionDetailTransportProvider(session.id).select(
                      (state) => state?.audioEffects.eqBandLevels[frequencyHz],
                    ),
                  ) ??
                  session.audioEffects.eqBandLevels[frequencyHz] ??
                  0.0;
              return EqBandSlider(
                label: _formatFrequency(frequencyHz),
                value: value.clamp(
                  eqCapabilities.minGainDb,
                  eqCapabilities.maxGainDb,
                ),
                min: eqCapabilities.minGainDb,
                max: eqCapabilities.maxGainDb,
                onChanged: eqEnabled
                    ? (nextValue) {
                        AppInteractionFeedback.continuous(
                          '$frequencyHz:${(nextValue * 2).round()}',
                        );
                        UiInteractionCoordinator.instance
                            .scheduleThrottledCommit(
                              key: 'session_eq:${session.id}:$frequencyHz',
                              commit: () => unawaited(
                                playback.setSessionEqBandLevel(
                                  session.id,
                                  frequencyHz,
                                  nextValue,
                                ),
                              ),
                            );
                      }
                    : null,
                onChangeEnd: (value) {
                  AppInteractionFeedback.resetContinuous();
                  UiInteractionCoordinator.instance.cancelThrottledCommit(
                    'session_eq:${session.id}:$frequencyHz',
                  );
                  unawaited(
                    playback.setSessionEqBandLevel(
                      session.id,
                      frequencyHz,
                      value,
                    ),
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Consumer(
          builder: (context, ref, _) {
            final hasAdjustedEqBands = ref.watch(
              sessionDetailTransportProvider(session.id).select((state) {
                final bandLevels =
                    state?.audioEffects.eqBandLevels ??
                    session.audioEffects.eqBandLevels;
                return bandLevels.values.any((gainDb) => gainDb.abs() >= 0.001);
              }),
            );
            return Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    key: const ValueKey<String>('reset_equalizer'),
                    style: sessionDetailResetButtonStyle(context),
                    onPressed: hasAdjustedEqBands
                        ? () {
                            final flat = builtInEqPresets.first;
                            unawaited(
                              playback.applySessionEqPreset(session.id, flat),
                            );
                          }
                        : null,
                    child: Text(i18n.tr('eq_reset')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonal(
                    key: ValueKey<String>(
                      isCustomPresetSelected
                          ? 'delete_equalizer_preset'
                          : 'save_equalizer_preset',
                    ),
                    style: sessionDetailResetButtonStyle(context),
                    onPressed: isCustomPresetSelected && selectedPresetId != null
                        ? () {
                            final selectedPreset = customPresets
                                .where((preset) => preset.id == selectedPresetId)
                                .firstOrNull;
                            if (selectedPreset != null) {
                              unawaited(
                                _stageEqualizerPresetRemoval(
                                  context,
                                  ref,
                                  selectedPreset,
                                ),
                              );
                            }
                          }
                        : (hasAdjustedEqBands
                              ? () => _showSavePresetDialog(
                                  context,
                                  commands: ref.read(
                                    settingsCommandControllerProvider,
                                  ),
                                  session: session,
                                )
                              : null),
                    child: Text(
                      i18n.tr(
                        isCustomPresetSelected
                            ? 'eq_delete_preset'
                            : 'eq_save_preset',
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    ).withWindowsSmoothScroll();
  }

  Future<void> _showSavePresetDialog(
    BuildContext context, {
    required SettingsCommandController commands,
    required PlaybackSessionSnapshot session,
  }) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final strings = MaterialLocalizations.of(context);
    final name = await showAppTextInputPanel<String>(
      context: context,
      header: AppEditPanelHeader(
        title: i18n.tr('eq_save_preset'),
        icon: Icons.equalizer_rounded,
      ),
      initialValue: '',
      decoration: InputDecoration(labelText: i18n.tr('eq_preset_name')),
      cancelLabel: strings.cancelButtonLabel,
      submitLabel: strings.okButtonLabel,
      parse: (value) => value.trim(),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    unawaited(
      saveSettingsWithFeedback(
        context,
        () => commands.saveCustomEqPreset(name, session.id),
      ),
    );
  }
}

class EqBandSlider extends StatefulWidget {
  const EqBandSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<EqBandSlider> createState() => _EqBandSliderState();
}

class _EqBandSliderState extends State<EqBandSlider> {
  double? _dragValue;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant EqBandSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging &&
        (oldWidget.value != widget.value || widget.onChanged == null)) {
      _dragValue = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeValue = (_dragValue ?? widget.value).clamp(
      widget.min,
      widget.max,
    );
    final divisions = ((widget.max - widget.min) * 2)
        .round()
        .clamp(1, 80)
        .toInt();
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            widget.label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Slider(
            value: activeValue,
            min: widget.min,
            max: widget.max,
            divisions: divisions,
            label: '${activeValue.toStringAsFixed(1)} dB',
            onChangeStart: widget.onChanged == null
                ? null
                : (_) => _dragging = true,
            onChanged: widget.onChanged == null
                ? null
                : (nextValue) {
                    setState(() => _dragValue = nextValue);
                    widget.onChanged!(nextValue);
                  },
            onChangeEnd: widget.onChanged == null
                ? null
                : (nextValue) {
                    _dragging = false;
                    setState(() => _dragValue = nextValue);
                    widget.onChangeEnd?.call(nextValue);
                  },
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            '${activeValue.toStringAsFixed(1)} dB',
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

String _formatFrequency(int frequencyHz) {
  if (frequencyHz >= 1000) {
    final khz = frequencyHz / 1000;
    return '${khz.toStringAsFixed(khz >= 10 ? 0 : 1)}k';
  }
  return '${frequencyHz}Hz';
}

String _presetLabel(AppLanguageProvider i18n, EqPreset preset) {
  return preset.isCustom ? preset.labelKey : i18n.tr(preset.labelKey);
}
