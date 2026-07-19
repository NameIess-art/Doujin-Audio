import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../application/app_cache_service.dart';
import '../application/settings_command_controller.dart';
import '../application/app_update_service.dart';
import '../application/settings_repository.dart';
import '../application/settings_state.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/card_info_field.dart';
import '../../../core/platform/permission_action_controller.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../app/theme/theme_provider.dart';
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
  const SettingsTab({super.key});

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
  late Future<AppVersionInfo> _appVersionFuture;
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  late final AppUpdateFlow _updateFlow = AppUpdateFlow(
    permissionController: _permissionActionController,
    languageProvider: ref.read(appLanguageProviderInstanceProvider),
    updateService: ref.read(appUpdateServiceProvider),
  );

  final ScrollController _scrollController = ScrollController();

  @override
  int get tabIndex => 3;

  @override
  double get defaultHeaderHeight => 62.0;

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
    _appVersionFuture = ref.read(appUpdateServiceProvider).currentAppVersion();
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
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
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        child: AboutPage(versionFuture: _appVersionFuture),
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

    return ScrollActivityGate(
      child: Stack(
        children: [
          Positioned(
            top: headerHeight - 80,
            bottom: 0,
            left: 0,
            right: 0,
            child: ListView(
              controller: _scrollController,
              // Offset top padding since Positioned already shifts it.
              // Expand internal padding by 80px to match the expanded Positioned bounds.
              padding: EdgeInsets.fromLTRB(16, 80 + 4, 16, bottomInset),
              clipBehavior: Clip.none,
              children: [
                _SettingsTileTheme(
                  child: Column(
                    children: [
                      for (final category in _SettingsCategory.values)
                        _SettingsCategoryTile(
                          category: category,
                          i18n: i18n,
                          onTap: () => _openSettingsCategory(category),
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
              icon: Icons.tune_rounded,
              title: i18n.tr('settings'),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              collapseController: _scrollController,
              bottomSpacing: 16,
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
        child: _SettingsCategoryPage(
          category: category,
          updateInfoListenable: _updateInfoNotifier,
          currentVersion: _appVersionFuture,
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
  language('section_language', Icons.language_rounded),
  common('section_common', Icons.tune_rounded),
  appearance('section_appearance', Icons.palette_outlined),
  playback('section_playback', Icons.play_circle_outline_rounded),
  asmrDownload('section_asmr_download', Icons.download_rounded),
  dataStorage('section_data_storage', Icons.storage_rounded),
  updatesPermissions(
    'section_updates_permissions',
    Icons.system_update_alt_rounded,
  ),
  about('about', Icons.info_outline_rounded);

  const _SettingsCategory(this.labelKey, this.icon);

  final String labelKey;
  final IconData icon;
}

class _SettingsCategoryTile extends StatelessWidget {
  const _SettingsCategoryTile({
    required this.category,
    required this.i18n,
    required this.onTap,
  });

  final _SettingsCategory category;
  final AppLanguageProvider i18n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _SettingsGroupCard(
        children: [
          ListTile(
            onTap: onTap,
            leading: _settingsIcon(category.icon, cs.onSurface),
            title: _settingsTitle(i18n.tr(category.labelKey)),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: cs.onSurfaceVariant,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 4,
            ),
          ),
        ],
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

    Widget content() {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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

    return Scaffold(
      backgroundColor: cs.surface,
      body: Column(
        children: [
          TopPageHeader(
            icon: category.icon,
            title: i18n.tr(category.labelKey),
            leading: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: i18n.tr('back'),
            ),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            bottomSpacing: 16,
          ),
          Expanded(child: content()),
        ],
      ),
    );
  }
}
