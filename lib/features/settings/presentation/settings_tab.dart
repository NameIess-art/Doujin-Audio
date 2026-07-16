import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/audio_provider.dart';
import '../../../app/state/audio_provider_riverpod.dart';
import '../application/app_cache_service.dart';
import '../application/app_update_service.dart';
import '../../player/application/audio_state_services.dart';
import '../../../core/media/path_display.dart';
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
import '../../../app/state/subtitle_settings_provider.dart';
import '../../data_support/presentation/data_support_page.dart';
import 'permission_status_page.dart';
import 'app_update_flow.dart';
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
  AppUpdateInfo? _lastUpdateInfo;
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

  void _setLocalState(VoidCallback fn) => setState(fn);

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
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final audioProvider = ref.read(audioProviderFacadeProvider);
    final bottomInset = MobileOverlayInset.of(context);
    final cs = Theme.of(context).colorScheme;
    final descStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 11,
      height: 1.25,
      color: cs.onSurfaceVariant,
    );

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
              padding: EdgeInsets.fromLTRB(16, 80 + 4, 16, bottomInset + 24),
              clipBehavior: Clip.none,
              children: [
                ListTileTheme.merge(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  child: Column(
                    children: [
                      ..._buildSettingsGeneralSection(
                        i18n: i18n,
                        audioProvider: audioProvider,
                        descStyle: descStyle,
                        cs: cs,
                      ),
                      ..._buildSettingsAppearanceSection(
                        context: context,
                        i18n: i18n,
                        audioProvider: audioProvider,
                        descStyle: descStyle,
                        cs: cs,
                        onShowSubtitleWindowSettings: () =>
                            _showSubtitleWindowSettings(context),
                        onShowCardInfoFieldsSettings: () =>
                            _showCardInfoFieldsSettings(context),
                      ),
                      ..._buildSettingsPlaybackSection(
                        i18n: i18n,
                        audioProvider: audioProvider,
                        descStyle: descStyle,
                        cs: cs,
                      ),
                      ..._buildSettingsAsmrSection(
                        i18n: i18n,
                        audioProvider: audioProvider,
                        descStyle: descStyle,
                        cs: cs,
                        onChooseAsmrDownloadDestination:
                            _chooseAsmrDownloadDestination,
                      ),
                      ..._buildSettingsDataSection(
                        i18n: i18n,
                        audioProvider: audioProvider,
                        descStyle: descStyle,
                        cs: cs,
                        onOpenDataAndSupport: _openDataAndSupport,
                        onClearApplicationCache: () =>
                            _clearApplicationCache(context),
                      ),
                      ..._buildSettingsUpdateSection(
                        i18n: i18n,
                        audioProvider: audioProvider,
                        descStyle: descStyle,
                        cs: cs,
                        updateInfo: _lastUpdateInfo,
                        currentVersion: _appVersionFuture,
                        onOpenPermissionCenter: _openPermissionCenter,
                        onCheckForUpdates: () => _checkForUpdates(context),
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
}
