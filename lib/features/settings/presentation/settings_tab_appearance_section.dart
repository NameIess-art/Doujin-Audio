part of 'settings_tab.dart';

List<Widget> _buildSettingsAppearanceSection({
  required BuildContext context,
  required WidgetRef ref,
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
  required VoidCallback onShowSubtitleWindowSettings,
}) {
  final themeProvider = ref.read(themeProviderInstanceProvider);
  final coverResolutionLabels = <CoverImageResolution, String>{
    CoverImageResolution.memorySaver: i18n.tr('cover_image_resolution_300'),
    CoverImageResolution.balanced: i18n.tr('cover_image_resolution_600'),
    CoverImageResolution.high: i18n.tr('cover_image_resolution_900'),
    CoverImageResolution.ultraHigh: i18n.tr('cover_image_resolution_1200'),
    CoverImageResolution.original: i18n.tr('cover_image_resolution_original'),
  };

  return <Widget>[
    _SettingsSectionCard(
      title: i18n.tr('settings_group_theme_layout'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final themeMode = ref.watch(
              themeProviderInstanceProvider.select((t) => t.themeMode),
            );
            final modeLabels = <ThemeMode, String>{
              ThemeMode.system: i18n.tr('theme_system'),
              ThemeMode.light: i18n.tr('theme_light'),
              ThemeMode.dark: i18n.tr('theme_dark'),
            };
            return ListTile(
              title: _settingsTitle(i18n.tr('dark_mode')),
              leading: _settingsIcon(Icons.dark_mode_rounded, cs.primary),
              trailing: _settingsDropdown<ThemeMode>(
                context,
                value: themeMode,
                onChanged: (value) {
                  if (value != null) {
                    unawaited(
                      _applyThemeChange(
                        context: context,
                        i18n: i18n,
                        change: () => ref
                            .read(themeProviderInstanceProvider)
                            .setThemeMode(value),
                      ),
                    );
                  }
                },
                items: ThemeMode.values
                    .map(
                      (mode) => DropdownMenuItem<ThemeMode>(
                        value: mode,
                        child: _settingsDropdownText(modeLabels[mode]!),
                      ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        if (Theme.of(context).brightness == Brightness.dark)
          Consumer(
            builder: (context, ref, _) {
              final pureBlack = ref.watch(
                themeProviderInstanceProvider.select((t) => t.pureBlackTheme),
              );
              return SwitchListTile(
                key: const ValueKey<String>('pure_black_theme_tile'),
                title: _settingsTitle(i18n.tr('black_theme')),
                value: pureBlack,
                onChanged: (value) {
                  unawaited(
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.selection,
                    ),
                  );
                  unawaited(
                    _applyThemeChange(
                      context: context,
                      i18n: i18n,
                      change: () => themeProvider.setPureBlackTheme(value),
                    ),
                  );
                },
                secondary: _settingsIcon(Icons.contrast_rounded, cs.primary),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              );
            },
          ),
        Consumer(
          builder: (context, ref, _) {
            final barGlassEnabled = ref.watch(
              themeProviderInstanceProvider.select((t) => t.barGlassEnabled),
            );
            return SwitchListTile(
              key: const ValueKey<String>('bar_glass_enabled_tile'),
              title: _settingsTitle(i18n.tr('bar_glass_enabled')),
              value: barGlassEnabled,
              onChanged: (value) {
                unawaited(
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  ),
                );
                unawaited(
                  _applyThemeChange(
                    context: context,
                    i18n: i18n,
                    change: () => themeProvider.setBarGlassEnabled(value),
                  ),
                );
              },
              secondary: _settingsIcon(Icons.blur_on_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final selection = ref.watch(
              themeProviderInstanceProvider.select(
                (t) => (
                  t.appThemeColor,
                  t.customThemeColor,
                  t.useSystemAccentColor,
                ),
              ),
            );
            return _ThemeColorTile(
              key: const ValueKey<String>('app_theme_color_tile'),
              title: i18n.tr('app_theme_color'),
              indicatorKey: const ValueKey<String>('app_theme_color_indicator'),
              color: Theme.of(context).colorScheme.primary,
              iconColor: cs.primary,
              onTap: () {
                if (themeProvider.systemAccentColor == null) {
                  final lifecycleService = ref.read(
                    appLifecyclePlatformServiceProvider,
                  );
                  unawaited(
                    lifecycleService
                        .getSystemAccentColor()
                        .then((accent) {
                          if (!context.mounted || accent == null) return;
                          themeProvider.setSystemAccentColor(Color(accent));
                        })
                        .catchError((Object error, StackTrace stackTrace) {
                          debugPrint(
                            'Failed to load system accent color: $error\n$stackTrace',
                          );
                        }),
                  );
                }
                _showThemeColorPicker(
                  context: context,
                  i18n: i18n,
                  title: i18n.tr('app_theme_color'),
                  selected: selection.$1,
                  customColor: selection.$2,
                  useSystemAccent: selection.$3,
                  systemAccentColorListenable:
                      themeProvider.systemAccentColorListenable,
                  onSelected: themeProvider.setAppThemeColor,
                  onCustomColorSelected: themeProvider.setCustomThemeColor,
                  onSystemAccentSelected: themeProvider.setUseSystemAccentColor,
                );
              },
            );
          },
        ),
      ],
    ),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_cover_background'),
      children: [
        ListTile(
          title: _settingsTitle(i18n.tr('cover_image_resolution')),
          leading: _settingsIcon(
            Icons.photo_size_select_large_rounded,
            cs.primary,
          ),
          trailing: Consumer(
            builder: (context, ref, _) =>
                _settingsDropdown<CoverImageResolution>(
                  context,
                  value: ref.watch(coverImageResolutionProvider),
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(
                        saveSettingsWithFeedback(
                          context,
                          () =>
                              settingsController.setCoverImageResolution(value),
                        ),
                      );
                    }
                  },
                  items: CoverImageResolution.values
                      .map(
                        (value) => DropdownMenuItem<CoverImageResolution>(
                          value: value,
                          child: _settingsDropdownText(
                            coverResolutionLabels[value]!,
                          ),
                        ),
                      )
                      .toList(),
                ),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.preferEmbeddedCover ?? false,
              ),
            );
            return SwitchListTile(
              key: const ValueKey<String>('prefer_embedded_cover_switch'),
              value: enabled,
              onChanged: (value) => _saveSettingsSwitch(
                context,
                () => settingsController.setPreferEmbeddedCover(value),
              ),
              title: _settingsTitle(i18n.tr('prefer_embedded_cover')),
              secondary: _settingsIcon(Icons.audio_file_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
      ],
    ),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_playback_detail'),
      children: [
        AppSettingsActionTile(
          title: i18n.tr('subtitle_window_settings'),
          icon: Icons.subtitles_rounded,
          onTap: onShowSubtitleWindowSettings,
        ),
      ],
    ),
  ];
}

void _showThemeColorPicker({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required String title,
  required ThemeAccentPreset selected,
  required Color? customColor,
  required bool useSystemAccent,
  required ValueListenable<Color?> systemAccentColorListenable,
  required Future<bool> Function(ThemeAccentPreset value) onSelected,
  required Future<bool> Function(Color? value) onCustomColorSelected,
  required Future<bool> Function(bool value) onSystemAccentSelected,
}) {
  showAppDialog<void>(
    context: context,
    maxWidth: 388,
    builder: (dialogContext) => _ThemeColorPickerMenu(
      title: title,
      selected: selected,
      customColor: customColor,
      useSystemAccent: useSystemAccent,
      systemAccentColorListenable: systemAccentColorListenable,
      i18n: i18n,
      onSelected: (value) {
        Navigator.of(dialogContext).pop();
        unawaited(
          _applyThemeChange(
            context: context,
            i18n: i18n,
            change: () => onSelected(value),
          ),
        );
      },
      onCustomColorSelected: (value) {
        Navigator.of(dialogContext).pop();
        unawaited(
          _applyThemeChange(
            context: context,
            i18n: i18n,
            change: () => onCustomColorSelected(value),
          ),
        );
      },
      onSystemAccentSelected: () {
        Navigator.of(dialogContext).pop();
        unawaited(
          _applyThemeChange(
            context: context,
            i18n: i18n,
            change: () => onSystemAccentSelected(true),
          ),
        );
      },
    ),
  );
}

Future<void> _applyThemeChange({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required Future<bool> Function() change,
}) async {
  final updated = await change();
  if (updated || !context.mounted) return;
  showAppSnackBar(
    context,
    i18n.tr('operation_failed_retry'),
    tone: AppFeedbackTone.destructive,
    icon: Icons.error_outline_rounded,
  );
}

class _ThemeColorTile extends StatelessWidget {
  const _ThemeColorTile({
    super.key,
    required this.title,
    required this.indicatorKey,
    required this.color,
    required this.iconColor,
    required this.onTap,
  });

  final String title;
  final Key indicatorKey;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Theme(
      data: AppEntryInkWell.entryTheme(context),
      child: ListTile(
        title: _settingsTitle(title),
        leading: _settingsIcon(Icons.color_lens_rounded, iconColor),
        trailing: SizedBox.square(
          dimension: 48,
          child: Center(
            child: Container(
              key: indicatorKey,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        onTap: onTap,
      ),
    );
  }
}

class _ThemeColorPickerMenu extends StatefulWidget {
  const _ThemeColorPickerMenu({
    required this.title,
    required this.selected,
    required this.customColor,
    required this.useSystemAccent,
    required this.systemAccentColorListenable,
    required this.i18n,
    required this.onSelected,
    required this.onCustomColorSelected,
    required this.onSystemAccentSelected,
  });

  final String title;
  final ThemeAccentPreset selected;
  final Color? customColor;
  final bool useSystemAccent;
  final ValueListenable<Color?> systemAccentColorListenable;
  final AppLanguageProvider i18n;
  final ValueChanged<ThemeAccentPreset> onSelected;
  final ValueChanged<Color> onCustomColorSelected;
  final VoidCallback onSystemAccentSelected;

  @override
  State<_ThemeColorPickerMenu> createState() => _ThemeColorPickerMenuState();
}

class _ThemeColorPickerMenuState extends State<_ThemeColorPickerMenu> {
  late bool _customExpanded;
  late final ValueNotifier<HSLColor> _draftHsl;

  @override
  void initState() {
    super.initState();
    _customExpanded = widget.customColor != null && !widget.useSystemAccent;
    final initial = widget.customColor ?? widget.selected.primaryColor;
    _draftHsl = ValueNotifier<HSLColor>(HSLColor.fromColor(initial));
  }

  @override
  void dispose() {
    _draftHsl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final hasCustomActive =
        widget.customColor != null && !widget.useSystemAccent;

    return AppDialog(
      key: const ValueKey<String>('theme_color_dialog'),
      title: widget.title,
      icon: Icons.palette_outlined,
      scrollable: true,
      content: ValueListenableBuilder<Color?>(
        valueListenable: widget.systemAccentColorListenable,
        builder: (context, systemAccentColor, _) {
          final hasSystemActive =
              widget.useSystemAccent && systemAccentColor != null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GridView.builder(
                key: const ValueKey<String>('theme_color_grid'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisExtent: 56,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 4,
                ),
                itemCount: ThemeAccentPreset.values.length,
                itemBuilder: (context, index) {
                  final preset = ThemeAccentPreset.values[index];
                  final isSelected =
                      !hasCustomActive &&
                      !hasSystemActive &&
                      preset == widget.selected;
                  final label = widget.i18n.tr(preset.labelKey);
                  final highContrast =
                      tokens.highContrast || MediaQuery.highContrastOf(context);
                  final color = preset
                      .colorScheme(
                        theme.brightness,
                        pureBlack: tokens.pureBlack,
                        highContrast: highContrast,
                      )
                      .primary;
                  final foreground = appReadableOnColor(color);
                  return Semantics(
                    button: true,
                    selected: isSelected,
                    label: label,
                    child: Tooltip(
                      message: label,
                      child: AppEntryInkWell(
                        key: ValueKey<String>('theme_color_${preset.name}'),
                        customBorder: const CircleBorder(),
                        onTap: () => widget.onSelected(preset),
                        child: Center(
                          child: AnimatedContainer(
                            duration: tokens.motionFast,
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? cs.onSurface
                                    : cs.outlineVariant.withValues(alpha: 0.7),
                                width: isSelected ? 3 : 1,
                              ),
                            ),
                            child: isSelected
                                ? Icon(
                                    Icons.check_rounded,
                                    color: foreground,
                                    size: 24,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Divider(
                height: 1,
                color: cs.outlineVariant.withValues(
                  alpha: tokens.subtleBorderAlpha,
                ),
              ),
              const SizedBox(height: 8),
              if (systemAccentColor != null) ...[
                _ThemeColorOptionRow(
                  key: const ValueKey<String>('theme_color_system_option'),
                  label: widget.i18n.tr('theme_color_system'),
                  previewColor: buildAppColorScheme(
                    seedColor: systemAccentColor,
                    brightness: theme.brightness,
                    pureBlack: tokens.pureBlack,
                    highContrast:
                        tokens.highContrast ||
                        MediaQuery.highContrastOf(context),
                  ).primary,
                  selected: hasSystemActive,
                  onTap: widget.onSystemAccentSelected,
                ),
                const SizedBox(height: 4),
              ],
              ValueListenableBuilder<HSLColor>(
                valueListenable: _draftHsl,
                builder: (context, draftHsl, _) {
                  final draftColor = draftHsl.toColor();
                  final draftOnColor =
                      ThemeData.estimateBrightnessForColor(draftColor) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black;
                  final hexCode =
                      '#${(draftColor.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ThemeColorOptionRow(
                        key: const ValueKey<String>(
                          'theme_color_custom_toggle',
                        ),
                        label: widget.i18n.tr('theme_color_custom'),
                        previewColor: draftColor,
                        selected: hasCustomActive,
                        trailingIcon: _customExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        onTap: () =>
                            setState(() => _customExpanded = !_customExpanded),
                      ),
                      if (_customExpanded) ...[
                        const SizedBox(height: 8),
                        Container(
                          key: const ValueKey<String>(
                            'theme_color_custom_editor',
                          ),
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainer,
                            borderRadius: BorderRadius.circular(
                              tokens.radiusCard,
                            ),
                            border: Border.all(
                              color: cs.outlineVariant.withValues(
                                alpha: tokens.subtleBorderAlpha,
                              ),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: draftColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: cs.outlineVariant.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    hexCode,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: cs.onSurface,
                                    ),
                                  ),
                                  const Spacer(),
                                  FilledButton(
                                    key: const ValueKey<String>(
                                      'theme_color_custom_apply',
                                    ),
                                    onPressed: () => widget
                                        .onCustomColorSelected(draftColor),
                                    style: appSurfaceButtonStyle(
                                      style: FilledButton.styleFrom(
                                        minimumSize: const Size(72, 36),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                        ),
                                        backgroundColor: draftColor,
                                        foregroundColor: draftOnColor,
                                      ),
                                      colorScheme: cs,
                                      platform: theme.platform,
                                      defaultBackgroundColor: draftColor,
                                      animationDuration:
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                          ? Duration.zero
                                          : const Duration(milliseconds: 130),
                                    ),
                                    child: Text(widget.i18n.tr('confirm')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              _HslColorSliderRow(
                                label: widget.i18n.tr('theme_color_hue'),
                                value: draftHsl.hue,
                                min: 0,
                                max: 360,
                                activeColor: draftColor,
                                onChanged: (hue) =>
                                    _draftHsl.value = draftHsl.withHue(hue),
                              ),
                              _HslColorSliderRow(
                                label: widget.i18n.tr('theme_color_saturation'),
                                value: draftHsl.saturation,
                                min: 0.1,
                                max: 1.0,
                                activeColor: draftColor,
                                onChanged: (sat) => _draftHsl.value = draftHsl
                                    .withSaturation(sat),
                              ),
                              _HslColorSliderRow(
                                label: widget.i18n.tr('theme_color_lightness'),
                                value: draftHsl.lightness,
                                min: 0.25,
                                max: 0.85,
                                activeColor: draftColor,
                                onChanged: (light) => _draftHsl.value = draftHsl
                                    .withLightness(light),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ThemeColorOptionRow extends StatelessWidget {
  const _ThemeColorOptionRow({
    super.key,
    required this.label,
    required this.previewColor,
    required this.selected,
    required this.onTap,
    this.trailingIcon,
  });

  final String label;
  final Color previewColor;
  final bool selected;
  final VoidCallback onTap;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final rowRadius = BorderRadius.circular(tokens.radiusControl);
    return Material(
      color: Colors.transparent,
      borderRadius: rowRadius,
      clipBehavior: Clip.antiAlias,
      child: AppEntryInkWell(
        borderRadius: rowRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: previewColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? cs.onSurface
                        : cs.outlineVariant.withValues(alpha: 0.7),
                    width: selected ? 2.2 : 1,
                  ),
                ),
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: appReadableOnColor(previewColor),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (trailingIcon != null)
                Icon(trailingIcon, size: 20, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _HslColorSliderRow extends StatelessWidget {
  const _HslColorSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.activeColor,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final Color activeColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: activeColor,
                thumbColor: activeColor,
              ),
              child: Slider(
                min: min,
                max: max,
                value: value.clamp(min, max),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
