import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/app_update_service.dart';
import '../services/audio_state_services.dart';
import '../services/permission_action_controller.dart';
import '../services/platform_channels.dart';
import '../theme/theme_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/top_page_header.dart';
import '../providers/subtitle_settings_provider.dart';

part 'settings_tab_actions.dart';
part 'settings_tab_widgets.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  static const MethodChannel _powerChannel = MethodChannel(PowerChannel.name);
  static const MethodChannel _notificationsChannel = MethodChannel(
    NotificationsChannel.name,
  );

  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  double? _downloadProgress;
  AppUpdateInfo? _lastUpdateInfo;
  late Future<bool> _backgroundRunAllowedFuture;
  late Future<bool> _exactAlarmAllowedFuture;
  late Future<bool> _notificationsAllowedFuture;
  final PermissionActionController _permissionActionController =
      PermissionActionController();

  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 62;
  final ScrollController _scrollController = ScrollController();
  ValueListenable<int?>? _scrollToTopListenable;

  @override
  bool get wantKeepAlive => true;

  void _setLocalState(VoidCallback fn) => setState(fn);

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final h = box.size.height;
      if (h > 0 && h != _headerHeight) {
        setState(() => _headerHeight = h);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backgroundRunAllowedFuture = _isIgnoringBatteryOptimizations();
    _exactAlarmAllowedFuture = _canScheduleExactAlarms();
    _notificationsAllowedFuture = _areNotificationsEnabled();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _measureHeader();
        _scrollToTopListenable = ref
            .read(audioProviderFacadeProvider)
            .scrollToTopTabListenable;
        _scrollToTopListenable?.addListener(_handleScrollToTopSignal);
      }
    });
  }

  void _handleScrollToTopSignal() {
    if (!mounted) return;
    final index = _scrollToTopListenable?.value;
    if (index == 2) {
      // 2 is SettingsTab
      _jumpSettingsToTop();
    }
  }

  void _jumpSettingsToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollToTopListenable?.removeListener(_handleScrollToTopSignal);
    _scrollController.dispose();
    _permissionActionController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_permissionActionController.handleAppResumed());
      _refreshBackgroundRunStatus();
    }
  }

  void _refreshBackgroundRunStatus() {
    if (!mounted) return;
    setState(() {
      _backgroundRunAllowedFuture = _isIgnoringBatteryOptimizations();
      _exactAlarmAllowedFuture = _canScheduleExactAlarms();
      _notificationsAllowedFuture = _areNotificationsEnabled();
    });
  }

  void _showSubtitleWindowSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _SubtitleWindowSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = context.watch<AppLanguageProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final audioProvider = ref.read(audioProviderFacadeProvider);
    final playbackSettings =
        ref.watch(settingsStateProvider).valueOrNull ?? const SettingsState();
    final bottomInset = MobileOverlayInset.of(context);
    final cs = Theme.of(context).colorScheme;
    final descStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 11,
      height: 1.25,
      color: cs.onSurfaceVariant,
    );

    return Stack(
      children: [
        Positioned(
          top: _headerHeight - 80,
          bottom: bottomInset,
          left: 0,
          right: 0,
          child: ListView(
            controller: _scrollController,
            // Flush with bottom dock. Offset top padding since Positioned already shifts it.
            // Expand internal padding by 80px to match the expanded Positioned bounds.
            padding: const EdgeInsets.fromLTRB(16, 80 + 4, 16, 0),
            clipBehavior: Clip.none,
            children: [
              ListTileTheme.merge(
                dense: true,
                visualDensity: VisualDensity.compact,
                child: Column(
                  children: [
                    _SectionHeader(title: i18n.tr('section_appearance')),
                    const SizedBox(height: 2),
                    SwitchListTile(
                      value: themeProvider.isDarkMode,
                      onChanged: themeProvider.toggleTheme,
                      title: Text(i18n.tr('dark_mode')),
                      subtitle: Text(
                        i18n.tr('dark_mode_subtitle'),
                        style: descStyle,
                      ),
                      secondary: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.dark_mode_rounded,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    const SizedBox(height: 2),
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
                    const SizedBox(height: 2),
                    SwitchListTile(
                      value: playbackSettings.showPlaybackCard,
                      onChanged: audioProvider.setShowPlaybackCard,
                      title: Text(i18n.tr('show_playback_card')),
                      subtitle: Text(
                        i18n.tr('show_playback_card_subtitle'),
                        style: descStyle,
                      ),
                      secondary: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.play_circle_outline_rounded,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    const SizedBox(height: 2),
                    ListTile(
                      title: Text(i18n.tr('subtitle_window_settings')),
                      subtitle: Text(
                        i18n.tr('subtitle_window_settings_subtitle'),
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
                          Icons.subtitles_rounded,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: cs.onSurfaceVariant,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      onTap: () => _showSubtitleWindowSettings(context),
                    ),
                    const SizedBox(height: 12),
                    _SectionHeader(title: i18n.tr('section_playback')),
                    const SizedBox(height: 2),
                    SwitchListTile(
                      value: playbackSettings.multiThreadPlaybackEnabled,
                      onChanged: (value) {
                        audioProvider.setMultiThreadPlaybackEnabled(value);
                        if (!value) {
                          ref
                              .read(subtitleSettingsProvider.notifier)
                              .turnOffAllSubtitles();
                        }
                      },
                      title: Text(i18n.tr('multi_thread_playback')),
                      subtitle: Text(
                        i18n.tr('multi_thread_playback_subtitle'),
                        style: descStyle,
                      ),
                      secondary: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: cs.secondaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.multitrack_audio_rounded,
                          color: cs.onSecondaryContainer,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    const SizedBox(height: 2),
                    SwitchListTile(
                      value: playbackSettings.autoPlayAddedSessions,
                      onChanged: audioProvider.setAutoPlayAddedSessions,
                      title: Text(i18n.tr('auto_play_added_sessions')),
                      subtitle: Text(
                        i18n.tr('auto_play_added_sessions_subtitle'),
                        style: descStyle,
                      ),
                      secondary: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.playlist_play_rounded,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _SectionHeader(title: i18n.tr('section_notification')),
                    const SizedBox(height: 2),
                    SwitchListTile(
                      value: playbackSettings.notificationsEnabled,
                      onChanged: audioProvider.setNotificationsEnabled,
                      title: Text(i18n.tr('notification_bar')),
                      subtitle: Text(
                        i18n.tr('notification_bar_subtitle'),
                        style: descStyle,
                      ),
                      secondary: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: cs.tertiaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.notifications_active_rounded,
                          color: cs.onTertiaryContainer,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    const SizedBox(height: 2),
                    _CapabilitySettingsTile(
                      title: i18n.tr('notification_permission_status'),
                      icon: Icons.notifications_rounded,
                      okFuture: _notificationsAllowedFuture,
                      okText: i18n.tr('notification_permission_ready'),
                      missingText: i18n.tr('notification_permission_missing'),
                      checkingText: i18n.tr('notification_permission_checking'),
                      onTap: () => _openNotificationSettings(context),
                    ),
                    const SizedBox(height: 2),
                    _CapabilitySettingsTile(
                      title: i18n.tr('exact_alarm_permission_status'),
                      icon: Icons.alarm_on_rounded,
                      okFuture: _exactAlarmAllowedFuture,
                      okText: i18n.tr('exact_alarm_permission_ready'),
                      missingText: i18n.tr('exact_alarm_permission_missing'),
                      checkingText: i18n.tr('exact_alarm_permission_checking'),
                      onTap: () => _openExactAlarmSettings(context),
                    ),
                    const SizedBox(height: 2),
                    ListTile(
                      onTap: () => _openBackgroundRunSettings(context),
                      title: Text(i18n.tr('allow_background_run')),
                      subtitle: FutureBuilder<bool>(
                        future: _backgroundRunAllowedFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                                  ConnectionState.done &&
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
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Divider(),
                    const SizedBox(height: 8),
                    _SectionHeader(title: i18n.tr('section_other')),
                    const SizedBox(height: 2),
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
                    const SizedBox(height: 2),
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
            ],
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            icon: Icons.settings_rounded,
            title: i18n.tr('settings'),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            bottomSpacing: 16,
          ),
        ),
      ],
    );
  }
}
