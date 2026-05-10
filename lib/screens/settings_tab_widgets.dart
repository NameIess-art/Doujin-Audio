part of 'settings_tab.dart';

class _UpdateSettingsTile extends StatelessWidget {
  const _UpdateSettingsTile({
    required this.checking,
    required this.downloading,
    required this.progress,
    required this.updateInfo,
    required this.textStyle,
    required this.onCheck,
  });

  final bool checking;
  final bool downloading;
  final double? progress;
  final AppUpdateInfo? updateInfo;
  final TextStyle? textStyle;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final busy = checking || downloading;

    return InkWell(
      onTap: busy ? null : onCheck,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.system_update_alt_rounded,
                color: cs.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    i18n.tr('check_updates'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  _UpdateSubtitle(
                    checking: checking,
                    downloading: downloading,
                    progress: progress,
                    updateInfo: updateInfo,
                    textStyle: textStyle,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
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
          ],
        ),
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
    required this.textStyle,
  });

  final bool checking;
  final bool downloading;
  final double? progress;
  final AppUpdateInfo? updateInfo;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    if (checking) {
      return Text(
        i18n.tr('checking_updates'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value),
        ],
      );
    }
    final info = updateInfo;
    if (info != null) {
      final key = info.isUpdateAvailable
          ? 'update_available_subtitle'
          : 'check_updates_subtitle_latest';
      return Text(
        i18n.tr(key, {'version': info.latestVersionName}),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: textStyle,
      );
    }
    return Text(
      i18n.tr('check_updates_subtitle'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textStyle,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          title,
          textAlign: TextAlign.left,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
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
    final i18n = context.read<AppLanguageProvider>();
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);

    return Consumer(
      builder: (context, ref, child) {
        final settings = ref.watch(subtitleSettingsProvider);
        final notifier = ref.read(subtitleSettingsProvider.notifier);

        final currentFontColor = settings.fontColor;
        final currentBgColor = settings.backgroundColor;

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Font family
                Text(i18n.tr('font_setting'), style: labelStyle),
                const SizedBox(height: 6),
                InputDecorator(
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: settings.fontFamily,
                      isDense: true,
                      isExpanded: true,
                      borderRadius: BorderRadius.circular(12),
                      items: List.generate(_fontFamilies.length, (i) {
                        final label = i == 0
                            ? i18n.tr('system_default')
                            : _fontFamilies[i];
                        return DropdownMenuItem(
                          value: _fontFamilies[i],
                          child: Text(
                            label,
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
                ),
                const SizedBox(height: 12),

                // Font size
                Row(
                  children: [
                    Expanded(
                      child: Text(i18n.tr('font_size'), style: labelStyle),
                    ),
                    Text(
                      settings.fontSize.toStringAsFixed(0),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 12),

                // Font color RGB
                _buildRgbSliders(
                  label: i18n.tr('font_color'),
                  resetTooltip: i18n.tr('reset_to_default'),
                  currentColor: currentFontColor,
                  defaultColor: const Color(0xFFFFFFFF),
                  cs: cs,
                  labelStyle: labelStyle,
                  onChanged: (c) => notifier.setFontColor(c),
                  onReset: () => notifier.setFontColor(null),
                ),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 12),

                // Background blur
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        i18n.tr('background_blur'),
                        style: labelStyle,
                      ),
                    ),
                    Text(
                      settings.backgroundBlur.toStringAsFixed(0),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: settings.backgroundBlur,
                  min: 0,
                  max: 50,
                  divisions: 50,
                  onChanged: (v) => notifier.setBackgroundBlur(v),
                ),

                // Transparency (User requested: 0% = solid, 100% = transparent)
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: 1.0 - settings.backgroundOpacity,
                  min: 0,
                  max: 1.0,
                  divisions: 100,
                  onChanged: (v) => notifier.setBackgroundOpacity(1.0 - v),
                ),
                const SizedBox(height: 4),

                // Background color RGB
                _buildRgbSliders(
                  label: i18n.tr('background_color'),
                  resetTooltip: i18n.tr('reset_to_default'),
                  currentColor: currentBgColor,
                  defaultColor: const Color(0xFF000000),
                  cs: cs,
                  labelStyle: labelStyle,
                  onChanged: (c) => notifier.setBackgroundColor(c),
                  onReset: () => notifier.setBackgroundColor(null),
                ),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 12),

                // Border depth
                Row(
                  children: [
                    Expanded(
                      child: Text(i18n.tr('border_depth'), style: labelStyle),
                    ),
                    Text(
                      (settings.borderDepth * 100).toStringAsFixed(0),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: settings.borderDepth,
                  min: 0,
                  max: 1.0,
                  divisions: 100,
                  onChanged: (v) => notifier.setBorderDepth(v),
                ),
              ],
            ),
          ),
        );
      },
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
            min: 0,
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
