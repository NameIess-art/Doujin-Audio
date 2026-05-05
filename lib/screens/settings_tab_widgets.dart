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
