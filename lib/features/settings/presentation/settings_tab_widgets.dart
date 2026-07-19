part of 'settings_tab.dart';

const double _settingsTileHeight = 58;
const double _settingsTileReferenceHeight = 68;
const double _settingsTileTitleFontSize =
    _settingsTileHeight * 18 / _settingsTileReferenceHeight;
const double _settingsTileSubtitleFontSize =
    _settingsTileHeight * 15 / _settingsTileReferenceHeight;
const double _settingsDropdownMinWidth = 128;
const double _settingsDropdownMaxWidth = 180;

Widget _settingsTitle(String text) {
  return Text(text, softWrap: true, overflow: TextOverflow.visible);
}

Widget _settingsDropdownText(
  String text, {
  TextStyle? style,
  TextAlign textAlign = TextAlign.end,
}) {
  return Text(
    text,
    softWrap: true,
    overflow: TextOverflow.visible,
    textAlign: textAlign,
    style: style ?? const TextStyle(fontWeight: FontWeight.w700),
  );
}

Widget _settingsDropdown<T>(
  BuildContext context, {
  required T value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?>? onChanged,
}) {
  final mediaQuery = MediaQuery.of(context);
  final screenWidth = mediaQuery.size.width;
  final textScale = mediaQuery.textScaler.scale(1);
  final minWidth = screenWidth < 360 ? 112.0 : _settingsDropdownMinWidth;
  final maxWidth = (screenWidth * 0.52)
      .clamp(minWidth, _settingsDropdownMaxWidth + 40)
      .toDouble();
  final width = (screenWidth * (textScale >= 2 ? 0.48 : 0.4))
      .clamp(minWidth, maxWidth)
      .toDouble();
  return SizedBox(
    width: width,
    child: UnifiedDropdownButton<T>(
      value: value,
      items: items,
      onChanged: onChanged,
      isExpanded: true,
      multilineItems: true,
    ),
  );
}

class _SettingsTileTheme extends StatelessWidget {
  const _SettingsTileTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleTextStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: _settingsTileTitleFontSize,
    );
    final subtitleTextStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: _settingsTileSubtitleFontSize,
    );

    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.copyWith(
          titleMedium: titleTextStyle,
          bodyMedium: subtitleTextStyle,
        ),
      ),
      child: ListTileTheme.merge(
        visualDensity: const VisualDensity(horizontal: -1),
        minTileHeight: _settingsTileHeight,
        minVerticalPadding: 8,
        titleTextStyle: titleTextStyle,
        subtitleTextStyle: subtitleTextStyle,
        child: child,
      ),
    );
  }
}

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final List<Widget> separatedChildren = [];
    for (int i = 0; i < children.length; i++) {
      separatedChildren.add(children[i]);
      if (i < children.length - 1) {
        separatedChildren.add(const SizedBox(height: 8));
      }
    }

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: separatedChildren,
        ),
      ),
    );
  }
}

class _UpdateSettingsTile extends StatelessWidget {
  const _UpdateSettingsTile({
    required this.checking,
    required this.downloading,
    required this.progress,
    required this.updateInfo,
    required this.currentVersion,
    required this.textStyle,
    required this.onCheck,
  });

  final bool checking;
  final bool downloading;
  final double? progress;
  final AppUpdateInfo? updateInfo;
  final Future<AppVersionInfo> currentVersion;
  final TextStyle? textStyle;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final busy = checking || downloading;

    return ListTile(
      onTap: busy ? null : onCheck,
      leading: _settingsIcon(Icons.system_update_alt_rounded, cs.onSurface),
      title: _settingsTitle(i18n.tr('check_updates')),
      subtitle: _UpdateSubtitle(
        checking: checking,
        downloading: downloading,
        progress: progress,
        updateInfo: updateInfo,
        currentVersion: currentVersion,
        textStyle: textStyle,
      ),
      trailing: SizedBox(
        width: 48,
        height: 48,
        child: busy
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              )
            : IconButton.filledTonal(
                onPressed: onCheck,
                tooltip: i18n.tr('check'),
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusControl),
      ),
    );
  }
}

class _UpdateSubtitle extends StatelessWidget {
  const _UpdateSubtitle({
    required this.checking,
    required this.downloading,
    required this.progress,
    required this.updateInfo,
    required this.currentVersion,
    required this.textStyle,
  });

