part of 'settings_tab.dart';

List<Widget> _buildSettingsAppearanceSection({
  required BuildContext context,
  required AppLanguageProvider i18n,
  required SettingsRepository settings,
  required SettingsCommandController settingsController,
  required ColorScheme cs,
  required VoidCallback onShowSubtitleWindowSettings,
  required VoidCallback onShowCardInfoFieldsSettings,
}) {
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
            final themeMode =
                ref.watch(themeStateProvider).value?.themeMode ??
                ref.read(themeProviderInstanceProvider).themeMode;
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
                    ref.read(themeProviderInstanceProvider).setThemeMode(value);
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
        Consumer(
          builder: (context, ref, _) {
            final themeState =
                ref.watch(themeStateProvider).value ??
                ThemeState.from(ref.read(themeProviderInstanceProvider));
            final provider = ref.read(themeProviderInstanceProvider);
            return SwitchListTile(
              title: _settingsTitle(i18n.tr('differentiate_asmr_theme')),
              value: themeState.differentiateAsmrTheme,
              onChanged: provider.setDifferentiateAsmrTheme,
              secondary: _settingsIcon(Icons.palette_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final themeState =
                ref.watch(themeStateProvider).value ??
                ThemeState.from(ref.read(themeProviderInstanceProvider));
            final provider = ref.read(themeProviderInstanceProvider);
            return _ThemeColorTile(
              key: const ValueKey<String>('app_theme_color_tile'),
              title: i18n.tr('app_theme_color'),
              color: themeState.appThemeColor.color,
              iconColor: cs.primary,
              onTap: () => _showThemeColorPicker(
                context: context,
                i18n: i18n,
                title: i18n.tr('app_theme_color'),
                selected: themeState.appThemeColor,
                onSelected: provider.setAppThemeColor,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final themeState =
                ref.watch(themeStateProvider).value ??
                ThemeState.from(ref.read(themeProviderInstanceProvider));
            if (!themeState.differentiateAsmrTheme) {
              return const SizedBox.shrink();
            }
            final provider = ref.read(themeProviderInstanceProvider);
            return _ThemeColorTile(
              key: const ValueKey<String>('asmr_theme_color_tile'),
              title: i18n.tr('asmr_theme_color'),
              color: themeState.asmrThemeColor.color,
              iconColor: cs.primary,
              onTap: () => _showThemeColorPicker(
                context: context,
                i18n: i18n,
                title: i18n.tr('asmr_theme_color'),
                selected: themeState.asmrThemeColor,
                onSelected: provider.setAsmrThemeColor,
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final style = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.bottomNavigationStyle ??
                    BottomNavigationStyle.capsule,
              ),
            );
            return SwitchListTile(
              value: style == BottomNavigationStyle.capsule,
              onChanged: (value) {
                settings.setBottomNavigationStyle(
                  value
                      ? BottomNavigationStyle.capsule
                      : BottomNavigationStyle.bar,
                );
              },
              title: _settingsTitle(i18n.tr('bottom_navigation_style')),
              secondary: _settingsIcon(Icons.space_bar_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                      settingsController.setCoverImageResolution(value);
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
                (state) => state.value?.uiBlurEffectEnabled ?? true,
              ),
            );
            return SwitchListTile(
              value: enabled,
              onChanged: settings.setUiBlurEffectEnabled,
              title: _settingsTitle(i18n.tr('ui_blur_effect')),
              secondary: _settingsIcon(Icons.blur_linear_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.blurPlayerBackgroundEnabled ?? true,
              ),
            );
            return SwitchListTile(
              value: enabled,
              onChanged: settings.setBlurPlayerBackgroundEnabled,
              title: _settingsTitle(i18n.tr('blur_player_background')),
              secondary: _settingsIcon(Icons.blur_on_rounded, cs.primary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
      ],
    ),
    _SettingsSectionCard(
      title: i18n.tr('settings_group_playback_detail'),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final style = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.playbackDetailSubtitleStyle ??
                    PlaybackDetailSubtitleStyle.compact,
              ),
            );
            final styleLabels = <PlaybackDetailSubtitleStyle, String>{
              PlaybackDetailSubtitleStyle.compact: i18n.tr(
                'playback_detail_subtitle_style_compact',
              ),
              PlaybackDetailSubtitleStyle.timeline: i18n.tr(
                'playback_detail_subtitle_style_timeline',
              ),
            };
            return ListTile(
              title: _settingsTitle(i18n.tr('playback_detail_subtitle_style')),
              leading: _settingsIcon(Icons.lyrics_rounded, cs.primary),
              trailing: _settingsDropdown<PlaybackDetailSubtitleStyle>(
                context,
                value: style,
                onChanged: (value) {
                  if (value != null) {
                    settings.setPlaybackDetailSubtitleStyle(value);
                  }
                },
                items: PlaybackDetailSubtitleStyle.values
                    .map(
                      (value) => DropdownMenuItem<PlaybackDetailSubtitleStyle>(
                        value: value,
                        child: _settingsDropdownText(styleLabels[value]!),
                      ),
                    )
                    .toList(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(
              settingsStateProvider.select(
                (state) => state.value?.showPlaybackCard ?? true,
              ),
            );
            return SwitchListTile(
              value: enabled,
              onChanged: settings.setShowPlaybackCard,
              title: _settingsTitle(i18n.tr('show_playback_card')),
              secondary: _settingsIcon(
                Icons.play_circle_outline_rounded,
                cs.primary,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final fields = ref.watch(
              settingsStateProvider.select(
                (state) =>
                    state.value?.cardInfoFields ?? CardInfoField.defaults,
              ),
            );
            final summary = fields.isEmpty
                ? i18n.tr('card_info_none')
                : fields
                      .map((field) => _cardInfoFieldLabel(i18n, field))
                      .join('\uFF0C');
            return ListTile(
              title: _settingsTitle(i18n.tr('card_info_display')),
              subtitle: Text(summary, softWrap: true),
              leading: _settingsIcon(Icons.badge_rounded, cs.primary),
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              onTap: onShowCardInfoFieldsSettings,
            );
          },
        ),
        ListTile(
          title: _settingsTitle(i18n.tr('subtitle_window_settings')),
          leading: _settingsIcon(Icons.subtitles_rounded, cs.primary),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
  required Future<void> Function(ThemeAccentPreset value) onSelected,
}) {
  AppBottomSheet.show<void>(
    context: context,
    builder: (sheetContext) => _ThemeColorPickerSheet(
      title: title,
      selected: selected,
      i18n: i18n,
      onSelected: (value) {
        onSelected(value);
        Navigator.of(sheetContext).pop();
      },
    ),
  );
}

class _ThemeColorTile extends StatelessWidget {
  const _ThemeColorTile({
    super.key,
    required this.title,
    required this.color,
    required this.iconColor,
    required this.onTap,
  });

  final String title;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      title: _settingsTitle(title),
      leading: _settingsIcon(Icons.color_lens_rounded, iconColor),
      trailing: SizedBox.square(
        dimension: 48,
        child: Center(
          child: Container(
            key: ValueKey<String>('theme_color_indicator_$title'),
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
    );
  }
}

class _ThemeColorPickerSheet extends StatelessWidget {
  const _ThemeColorPickerSheet({
    required this.title,
    required this.selected,
    required this.i18n,
    required this.onSelected,
  });

  final String title;
  final ThemeAccentPreset selected;
  final AppLanguageProvider i18n;
  final ValueChanged<ThemeAccentPreset> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spaceLg,
              tokens.spaceXs,
              tokens.spaceLg,
              tokens.spaceXl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: tokens.spaceLg),
                GridView.builder(
                  key: const ValueKey<String>('theme_color_grid'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisExtent: 64,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: ThemeAccentPreset.values.length,
                  itemBuilder: (context, index) {
                    final preset = ThemeAccentPreset.values[index];
                    final isSelected = preset == selected;
                    final label = i18n.tr(preset.labelKey);
                    final foreground =
                        ThemeData.estimateBrightnessForColor(preset.color) ==
                            Brightness.dark
                        ? Colors.white
                        : const Color(0xFF242126);
                    return Semantics(
                      button: true,
                      selected: isSelected,
                      label: label,
                      child: Tooltip(
                        message: label,
                        child: InkWell(
                          key: ValueKey<String>('theme_color_${preset.name}'),
                          customBorder: const CircleBorder(),
                          onTap: () => onSelected(preset),
                          child: Center(
                            child: AnimatedContainer(
                              duration: tokens.motionFast,
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: preset.color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? cs.onSurface
                                      : cs.outlineVariant.withValues(
                                          alpha: 0.7,
                                        ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
