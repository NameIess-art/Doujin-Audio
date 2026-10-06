part of 'settings_tab.dart';

const double _settingsTileHeight = 78;
const double _settingsTileTitleFontSize = 16;
const double _settingsTileSubtitleFontSize = 13;
const double _settingsDropdownMaxWidth = 180;
const double _settingsDropdownChromeWidth = kMinInteractiveDimension;

Widget _settingsTitle(String text) {
  return Text(text, softWrap: true, overflow: TextOverflow.visible);
}

class _SettingsTitleBlock extends StatelessWidget {
  const _SettingsTitleBlock({required this.title, required this.subtitle});

  final String title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitleStyle =
        ListTileTheme.of(context).subtitleTextStyle ??
        Theme.of(context).textTheme.bodyMedium ??
        DefaultTextStyle.of(context).style;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsTitle(title),
        DefaultTextStyle(style: subtitleStyle, child: subtitle),
      ],
    );
  }
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
  double? maxWidth,
}) {
  final mediaQuery = MediaQuery.of(context);
  final screenWidth = mediaQuery.size.width;
  final resolvedMaxWidth = (screenWidth * 0.52)
      .clamp(0, maxWidth ?? _settingsDropdownMaxWidth + 40)
      .toDouble();
  final defaultTextStyle = DefaultTextStyle.of(context).style;
  double? longestTextWidth = 0;
  for (final item in items) {
    final child = item.child;
    if (child is! Text || child.data == null) {
      longestTextWidth = null;
      break;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: child.data,
        style: defaultTextStyle.merge(child.style),
      ),
      textDirection: Directionality.of(context),
      textScaler: mediaQuery.textScaler,
      maxLines: 1,
    )..layout();
    longestTextWidth = math.max(longestTextWidth!, painter.width);
  }
  final width =
      ((longestTextWidth ?? resolvedMaxWidth) + _settingsDropdownChromeWidth)
          .clamp(_settingsDropdownChromeWidth, resolvedMaxWidth)
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
  const _SettingsTileTheme({required this.child})
    : minTileHeight = _settingsTileHeight,
      titleFontSize = _settingsTileTitleFontSize,
      subtitleFontSize = _settingsTileSubtitleFontSize,
      titleFontWeight = null,
      subtitleFontWeight = null;

  const _SettingsTileTheme.categories({required this.child})
    : minTileHeight = 78,
      titleFontSize = 18,
      subtitleFontSize = 14,
      titleFontWeight = FontWeight.bold,
      subtitleFontWeight = FontWeight.normal;

  final Widget child;
  final double minTileHeight;
  final double titleFontSize;
  final double subtitleFontSize;
  final FontWeight? titleFontWeight;
  final FontWeight? subtitleFontWeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleTextStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: titleFontSize,
      fontWeight: titleFontWeight,
    );
    final subtitleTextStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: subtitleFontSize,
      fontWeight: subtitleFontWeight,
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.68),
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        minTileHeight: minTileHeight,
        minVerticalPadding: 2,
        titleTextStyle: titleTextStyle,
        subtitleTextStyle: subtitleTextStyle,
        titleAlignment: ListTileTitleAlignment.center,
        child: child,
      ),
    );
  }
}

class _SettingsSectionCard extends StatelessWidget {
  const _SettingsSectionCard({
    required this.title,
    required this.children,
    this.leadingContent,
    this.titleKey,
    this.sectionId,
    this.hideTitlePill = false,
    this.childrenUseOwnCards = false,
  });

  final String title;
  final List<Widget> children;
  final Widget? leadingContent;
  final Key? titleKey;
  final String? sectionId;
  final bool hideTitlePill;
  final bool childrenUseOwnCards;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Visibility(
            visible: !hideTitlePill,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: KeyedSubtree(
              key: sectionId == null
                  ? null
                  : ValueKey<String>('settings_section_pill_$sectionId'),
              child: _SettingsSectionTitlePill(key: titleKey, title: title),
            ),
          ),
          const SizedBox(height: 8),
          if (leadingContent != null) ...[
            leadingContent!,
            const SizedBox(height: 12),
          ],
          if (childrenUseOwnCards)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            )
          else
            AppSettingsGroupCard(children: children),
        ],
      ),
    );
  }
}

class _SettingsSectionTitlePill extends StatelessWidget {
  const _SettingsSectionTitlePill({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: HeaderFloatingSurface(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - 64,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
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
    final busy = checking || downloading;

    return ListTile(
      onTap: busy ? null : onCheck,
      leading: _settingsIcon(Icons.system_update_alt_rounded, cs.onSurface),
      title: _SettingsTitleBlock(
        title: i18n.tr('check_updates'),
        subtitle: _UpdateSubtitle(
          checking: checking,
          downloading: downloading,
          progress: progress,
          updateInfo: updateInfo,
          currentVersion: currentVersion,
          textStyle: textStyle,
        ),
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
            : IconButton(
                onPressed: onCheck,
                tooltip: i18n.tr('check'),
                color: cs.onSurfaceVariant,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
