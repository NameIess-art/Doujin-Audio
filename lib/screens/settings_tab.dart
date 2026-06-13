import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/app_cache_service.dart';
import '../services/app_log_service.dart';
import '../services/app_update_service.dart';
import '../services/permission_action_controller.dart';
import '../theme/theme_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_transitions.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/subtitle_window_visual.dart';
import '../widgets/top_page_header.dart';
import '../providers/subtitle_settings_provider.dart';
import 'permission_status_page.dart';
import 'data_support_page.dart';

part 'settings_tab_actions.dart';
part 'settings_tab_widgets.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  static const List<int> _cacheLimitOptions = <int>[
    100 * 1024 * 1024,
    300 * 1024 * 1024,
    500 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
  ];

  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  double? _downloadProgress;
  AppUpdateInfo? _lastUpdateInfo;
  late Future<AppVersionInfo> _appVersionFuture;
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
    _appVersionFuture = AppUpdateService.currentAppVersion();
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
    if (index == 3) {
      // 3 is SettingsTab after inserting ASMR.ONE on the left.
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
    }
  }

  void _openPermissionCenter() {
    Navigator.of(
      context,
    ).push(buildAppPageRoute<void>(child: const PermissionStatusPage()));
  }

  void _openDataAndSupport() {
    Navigator.of(
      context,
    ).push(buildAppPageRoute<void>(child: const DataSupportPage()));
  }

  void _showSubtitleWindowSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _SubtitleWindowSettingsSheet(),
    );
  }

  void _showCardInfoFieldsSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _CardInfoFieldsSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = context.watch<AppLanguageProvider>();
    final audioProvider = ref.read(audioProviderFacadeProvider);
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
          bottom: 0,
          left: 0,
          right: 0,
          child: ListView(
            controller: _scrollController,
            // Offset top padding since Positioned already shifts it.
            // Expand internal padding by 80px to match the expanded Positioned bounds.
            padding: EdgeInsets.fromLTRB(16, 80 + 4, 16, bottomInset + 24),
            clipBehavior: Clip.none,
            children: [
              ListTileTheme.merge(
                dense: true,
                visualDensity: VisualDensity.compact,
                child: Column(
                  children: [
                    _SectionHeader(title: i18n.tr('section_general')),
                    _SettingsGroupCard(
                      children: [
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
                              dropdownColor: cs.surfaceContainerHigh.withValues(alpha: 1.0),
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
                        Consumer(
                          builder: (context, ref, _) {
                            final startupPage = ref.watch(
                              settingsStateProvider.select(
                                (state) =>
                                    state.valueOrNull?.startupPage ??
                                    StartupPage.library,
                              ),
                            );
                            return ListTile(
                              title: Text(i18n.tr('startup_page')),
                              subtitle: Text(
                                i18n.tr('startup_page_subtitle'),
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
                                  Icons.home_rounded,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                              trailing: DropdownButtonHideUnderline(
                                child: DropdownButton<StartupPage>(
                                  value: startupPage,
                                  dropdownColor: cs.surfaceContainerHigh.withValues(alpha: 1.0),
                                  borderRadius: BorderRadius.circular(12),
                                  onChanged: (value) {
                                    if (value != null) {
                                      audioProvider.setStartupPage(value);
                                    }
                                  },
                                  items: StartupPage.values
                                      .map(
                                        (page) => DropdownMenuItem<StartupPage>(
                                          value: page,
                                          child: Text(
                                            i18n.tr(
                                              'startup_page_${page.name}',
                                            ),
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
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final dlsiteLanguage = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s.valueOrNull?.dlsiteMetadataLanguage ??
                                    AppLanguage.ja,
                              ),
                            );
                            return ListTile(
                              title: Text(i18n.tr('dlsite_metadata_language')),
                              subtitle: Text(
                                i18n.tr('dlsite_metadata_language_subtitle'),
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
                                  Icons.public_rounded,
                                  color: cs.onPrimaryContainer,
                                ),
                              ),
                              trailing: DropdownButtonHideUnderline(
                                child: DropdownButton<AppLanguage>(
                                  value: dlsiteLanguage,
                                  dropdownColor: cs.surfaceContainerHigh.withValues(alpha: 1.0),
                                  borderRadius: BorderRadius.circular(12),
                                  onChanged: (value) {
                                    if (value != null) {
                                      audioProvider.setDlsiteMetadataLanguage(
                                        value,
                                      );
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
                            );
                          },
                        ),
                      ],
                    ),
                    _SectionHeader(title: i18n.tr('section_appearance')),
                    _SettingsGroupCard(
                      children: [
                        Consumer(
                          builder: (context, ref, _) {
                            final themeMode = context
                                .select<ThemeProvider, ThemeMode>(
                                  (provider) => provider.themeMode,
                                );
                            final modeLabels = <ThemeMode, String>{
                              ThemeMode.system: i18n.tr('theme_system'),
                              ThemeMode.light: i18n.tr('theme_light'),
                              ThemeMode.dark: i18n.tr('theme_dark'),
                            };
                            return ListTile(
                              title: Text(i18n.tr('dark_mode')),
                              subtitle: Text(
                                i18n.tr('dark_mode_subtitle'),
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
                                  Icons.dark_mode_rounded,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                              trailing: DropdownButtonHideUnderline(
                                child: DropdownButton<ThemeMode>(
                                  value: themeMode,
                                  dropdownColor: cs.surfaceContainerHigh.withValues(alpha: 1.0),
                                  borderRadius: BorderRadius.circular(12),
                                  onChanged: (value) {
                                    if (value != null) {
                                      context.read<ThemeProvider>().setThemeMode(value);
                                    }
                                  },
                                  items: ThemeMode.values
                                      .map(
                                        (mode) => DropdownMenuItem<ThemeMode>(
                                          value: mode,
                                          child: Text(
                                            modeLabels[mode]!,
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
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final uiBlurEnabled = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s.valueOrNull?.uiBlurEffectEnabled ?? true,
                              ),
                            );
                            return SwitchListTile(
                              value: uiBlurEnabled,
                              onChanged: audioProvider.setUiBlurEffectEnabled,
                              title: Text(i18n.tr('ui_blur_effect')),
                              subtitle: Text(
                                i18n.tr('ui_blur_effect_subtitle'),
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
                                  Icons.blur_linear_rounded,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final blurEnabled = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s
                                        .valueOrNull
                                        ?.blurPlayerBackgroundEnabled ??
                                    true,
                              ),
                            );
                            return SwitchListTile(
                              value: blurEnabled,
                              onChanged:
                                  audioProvider.setBlurPlayerBackgroundEnabled,
                              title: Text(i18n.tr('blur_player_background')),
                              subtitle: Text(
                                i18n.tr('blur_player_background_subtitle'),
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
                                  Icons.blur_on_rounded,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final showPlaybackCard = ref.watch(
                              settingsStateProvider.select(
                                (s) => s.valueOrNull?.showPlaybackCard ?? true,
                              ),
                            );
                            return SwitchListTile(
                              value: showPlaybackCard,
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
                                  color: cs.secondaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.play_circle_outline_rounded,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final fields = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s.valueOrNull?.cardInfoFields ??
                                    CardInfoField.defaults,
                              ),
                            );
                            final summary = fields.isEmpty
                                ? i18n.tr('card_info_none')
                                : fields
                                      .map(
                                        (field) =>
                                            _cardInfoFieldLabel(i18n, field),
                                      )
                                      .join('\uFF0C');
                            return ListTile(
                              title: Text(i18n.tr('card_info_display')),
                              subtitle: Text(summary, style: descStyle),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: cs.secondaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.badge_rounded,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                              trailing: Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                                color: cs.onSurfaceVariant,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              onTap: () => _showCardInfoFieldsSettings(context),
                            );
                          },
                        ),
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
                              color: cs.secondaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.subtitles_rounded,
                              color: cs.onSecondaryContainer,
                            ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          onTap: () => _showSubtitleWindowSettings(context),
                        ),
                      ],
                    ),
                    _SectionHeader(title: i18n.tr('section_playback')),
                    _SettingsGroupCard(
                      children: [
                        Consumer(
                          builder: (context, ref, _) {
                            final autoPlay = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s.valueOrNull?.autoPlayAddedSessions ??
                                    true,
                              ),
                            );
                            return SwitchListTile(
                              value: autoPlay,
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
                                  color: cs.tertiaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.playlist_play_rounded,
                                  color: cs.onTertiaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final recordProgress = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s.valueOrNull?.recordPlaybackProgress ??
                                    true,
                              ),
                            );
                            return SwitchListTile(
                              value: recordProgress,
                              onChanged:
                                  audioProvider.setRecordPlaybackProgress,
                              title: Text(i18n.tr('record_playback_progress')),
                              subtitle: Text(
                                i18n.tr('record_playback_progress_subtitle'),
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
                                  Icons.restore_rounded,
                                  color: cs.onTertiaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final multiThreadEnabled = ref.watch(
                              settingsStateProvider.select(
                                (s) =>
                                    s.valueOrNull?.multiThreadPlaybackEnabled ??
                                    false,
                              ),
                            );
                            return SwitchListTile(
                              value: multiThreadEnabled,
                              onChanged: (value) {
                                audioProvider.setMultiThreadPlaybackEnabled(
                                  value,
                                );
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
                                  color: cs.tertiaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.multitrack_audio_rounded,
                                  color: cs.onTertiaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    _SectionHeader(title: i18n.tr('section_data_storage')),
                    _SettingsGroupCard(
                      children: [
                        ListTile(
                          onTap: _openDataAndSupport,
                          title: Text(i18n.tr('data_and_support')),
                          subtitle: Text(
                            i18n.tr('data_and_support_subtitle'),
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
                              Icons.health_and_safety_rounded,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                        ),
                        if (!Platform.isWindows) ...[
                          Consumer(
                            builder: (context, ref, _) {
                              final maxCacheBytes = ref.watch(
                                settingsStateProvider.select(
                                  (s) =>
                                      s.valueOrNull?.maxCacheBytes ??
                                      AppCacheService.defaultMaxCacheBytes,
                                ),
                              );
                              return ListTile(
                                title: Text(i18n.tr('max_cache_size')),
                                subtitle: Text(
                                  i18n.tr('max_cache_size_subtitle', {
                                    'size': AppCacheService.formatBytes(
                                      maxCacheBytes,
                                    ),
                                  }),
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
                                    Icons.storage_rounded,
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                                trailing: DropdownButtonHideUnderline(
                                  child: DropdownButton<int>(
                                    value:
                                        _cacheLimitOptions.contains(
                                          maxCacheBytes,
                                        )
                                        ? maxCacheBytes
                                        : AppCacheService.defaultMaxCacheBytes,
                                    dropdownColor: cs.surfaceContainerHigh.withValues(alpha: 1.0),
                                    borderRadius: BorderRadius.circular(12),
                                    onChanged: (value) {
                                      if (value != null) {
                                        audioProvider.setMaxCacheBytes(value);
                                      }
                                    },
                                    items: _cacheLimitOptions
                                        .map(
                                          (value) => DropdownMenuItem<int>(
                                            value: value,
                                            child: Text(
                                              AppCacheService.formatBytes(
                                                value,
                                              ),
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
                              );
                            },
                          ),
                          ListTile(
                            onTap: () => _clearApplicationCache(context),
                            title: Text(i18n.tr('clear_app_cache')),
                            subtitle: Text(
                              i18n.tr('clear_app_cache_subtitle'),
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
                                Icons.cleaning_services_rounded,
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                          ),
                        ],
                      ],
                    ),
                    _SectionHeader(title: i18n.tr('section_system_updates')),
                    _SettingsGroupCard(
                      children: [
                        if (!Platform.isWindows) ...[
                          ListTile(
                            onTap: _openPermissionCenter,
                            title: Text(i18n.tr('permission_center')),
                            subtitle: Text(
                              i18n.tr('permission_center_subtitle'),
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
                                Icons.admin_panel_settings_rounded,
                                color: cs.onSecondaryContainer,
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
                        ],
                        _UpdateSettingsTile(
                          checking: _checkingUpdate,
                          downloading: _downloadingUpdate,
                          progress: _downloadProgress,
                          updateInfo: _lastUpdateInfo,
                          currentVersion: _appVersionFuture,
                          textStyle: descStyle,
                          onCheck: () => _checkForUpdates(context),
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final autoCheckUpdates = ref.watch(
                              settingsStateProvider.select(
                                (s) => s.valueOrNull?.autoCheckUpdates ?? false,
                              ),
                            );
                            return SwitchListTile(
                              value: autoCheckUpdates,
                              onChanged: audioProvider.setAutoCheckUpdates,
                              title: Text(i18n.tr('auto_check_updates')),
                              subtitle: Text(
                                i18n.tr('auto_check_updates_subtitle'),
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
                                  Icons.update_rounded,
                                  color: cs.onSecondaryContainer,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
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
