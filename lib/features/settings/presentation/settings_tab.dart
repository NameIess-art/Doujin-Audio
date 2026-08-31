import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../application/app_cache_service.dart';
import '../application/settings_command_controller.dart';
import '../application/app_update_service.dart';
import '../application/settings_repository.dart';
import '../application/settings_state.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/card_info_field.dart';
import '../../../core/ui/permission_action_controller.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/theme/theme_provider.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/subtitle_window_visual.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_dropdown.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../app/state/subtitle_settings_provider.dart';
import '../../data_support/presentation/data_support_page.dart';
import '../../data_support/presentation/storage_usage_card.dart';
import '../../asmr/domain/asmr_download.dart';
import '../../asmr/presentation/asmr_language_labels.dart';
import 'permission_status_page.dart';
import 'app_update_flow.dart';
import 'about_page.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';

part 'settings_tab_actions.dart';
part 'settings_tab_general_section.dart';
part 'settings_tab_appearance_section.dart';
part 'settings_tab_playback_section.dart';
part 'settings_tab_asmr_section.dart';
part 'settings_tab_data_section.dart';
part 'settings_tab_update_section.dart';
part 'settings_tab_widgets.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({
    super.key,
    this.tabIndex = 3,
    this.activeTabIndexListenable,
  });

  final int tabIndex;
  final ValueListenable<int>? activeTabIndexListenable;

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab>
    with
        WidgetsBindingObserver,
        AutomaticKeepAliveClientMixin,
        MainTabStateMixin<SettingsTab> {
  final ValueNotifier<AppUpdateInfo?> _updateInfoNotifier =
      ValueNotifier<AppUpdateInfo?>(null);
  Future<AppVersionInfo>? _appVersionFuture;
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  late final AppUpdateFlow _updateFlow = AppUpdateFlow(
    permissionController: _permissionActionController,
    languageProvider: ref.read(appLanguageProviderInstanceProvider),
    updateService: ref.read(appUpdateServiceProvider),
  );

  final ScrollController _scrollController = ScrollController();

  @override
  int get tabIndex => widget.tabIndex;

  @override
  ScrollController get mainScrollController => _scrollController;

  @override
  bool get wantKeepAlive => true;

  Future<T> _runSettingsOperation<T>({
    required UiOperationScope scope,
    required String labelKey,
    required UiOperationTask<T> task,
  }) {
    return ref
        .read(uiOperationServiceProvider)
        .run<T>(scope: scope, labelKey: labelKey, task: task);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
  }

  Future<AppVersionInfo> _ensureAppVersionFuture() {
    return _appVersionFuture ??= ref
        .read(appUpdateServiceProvider)
        .currentAppVersion();
  }

  @override
  void dispose() {
    disposeTabState();
    _scrollController.dispose();
    _updateInfoNotifier.dispose();
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
    AppBottomSheet.show<void>(
      context: context,
      builder: (_) => const PermissionStatusPage(),
    );
  }

  void _openDataAndSupport() {
    AppBottomSheet.show<void>(
      context: context,
      builder: (_) => const DataSupportPage(),
    );
  }

  void _openAboutPage() {
    final versionFuture = _ensureAppVersionFuture();
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: AboutPage(versionFuture: versionFuture),
      ),
    );
  }

  void _showSubtitleWindowSettings(BuildContext context) {
    AppBottomSheet.show<void>(
      context: context,
      builder: (_) => const _SubtitleWindowSettingsSheet(),
    );
  }

  void _showCardInfoFieldsSettings(BuildContext context) {
    AppBottomSheet.show<void>(
      context: context,
      builder: (_) => const _CardInfoFieldsSettingsSheet(),
    );
  }

  Future<void> _chooseAsmrDownloadDestination() async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final folder = await _runSettingsOperation<String?>(
      scope: UiOperationScope.settingsAsmrDownloadPath,
      labelKey: 'loading_dot',
      task: (_) {
        final manager = ref.read(asmrDownloadManagerProvider);
        if (manager == null) return Future<String?>.value();
        return manager.pickDestinationFolder(
          dialogTitle: i18n.tr('asmr_download_choose_path'),
        );
      },
    );
    if (!mounted || folder == null || folder.trim().isEmpty) return;
    await _runSettingsOperation<void>(
      scope: UiOperationScope.settingsAsmrDownloadPath,
      labelKey: 'loading_dot',
      task: (_) => ref
          .read(settingsRepositoryProvider)
          .setAsmrDownloadDestinationRoot(folder),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.watch(appLanguageStateProvider);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final bottomInset = MobileOverlayInset.of(context);
    final contentTopInset =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.padding.vertical +
        AppPageHeaderMetrics.contentHeight +
        AppPageHeaderMetrics.bottomSpacing +
        AppPageHeaderMetrics.firstContentSpacing;

    return ScrollActivityGate(
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              controller: _scrollController,
              padding: EdgeInsets.fromLTRB(
                16,
                contentTopInset,
                16,
                bottomInset + AppSpacing.sm,
              ),
              clipBehavior: Clip.none,
              children: [
                _SettingsTileTheme.categories(
                  child: Column(
                    children: [
                      for (
                        var index = 0;
                        index < _SettingsCategory.values.length;
                        index++
                      )
                        _SettingsCategoryTile(
                          category: _SettingsCategory.values[index],
                          i18n: i18n,
                          isFirst: index == 0,
                          isLast: index == _SettingsCategory.values.length - 1,
                          onTap: () => _openSettingsCategory(
                            _SettingsCategory.values[index],
                          ),
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
              key: headerKey,
              icon: Icons.settings_rounded,
              topCapsuleTitle: i18n.tr('settings'),
            ),
          ),
        ],
      ),
    );
  }

  void _openSettingsCategory(_SettingsCategory category) {
    if (category == _SettingsCategory.about) {
      _openAboutPage();
      return;
    }
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: _SettingsCategoryPage(
          category: category,
          updateInfoListenable: _updateInfoNotifier,
          currentVersion: _ensureAppVersionFuture(),
          onShowSubtitleWindowSettings: () =>
              _showSubtitleWindowSettings(context),
          onShowCardInfoFieldsSettings: () =>
              _showCardInfoFieldsSettings(context),
          onChooseAsmrDownloadDestination: _chooseAsmrDownloadDestination,
          onOpenDataAndSupport: _openDataAndSupport,
          onClearApplicationCache: () => _clearApplicationCache(context),
          onOpenPermissionCenter: _openPermissionCenter,
          onCheckForUpdates: () => _checkForUpdates(context),
        ),
      ),
    );
  }
}