  final bool checking;
  final bool downloading;
  final double? progress;
  final AppUpdateInfo? updateInfo;
  final Future<AppVersionInfo> currentVersion;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (checking) {
      return Text(
        i18n.tr('checking_updates'),
        softWrap: true,
        style: textStyle,
      );
    }
    if (downloading) {
      final value = progress;
      final percent = value == null ? '--' : '${(value * 100).round()}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            i18n.tr('downloading_update', {'percent': percent}),
            softWrap: true,
            style: textStyle,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value),
        ],
      );
    }
    final info = updateInfo;
    if (info != null) {
      final key = switch (info.status) {
        AppUpdateStatus.updateAvailable => 'update_available_subtitle',
        AppUpdateStatus.noCompatibleRelease => 'update_no_compatible_release',
        AppUpdateStatus.missingAsset => 'update_missing_asset',
        AppUpdateStatus.missingChecksum => 'update_missing_checksum',
        _ => 'check_updates_subtitle_latest',
      };
      return Text(
        i18n.tr(key, {'version': info.latestVersionName}),
        softWrap: true,
        style: textStyle,
      );
    }
    return FutureBuilder<AppVersionInfo>(
      future: currentVersion,
      builder: (context, snapshot) => Text(
        i18n.tr('current_version_label', {
          'version': snapshot.data?.versionName ?? '...',
        }),
        softWrap: true,
        style: textStyle,
      ),
    );
  }
}

class _SubtitleWindowSettingsSheet extends StatelessWidget {
  const _SubtitleWindowSettingsSheet();

  static const _fontFamilies = <String>[
    '',
    'monospace',
    'serif',
    'sans-serif',
    'SimSun',
    'KaiTi',
    'SimHei',
  ];
  static const double _previewHeight = 216;
  static const double _previewTopInset = 8;
  static const double _previewSideInset = 24;
  static const double _previewBottomGap = 28;

