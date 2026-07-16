part of 'playlist_tab.dart';

class _AudioFeaturesPage extends ConsumerWidget {
  const _AudioFeaturesPage({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sessionDetailTransportProvider(session.id));
    final effects = detail?.audioEffects ?? session.audioEffects;
    final channelSwapEnabled =
        detail?.channelSwapEnabled ?? session.channelSwapEnabled;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return ListView(
      padding: const EdgeInsets.only(top: 6),
      children: [
        _FeatureSwitchTile(
          title: i18n.tr('skip_silence'),
          subtitle: i18n.tr('skip_silence_desc'),
          icon: Icons.fast_forward_rounded,
          value: effects.skipSilenceEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(
              provider.playbackFacade.setSessionSkipSilence(session.id, value),
            );
          },
        ),
        const SizedBox(height: 10),
        _FeatureSwitchTile(
          title: i18n.tr('noise_reduction'),
          subtitle: i18n.tr('noise_reduction_desc'),
          icon: Icons.graphic_eq_rounded,
          value: effects.noiseReductionEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(
              provider.playbackFacade.setSessionNoiseReduction(
                session.id,
                value,
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        _FeatureSwitchTile(
          title: i18n.tr('volume_normalization'),
          subtitle: i18n.tr('volume_normalization_desc'),
          icon: Icons.compress_rounded,
          value: effects.volumeNormalizationEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(
              provider.playbackFacade.setSessionVolumeNormalization(
                session.id,
                value,
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        _FeatureSwitchTile(
          title: i18n.tr('channel_swap'),
          subtitle: i18n.tr('channel_swap_desc'),
          icon: Icons.swap_horiz_rounded,
          value: channelSwapEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(
              provider.playbackFacade.setSessionChannelSwap(session.id, value),
            );
          },
        ),
      ],
    );
  }
}

class _FeatureSwitchTile extends StatelessWidget {
  const _FeatureSwitchTile({
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        value: value,
        onChanged: onChanged,
        secondary: Icon(
          icon,
          color: value ? cs.primary : cs.onSurfaceVariant,
          size: 22,
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeBalancePage extends ConsumerWidget {
  const _VolumeBalancePage({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sessionDetailTransportProvider(session.id));
    final panning =
        detail?.audioEffects.panning ?? session.audioEffects.panning;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  Icons.headphones_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
                Icon(
                  Icons.headphones_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'L',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: panning,
                    min: -1.0,
                    divisions: 20,
                    label: panning == 0 ? '0' : panning.toStringAsFixed(1),
                    onChanged: (value) {
                      AppInteractionFeedback.continuous((value * 10).round());
                      UiInteractionCoordinator.instance.scheduleThrottledCommit(
                        key: 'session_panning:${session.id}',
                        commit: () => unawaited(
                          provider.playbackFacade.setSessionPanning(
                            session.id,
                            value,
                          ),
                        ),
                      );
                    },
                    onChangeEnd: (value) {
                      AppInteractionFeedback.resetContinuous();
                      UiInteractionCoordinator.instance.cancelThrottledCommit(
                        'session_panning:${session.id}',
                      );
                      unawaited(
                        provider.playbackFacade.setSessionPanning(
                          session.id,
                          value.abs() < 0.1 ? 0.0 : value,
                        ),
                      );
                    },
                  ),
                ),
                Text(
                  'R',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: FilledButton.tonal(
                key: const ValueKey<String>('restore_volume_balance'),
                style: _sessionDetailResetButtonStyle,
                onPressed: panning.abs() < 0.001
                    ? null
                    : () {
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.selection,
                        );
                        UiInteractionCoordinator.instance.cancelThrottledCommit(
                          'session_panning:${session.id}',
                        );
                        unawaited(
                          provider.playbackFacade.setSessionPanning(
                            session.id,
                            0.0,
                          ),
                        );
                      },
                child: Text(i18n.tr('restore_default')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerPage extends ConsumerWidget {
  const _EqualizerPage({required this.session, required this.provider});

  final PlaybackSession session;
  final AudioProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sessionDetailTransportProvider(session.id));
    final effects = detail?.audioEffects ?? session.audioEffects;
    final eqCapabilities = detail?.eqCapabilities ?? session.eqCapabilities;

    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final presets = [
      ...AudioProvider.builtInEqPresets,
      ...provider.customEqPresets,
    ];
    final selectedPresetId = effects.eqPresetId;
    final hasAdjustedEqBands = effects.eqBandLevels.values.any(
      (gainDb) => gainDb.abs() >= 0.001,
    );

    return ListView(
      padding: const EdgeInsets.only(top: 2),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            i18n.tr('equalizer'),
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(
            eqCapabilities.supported
                ? i18n.tr('equalizer_supported')
                : i18n.tr('equalizer_enable_hint'),
          ),
          value: effects.eqEnabled,
          onChanged: (value) {
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            unawaited(
              provider.playbackFacade.setSessionEqEnabled(session.id, value),
            );
          },
        ),
        UnifiedDropdownButtonFormField<String>(
          initialValue: selectedPresetId,
          alignment: AlignmentDirectional.centerStart,
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
            unawaited(
              provider.playbackFacade.applySessionEqPreset(session.id, preset),
            );
          },
        ),
        const SizedBox(height: 12),
        if (!eqCapabilities.supported)
          Text(
            i18n.tr('equalizer_unavailable'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          )
        else
          ...eqCapabilities.bands.map((band) {
            final value = effects.eqBandLevels[band.frequencyHz] ?? 0.0;
            return _EqBandSlider(
              label: _formatFrequency(band.frequencyHz),
              value: value.clamp(
                eqCapabilities.minGainDb,
                eqCapabilities.maxGainDb,
              ),
              min: eqCapabilities.minGainDb,
              max: eqCapabilities.maxGainDb,
              onChanged: effects.eqEnabled
                  ? (nextValue) {
                      AppInteractionFeedback.continuous(
                        '${band.frequencyHz}:${(nextValue * 2).round()}',
                      );
                      UiInteractionCoordinator.instance.scheduleThrottledCommit(
                        key: 'session_eq:${session.id}:${band.frequencyHz}',
                        commit: () => unawaited(
                          provider.playbackFacade.setSessionEqBandLevel(
                            session.id,
                            band.frequencyHz,
                            nextValue,
                          ),
                        ),
                      );
                    }
                  : null,
              onChangeEnd: (value) {
                AppInteractionFeedback.resetContinuous();
                UiInteractionCoordinator.instance.cancelThrottledCommit(
                  'session_eq:${session.id}:${band.frequencyHz}',
                );
                unawaited(
                  provider.playbackFacade.setSessionEqBandLevel(
                    session.id,
                    band.frequencyHz,
                    value,
                  ),
                );
              },
            );
          }),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Center(
                child: FilledButton.tonal(
                  key: const ValueKey<String>('reset_equalizer'),
                  style: _sessionDetailResetButtonStyle,
                  onPressed: hasAdjustedEqBands
                      ? () {
                          final flat = AudioProvider.builtInEqPresets.first;
                          unawaited(
                            provider.playbackFacade.applySessionEqPreset(
                              session.id,
                              flat,
                            ),
                          );
                        }
                      : null,
                  child: Text(i18n.tr('eq_reset')),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Center(
                child: FilledButton.tonal(
                  key: const ValueKey<String>('save_equalizer_preset'),
                  style: _sessionDetailResetButtonStyle,
                  onPressed: hasAdjustedEqBands
                      ? () => _showSavePresetDialog(
                          context,
                          provider: provider,
                          session: session,
                        )
                      : null,
                  child: Text(i18n.tr('eq_save_preset')),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showSavePresetDialog(
    BuildContext context, {
    required AudioProvider provider,
    required PlaybackSession session,
  }) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(i18n.tr('eq_save_preset')),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: i18n.tr('eq_preset_name')),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      MaterialLocalizations.of(context).cancelButtonLabel,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(controller.text),
                    child: Text(
                      MaterialLocalizations.of(context).okButtonLabel,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    unawaited(provider.saveCustomEqPreset(name, session));
  }
}

class _EqBandSlider extends StatelessWidget {
  const _EqBandSlider({
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
  Widget build(BuildContext context) {
    final divisions = ((max - min) * 2).round().clamp(1, 80).toInt();
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: '${value.toStringAsFixed(1)} dB',
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            '${value.toStringAsFixed(1)} dB',
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