enum _SettingsCategory {
  language(
    'section_language',
    'section_language_subtitle',
    Icons.language_rounded,
  ),
  common('section_common', 'section_common_subtitle', Icons.tune_rounded),
  appearance(
    'section_appearance',
    'section_appearance_subtitle',
    Icons.palette_outlined,
  ),
  playback(
    'section_playback',
    'section_playback_subtitle',
    Icons.play_circle_outline_rounded,
  ),
  asmrDownload(
    'section_asmr_download',
    'section_asmr_download_subtitle',
    Icons.download_rounded,
  ),
  dataStorage(
    'section_data_storage',
    'section_data_storage_subtitle',
    Icons.storage_rounded,
  ),
  updatesPermissions(
    'section_updates_permissions',
    'section_updates_permissions_subtitle',
    Icons.system_update_alt_rounded,
  ),
  about('about', 'about_subtitle', Icons.info_outline_rounded);

  const _SettingsCategory(this.labelKey, this.subtitleKey, this.icon);

  final String labelKey;
  final String subtitleKey;
  final IconData icon;
}

class _SettingsCategoryTile extends StatelessWidget {
  const _SettingsCategoryTile({
    required this.category,
    required this.i18n,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  final _SettingsCategory category;
  final AppLanguageProvider i18n;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _settingsCard(
      context: context,
      isFirst: isFirst,
      isLast: isLast,
      child: ListTile(
        onTap: onTap,
        leading: _settingsIcon(category.icon, cs.onSurface),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              i18n.tr(category.labelKey),
              softWrap: true,
              overflow: TextOverflow.visible,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              i18n.tr(category.subtitleKey),
              maxLines: 2,
              softWrap: true,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minTileHeight: 78,
        minVerticalPadding: 0,
        titleAlignment: ListTileTitleAlignment.center,
      ),
    );
  }
}

class _SettingsCategoryPage extends ConsumerWidget {
  const _SettingsCategoryPage({
    required this.category,
    required this.updateInfoListenable,
    required this.currentVersion,
    required this.onShowSubtitleWindowSettings,
    required this.onShowCardInfoFieldsSettings,
    required this.onChooseAsmrDownloadDestination,
    required this.onOpenDataAndSupport,
    required this.onClearApplicationCache,
    required this.onOpenPermissionCenter,
    required this.onCheckForUpdates,
  }) : assert(category != _SettingsCategory.about);