  Widget _buildRgbSliders({
    required String label,
    required String resetTooltip,
    required Color? currentColor,
    required Color defaultColor,
    required ValueChanged<Color> onChanged,
    required VoidCallback onReset,
    required ColorScheme cs,
    required TextStyle? labelStyle,
  }) {
    final int r = ((currentColor?.r ?? defaultColor.r) * 255).round();
    final int g = ((currentColor?.g ?? defaultColor.g) * 255).round();
    final int b = ((currentColor?.b ?? defaultColor.b) * 255).round();
    final int a = ((currentColor?.a ?? defaultColor.a) * 255).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: labelStyle)),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color.fromARGB(a, r, g, b),
                shape: BoxShape.circle,
                border: Border.all(color: cs.outlineVariant),
              ),
            ),
            if (currentColor != null)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: onReset,
                tooltip: resetTooltip,
              ),
          ],
        ),
        const SizedBox(height: 4),
        _buildSlider('R', r, cs, (v) {
          onChanged(Color.fromARGB(a, v.round(), g, b));
        }),
        _buildSlider('G', g, cs, (v) {
          onChanged(Color.fromARGB(a, r, v.round(), b));
        }),
        _buildSlider('B', b, cs, (v) {
          onChanged(Color.fromARGB(a, r, g, v.round()));
        }),
      ],
    );
  }

  Widget _buildSlider(
    String label,
    int value,
    ColorScheme cs,
    ValueChanged<double> onChanged,
  ) {
    return _RgbSliderRow(
      label: label,
      value: value,
      cs: cs,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);

    return Consumer(
      builder: (context, ref, child) {
        final settings = ref.watch(subtitleSettingsProvider);
        final notifier = ref.read(subtitleSettingsProvider.notifier);

        final currentFontColor = settings.fontColor;
        final currentBgColor = settings.backgroundColor;
        final mediaHeight = MediaQuery.sizeOf(context).height;
        final sheetHeight = mediaHeight * 0.76;
        const contentTopPadding =
            _previewTopInset + _previewHeight + _previewBottomGap;

        return SizedBox(
          height: sheetHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    24,
                    contentTopPadding,
                    24,
                    32,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SettingsGroupCard(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  i18n.tr('font_setting'),
                                  style: labelStyle,
                                ),
                                const SizedBox(height: 8),
                                InputDecorator(
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  child: UnifiedDropdownButton<String>(
                                    value: settings.fontFamily,
                                    isDense: true,
                                    isExpanded: true,
                                    multilineItems: true,
                                    alignment: AlignmentDirectional.centerStart,
                                    items: List.generate(_fontFamilies.length, (
                                      i,
                                    ) {
                                      final label = i == 0
                                          ? i18n.tr('system_default')
                                          : _fontFamilies[i];
                                      return DropdownMenuItem(
                                        value: _fontFamilies[i],
                                        child: _settingsDropdownText(
                                          label,
                                          textAlign: TextAlign.start,
                                          style: TextStyle(
                                            fontFamily: _fontFamilies[i].isEmpty
                                                ? null
                                                : _fontFamilies[i],
                                          ),
                                        ),
                                      );
                                    }),
                                    onChanged: (v) {
                                      if (v != null) notifier.setFontFamily(v);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        i18n.tr('font_size'),
                                        style: labelStyle,
                                      ),
                                    ),
                                    Text(
                                      settings.fontSize.toStringAsFixed(0),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: settings.fontSize,
                                  min: 12,
                                  max: 32,
                                  divisions: 20,
                                  onChanged: (v) => notifier.setFontSize(v),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            child: _buildRgbSliders(
                              label: i18n.tr('font_color'),
                              resetTooltip: i18n.tr('reset_to_default'),
                              currentColor: currentFontColor,
                              defaultColor: const Color(0xFFFFFFFF),
                              cs: cs,
                              labelStyle: labelStyle,
                              onChanged: (c) => notifier.setFontColor(c),
                              onReset: () => notifier.setFontColor(null),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _SettingsGroupCard(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        i18n.tr('background_transparency'),
                                        style: labelStyle,
                                      ),
                                    ),
                                    Text(
                                      '${((1.0 - settings.backgroundOpacity) * 100).toStringAsFixed(0)}%',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: 1.0 - settings.backgroundOpacity,
                                  divisions: 100,
                                  onChanged: (v) =>
                                      notifier.setBackgroundOpacity(1.0 - v),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: _buildRgbSliders(
                              label: i18n.tr('background_color'),
                              resetTooltip: i18n.tr('reset_to_default'),
                              currentColor: currentBgColor,
                              defaultColor: const Color(0xFF000000),
                              cs: cs,
                              labelStyle: labelStyle,
                              onChanged: (c) => notifier.setBackgroundColor(c),
                              onReset: () => notifier.setBackgroundColor(null),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        i18n.tr('border_depth'),
                                        style: labelStyle,
                                      ),
                                    ),
                                    Text(
                                      (settings.borderDepth * 100)
                                          .toStringAsFixed(0),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: settings.borderDepth,
                                  divisions: 100,
                                  onChanged: (v) => notifier.setBorderDepth(v),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: _previewTopInset,
                left: _previewSideInset,
                right: _previewSideInset,
                child: IgnorePointer(
                  child: _SubtitleWindowPreviewCard(
                    settings: settings,
                    title: i18n.tr('subtitle_window_preview'),
                    hint: i18n.tr('subtitle_window_preview_hint'),
                    sampleText: i18n.tr('subtitle_preview_sample'),
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

class _SubtitleWindowPreviewCard extends StatelessWidget {
  const _SubtitleWindowPreviewCard({
    required this.settings,
    required this.title,
    required this.hint,
    required this.sampleText,
  });

  final SubtitleSettingsState settings;
  final String title;
  final String hint;
  final String sampleText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardRadius = BorderRadius.circular(
      AppDesignTokens.of(context).radiusOverlay,
    );

    return SizedBox(
      height: _SubtitleWindowSettingsSheet._previewHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: cardRadius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              isDark ? const Color(0xFF131A29) : const Color(0xFFF6F8FC),
              isDark ? const Color(0xFF0B0F18) : const Color(0xFFE9EEF7),
            ],
          ),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.28 : 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: isDark ? 0.26 : 0.12),
              blurRadius: 26,
              spreadRadius: -10,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: cardRadius,
          child: Stack(
            children: [
              Positioned(
                left: -18,
                top: -24,
                child: _PreviewOrb(
                  size: 132,
                  color: cs.primary.withValues(alpha: isDark ? 0.24 : 0.14),
                ),
              ),
              Positioned(
                right: -22,
                bottom: -34,
                child: _PreviewOrb(
                  size: 148,
                  color: cs.secondary.withValues(alpha: isDark ? 0.18 : 0.12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      height: 84,
                      child: Center(
                        child: SubtitleWindowVisual(
                          settings: settings,
                          text: sampleText,
                          maxTextWidth: 260,
                          fallbackBackgroundColor: Colors.black,
                        ),
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewOrb extends StatelessWidget {
  const _PreviewOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: color.a * 0.25),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.42, 1],
          ),
        ),
      ),
    );
  }
}

class _RgbSliderRow extends StatefulWidget {
  const _RgbSliderRow({
    required this.label,
    required this.value,
    required this.cs,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ColorScheme cs;
  final ValueChanged<double> onChanged;

  @override
  State<_RgbSliderRow> createState() => _RgbSliderRowState();
}

class _RgbSliderRowState extends State<_RgbSliderRow> {
  late final TextEditingController _controller;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(covariant _RgbSliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && widget.value != oldWidget.value) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    _editing = false;
    final parsed = int.tryParse(_controller.text);
    if (parsed != null) {
      widget.onChanged(parsed.clamp(0, 255).toDouble());
    } else {
      _controller.text = widget.value.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: widget.cs.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: widget.value.toDouble(),
            max: 255,
            divisions: 255,
            onChanged: widget.onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: widget.cs.onSurface),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 2,
                vertical: 4,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(
                  color: widget.cs.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: widget.cs.primary, width: 1.5),
              ),
            ),
            onTap: () => _editing = true,
            onSubmitted: (_) => _submit(),
            onEditingComplete: _submit,
            onTapOutside: (_) => _submit(),
          ),
        ),
      ],
    );
  }
}

class _CardInfoFieldsSettingsSheet extends ConsumerWidget {
  const _CardInfoFieldsSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final settings = ref.read(settingsRepositoryProvider);
    final selected = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.cardInfoFields ?? CardInfoField.defaults,
      ),
    );
    final selectedSet = selected.toSet();

    void toggle(CardInfoField field) {
      final next = selected.toList(growable: true);
      if (selectedSet.contains(field)) {
        next.remove(field);
      } else {
        if (next.length >= CardInfoField.maxSelected) return;
        next.add(field);
      }
      settings.setCardInfoFields(next);
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              i18n.tr('card_info_display'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              i18n.tr('card_info_display_subtitle', {
                'count': selected.length.toString(),
                'max': CardInfoField.maxSelected.toString(),
              }),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final field in CardInfoField.values)
              CheckboxListTile(
                value: selectedSet.contains(field),
                onChanged:
                    selectedSet.contains(field) ||
                        selected.length < CardInfoField.maxSelected
                    ? (_) => toggle(field)
                    : null,
                title: _settingsTitle(_cardInfoFieldLabel(i18n, field)),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(i18n.tr('done')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AsmrDownloadFolderNameSettingsSheet extends ConsumerWidget {
  const _AsmrDownloadFolderNameSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final settings = ref.read(settingsRepositoryProvider);
    final selected = ref.watch(
      settingsStateProvider.select(
        (state) =>
            state.value?.asmrDownloadFolderNameFields ??
            kDefaultAsmrDownloadFolderNameFields,
      ),
    );
    final unselected = AsmrDownloadFolderNameField.values
        .where((field) => !selected.contains(field))
        .toList(growable: false);

    void remove(AsmrDownloadFolderNameField field) {
      if (selected.length == 1) return;
      unawaited(
        settings.setAsmrDownloadFolderNameFields(
          selected.where((candidate) => candidate != field),
        ),
      );
    }

    void add(AsmrDownloadFolderNameField field) {
      unawaited(settings.setAsmrDownloadFolderNameFields([...selected, field]));
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            Text(
              i18n.tr('asmr_download_folder_name_setting'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              i18n.tr('asmr_download_folder_name_hint'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: selected.length,
              onReorder: (oldIndex, newIndex) {
                final reordered = selected.toList(growable: true);
                if (newIndex > oldIndex) newIndex--;
                final field = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, field);
                unawaited(settings.setAsmrDownloadFolderNameFields(reordered));
              },
              itemBuilder: (context, index) {
                final field = selected[index];
                return CheckboxListTile(
                  key: ValueKey(field),
                  value: true,
                  onChanged: selected.length > 1 ? (_) => remove(field) : null,
                  title: _settingsTitle(
                    _asmrDownloadFolderNameFieldLabel(i18n, field),
                  ),
                  secondary: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle_rounded),
                  ),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                );
              },
            ),
            for (final field in unselected)
              CheckboxListTile(
                value: false,
                onChanged: (_) => add(field),
                title: _settingsTitle(
                  _asmrDownloadFolderNameFieldLabel(i18n, field),
                ),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(i18n.tr('done')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _asmrDownloadFolderNameFieldLabel(
  AppLanguageProvider i18n,
  AsmrDownloadFolderNameField field,
) {
  return switch (field) {
    AsmrDownloadFolderNameField.rjCode => i18n.tr(
      'asmr_download_folder_field_rj_code',
    ),
    AsmrDownloadFolderNameField.voiceActors => i18n.tr(
      'asmr_download_folder_field_voice_actors',
    ),
    AsmrDownloadFolderNameField.circleName => i18n.tr(
      'asmr_download_folder_field_circle_name',
    ),
    AsmrDownloadFolderNameField.workTitle => i18n.tr(
      'asmr_download_folder_field_work_title',
    ),
  };
}

String _cardInfoFieldLabel(AppLanguageProvider i18n, CardInfoField field) {
  return switch (field) {
    CardInfoField.rjCode => i18n.tr('audio_detail_rj_code'),
    CardInfoField.voiceActors => i18n.tr('audio_detail_voice_actors'),
    CardInfoField.circleName => i18n.tr('audio_detail_circle_name'),
    CardInfoField.tags => i18n.tr('audio_detail_tags'),
    CardInfoField.releaseDate => i18n.tr('audio_detail_release_date'),
    CardInfoField.salesCount => i18n.tr('audio_detail_sales_count'),
    CardInfoField.rating => i18n.tr('audio_detail_rating'),
  };
}
