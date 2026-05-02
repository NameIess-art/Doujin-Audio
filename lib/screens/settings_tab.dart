import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../services/app_update_service.dart';
import '../theme/theme_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/top_page_header.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  static const MethodChannel _powerChannel = MethodChannel(
    'music_player/power',
  );

  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  double? _downloadProgress;
  AppUpdateInfo? _lastUpdateInfo;
  late Future<bool> _backgroundRunAllowedFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backgroundRunAllowedFuture = _isIgnoringBatteryOptimizations();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBackgroundRunStatus();
    }
  }

  void _refreshBackgroundRunStatus() {
    if (!mounted) return;
    setState(() {
      _backgroundRunAllowedFuture = _isIgnoringBatteryOptimizations();
    });
  }

  Future<void> _clearTempCache(BuildContext context) async {
    final i18n = context.read<AppLanguageProvider>();
    final cacheDir = Directory(
      path.join(Directory.systemTemp.path, 'music_player_imports'),
    );
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('temp_cache_cleaned'),
          tone: AppFeedbackTone.success,
          icon: Icons.cleaning_services_rounded,
        );
      }
      return;
    }

    if (context.mounted) {
      showAppSnackBar(
        context,
        i18n.tr('temp_cache_none'),
        tone: AppFeedbackTone.info,
        icon: Icons.info_outline_rounded,
      );
    }
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _powerChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openBackgroundRunSettings(BuildContext context) async {
    if (!Platform.isAndroid) return;
    try {
      final opened =
          await _powerChannel.invokeMethod<bool>('openBackgroundRunSettings') ??
          false;
      if (!opened && context.mounted) {
        showAppSnackBar(
          context,
          context.read<AppLanguageProvider>().tr(
            'allow_background_run_open_failed',
          ),
          tone: AppFeedbackTone.warning,
          icon: Icons.settings_applications_rounded,
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        context.read<AppLanguageProvider>().tr(
          'allow_background_run_open_failed',
        ),
        tone: AppFeedbackTone.warning,
        icon: Icons.settings_applications_rounded,
      );
    } finally {
      Future<void>.delayed(
        const Duration(milliseconds: 600),
        _refreshBackgroundRunStatus,
      );
    }
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    if (_checkingUpdate || _downloadingUpdate) return;
    final i18n = context.read<AppLanguageProvider>();
    setState(() {
      _checkingUpdate = true;
      _downloadProgress = null;
    });

    AppUpdateInfo info;
    try {
      info = await AppUpdateService.checkLatest();
      if (!mounted) return;
      setState(() => _lastUpdateInfo = info);
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_check_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.cloud_off_rounded,
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }

    if (!info.isUpdateAvailable) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('no_updates_available'),
        tone: AppFeedbackTone.success,
        icon: Icons.verified_rounded,
      );
      return;
    }

    if (!context.mounted) return;
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(i18n.tr('latest_version_available')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                i18n.tr('current_version_label', {
                  'version': info.currentVersion.versionName,
                }),
              ),
              const SizedBox(height: 6),
              Text(
                i18n.tr('latest_version_label', {
                  'version': info.latestVersionName,
                }),
              ),
              const SizedBox(height: 10),
              Text(
                info.assetName,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(i18n.tr('later')),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.download_rounded),
              label: Text(i18n.tr('download_update')),
            ),
          ],
        );
      },
    );
    if (shouldDownload == true && context.mounted) {
      await _downloadAndInstallUpdate(context, info);
    }
  }

  Future<void> _downloadAndInstallUpdate(
    BuildContext context,
    AppUpdateInfo info,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    setState(() {
      _downloadingUpdate = true;
      _downloadProgress = 0;
    });

    File apkFile;
    try {
      apkFile = await AppUpdateService.downloadUpdate(
        info,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _downloadProgress = progress);
        },
      );
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_download_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _downloadingUpdate = false);
      }
    }

    try {
      final result = await AppUpdateService.installApk(apkFile);
      if (!context.mounted) return;
      if (result.needsPermission) {
        showAppSnackBar(
          context,
          i18n.tr('install_permission_needed'),
          tone: AppFeedbackTone.warning,
          icon: Icons.admin_panel_settings_rounded,
        );
        return;
      }
      if (!result.ok) {
        showAppSnackBar(
          context,
          result.message ?? i18n.tr('update_install_failed'),
          tone: AppFeedbackTone.destructive,
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      showAppSnackBar(
        context,
        i18n.tr('update_ready_install'),
        tone: AppFeedbackTone.success,
        icon: Icons.install_mobile_rounded,
      );
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        i18n.tr('update_install_failed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final audioProvider = context.watch<AudioProvider>();
    final bottomInset = MobileOverlayInset.of(context);
    final cs = Theme.of(context).colorScheme;
    final descStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 11,
      height: 1.25,
      color: cs.onSurfaceVariant,
    );

    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset),
        children: [
          TopPageHeader(
            icon: Icons.tune_rounded,
            title: i18n.tr('settings'),
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
            bottomSpacing: 10,
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Column(
                children: [
                  SwitchListTile(
                    value: themeProvider.isDarkMode,
                    onChanged: themeProvider.toggleTheme,
                    title: Text(i18n.tr('dark_mode')),
                    subtitle: Text(
                      i18n.tr('dark_mode_subtitle'),
                      style: descStyle,
                    ),
                    secondary: const Icon(Icons.dark_mode_rounded),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: audioProvider.multiThreadPlaybackEnabled,
                    onChanged: audioProvider.setMultiThreadPlaybackEnabled,
                    title: Text(i18n.tr('multi_thread_playback')),
                    subtitle: Text(
                      i18n.tr('multi_thread_playback_subtitle'),
                      style: descStyle,
                    ),
                    secondary: const Icon(Icons.multitrack_audio_rounded),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: audioProvider.notificationsEnabled,
                    onChanged: audioProvider.setNotificationsEnabled,
                    title: Text(i18n.tr('notification_bar')),
                    subtitle: Text(
                      i18n.tr('notification_bar_subtitle'),
                      style: descStyle,
                    ),
                    secondary: const Icon(Icons.notifications_active_rounded),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    title: Text(i18n.tr('language')),
                    subtitle: Text(
                      i18n.tr('language_subtitle'),
                      style: descStyle,
                    ),
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.language_rounded,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<AppLanguage>(
                        value: i18n.language,
                        borderRadius: BorderRadius.circular(12),
                        onChanged: (value) {
                          if (value != null) {
                            i18n.setLanguage(value);
                          }
                        },
                        items: AppLanguage.values
                            .map(
                              (lang) => DropdownMenuItem<AppLanguage>(
                                value: lang,
                                child: Text(
                                  i18n.languageName(lang),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    onTap: () => _openBackgroundRunSettings(context),
                    title: Text(i18n.tr('allow_background_run')),
                    subtitle: FutureBuilder<bool>(
                      future: _backgroundRunAllowedFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done &&
                            snapshot.data == null) {
                          return Text(
                            i18n.tr('allow_background_run_checking'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: descStyle,
                          );
                        }
                        final ignoring = snapshot.data == true;
                        final status = ignoring
                            ? i18n.tr('allow_background_run_ready')
                            : i18n.tr('allow_background_run_subtitle');
                        return Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: descStyle,
                        );
                      },
                    ),
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: cs.tertiaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.battery_saver_rounded,
                        color: cs.onTertiaryContainer,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    onTap: () => _clearTempCache(context),
                    title: Text(i18n.tr('clear_temp_cache')),
                    subtitle: Text(
                      i18n.tr('clear_temp_cache_subtitle'),
                      style: descStyle,
                    ),
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: cs.secondaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.cleaning_services_rounded,
                        color: cs.onSecondaryContainer,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _UpdateSettingsTile(
                    checking: _checkingUpdate,
                    downloading: _downloadingUpdate,
                    progress: _downloadProgress,
                    updateInfo: _lastUpdateInfo,
                    textStyle: descStyle,
                    onCheck: () => _checkForUpdates(context),
                  ),
                ],
              ),
            ),
          ),
        ],
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
          crossAxisAlignment: CrossAxisAlignment.center,
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