  final _SettingsCategory category;
  final ValueListenable<AppUpdateInfo?> updateInfoListenable;
  final Future<AppVersionInfo> currentVersion;
  final VoidCallback onShowSubtitleWindowSettings;
  final VoidCallback onShowCardInfoFieldsSettings;
  final VoidCallback onChooseAsmrDownloadDestination;
  final VoidCallback onOpenDataAndSupport;
  final VoidCallback onClearApplicationCache;
  final VoidCallback onOpenPermissionCenter;
  final VoidCallback onCheckForUpdates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final settings = ref.read(settingsRepositoryProvider);
    final settingsController = ref.read(settingsCommandControllerProvider);
    final cs = Theme.of(context).colorScheme;

    Widget content({
      double topPadding = AppPageHeaderMetrics.firstContentSpacing,
    }) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, topPadding, 16, 24),
        children: [
          _SettingsTileTheme(
            child: Column(
              children: switch (category) {
                _SettingsCategory.language => _buildSettingsLanguageSection(
                  context: context,
                  i18n: i18n,
                  settings: settings,
                  cs: cs,
                ),
                _SettingsCategory.common => _buildSettingsGeneralSection(
                  i18n: i18n,
                  settings: settings,
                  settingsController: settingsController,
                  cs: cs,
                ),
                _SettingsCategory.appearance => _buildSettingsAppearanceSection(
                  context: context,
                  ref: ref,
                  i18n: i18n,
                  settings: settings,
                  settingsController: settingsController,
                  cs: cs,
                  onShowSubtitleWindowSettings: onShowSubtitleWindowSettings,
                  onShowCardInfoFieldsSettings: onShowCardInfoFieldsSettings,
                ),
                _SettingsCategory.playback => _buildSettingsPlaybackSection(
                  i18n: i18n,
                  settings: settings,
                  settingsController: settingsController,
                  cs: cs,
                ),
                _SettingsCategory.asmrDownload => _buildSettingsAsmrSection(
                  i18n: i18n,
                  settings: settings,
                  cs: cs,
                  onChooseAsmrDownloadDestination:
                      onChooseAsmrDownloadDestination,
                ),
                _SettingsCategory.dataStorage => _buildSettingsDataSection(
                  i18n: i18n,
                  settingsController: settingsController,
                  cs: cs,
                  onOpenDataAndSupport: onOpenDataAndSupport,
                  onClearApplicationCache: onClearApplicationCache,
                ),
                _SettingsCategory.updatesPermissions => [
                  ValueListenableBuilder<AppUpdateInfo?>(
                    valueListenable: updateInfoListenable,
                    builder: (context, updateInfo, _) => Column(
                      children: _buildSettingsUpdateSection(
                        i18n: i18n,
                        settings: settings,
                        cs: cs,
                        updateInfo: updateInfo,
                        currentVersion: currentVersion,
                        onOpenPermissionCenter: onOpenPermissionCenter,
                        onCheckForUpdates: onCheckForUpdates,
                      ),
                    ),
                  ),
                ],
                _SettingsCategory.about => const <Widget>[],
              },
            ),
          ),
        ],
      );
    }

    final headerHeight =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.padding.vertical +
        AppPageHeaderMetrics.contentHeight +
        AppPageHeaderMetrics.bottomSpacing;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: content(
              topPadding:
                  headerHeight + AppPageHeaderMetrics.firstContentSpacing,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              icon: category.icon,
              title: i18n.tr(category.labelKey),
              leading: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
                tooltip: i18n.tr('back'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
