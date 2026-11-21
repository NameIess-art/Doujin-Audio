import 'settings_providers.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_entry_ink_well.dart';
import '../../../core/widgets/app_transitions.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_brand_icon.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../application/app_update_service.dart';
import 'settings_tile_theme.dart';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key, required this.versionFuture});

  final Future<AppVersionInfo> versionFuture;

  static const _repositoryUrl = AppUpdateService.repositoryPage;
  static const _feedbackPageUrl = '$_repositoryUrl/issues';
  static const _feedbackEmail = 'likenshonameless@gmail.com';
  static const _readmeUrl =
      'https://github.com/NameIess-art/Doujin-Audio/blob/main/README.md';
  static const _sponsorUrl =
      'https://ifdian.net/order/create?user_id=c6acfc3a646d11f0ae8a5254001e7c00';

  Future<void> _openRepository(BuildContext context, WidgetRef ref) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final opened = await ref
        .read(appUpdateServiceProvider)
        .openReleasePage(_repositoryUrl);
    if (!context.mounted || opened) return;
    showAppSnackBar(
      context,
      i18n.tr('about_wiki_open_failed'),
      tone: AppFeedbackTone.warning,
      icon: Icons.open_in_new_rounded,
    );
  }

  Future<void> _openFeedback(BuildContext context, WidgetRef ref) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final opened = await ref
        .read(appUpdateServiceProvider)
        .openReleasePage(
          isWindows ? _feedbackPageUrl : 'mailto:$_feedbackEmail',
        );
    if (!context.mounted || opened) return;
    final failureKey = isWindows
        ? 'about_feedback_page_open_failed'
        : 'about_feedback_open_failed';
    showAppSnackBar(
      context,
      '${i18n.tr(failureKey)} $_feedbackEmail',
      tone: AppFeedbackTone.warning,
      icon: Icons.mail_outline_rounded,
    );
  }

  Future<void> _openSponsor(BuildContext context, WidgetRef ref) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final opened = await ref
        .read(appUpdateServiceProvider)
        .openReleasePage(_sponsorUrl);
    if (!context.mounted || opened) return;
    showAppSnackBar(
      context,
      i18n.tr('about_reward_open_failed'),
      tone: AppFeedbackTone.warning,
      icon: Icons.open_in_new_rounded,
    );
  }

  Future<void> _openReadme(BuildContext context, WidgetRef ref) async {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final opened = await ref
        .read(appUpdateServiceProvider)
        .openReleasePage(_readmeUrl);
    if (!context.mounted || opened) return;
    showAppSnackBar(
      context,
      i18n.tr('about_wiki_open_failed'),
      tone: AppFeedbackTone.warning,
      icon: Icons.open_in_new_rounded,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + MobileOverlayInset.of(context);

    final contentTopInset = AppPageHeaderMetrics.contentTopInset(context);

    return Scaffold(
      backgroundColor: cs.surface,
      body: PageHeaderInset(
        topInset: contentTopInset,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    tokens.pageHorizontalPadding,
                    contentTopInset,
                    tokens.pageHorizontalPadding,
                    bottomInset + AppSpacing.xl,
                  ),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: tokens.readableContentMaxWidth,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _AboutCard(
                              children: [
                                const _AboutIdentity(),
                                const SizedBox(height: AppSpacing.lg),
                                _AboutVersionTile(versionFuture: versionFuture),
                                const SizedBox(height: AppSpacing.xs),
                                _AboutLinkTile(
                                  icon: Icons.code_rounded,
                                  title: i18n.tr('about_source_code'),
                                  onTap: () =>
                                      unawaited(_openRepository(context, ref)),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                _AboutLinkTile(
                                  icon: Icons.menu_book_outlined,
                                  title: i18n.tr('about_wiki'),
                                  onTap: () =>
                                      unawaited(_openReadme(context, ref)),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                _AboutLinkTile(
                                  icon: Icons.mail_outline_rounded,
                                  title: i18n.tr('about_feedback'),
                                  onTap: () =>
                                      unawaited(_openFeedback(context, ref)),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            _AboutCard(
                              children: [
                                ListTile(
                                  leading: const _AboutIconContainer(
                                    icon: Icons.person_outline_rounded,
                                  ),
                                  title: Text(i18n.tr('about_author')),
                                  trailing: Text(
                                    'NameIess-art',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontSize: SettingsTileTheme.titleFontSize,
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.xs,
                                  ),
                                  child: AppLabelledButton(
                                    OutlinedButton.icon,
                                    onPressed: () =>
                                        unawaited(_openSponsor(context, ref)),
                                    icon: const Icon(
                                      Icons.favorite_border_rounded,
                                      size: 24,
                                    ),
                                    label: Text(i18n.tr('about_reward')),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ).withWindowsSmoothScroll(),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.info_outline_rounded,
                leading: const AppHeaderBackButton(),
                title: i18n.tr('about'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: SettingsTileTheme(child: Column(children: children)),
      ),
    );
  }
}

class _AboutIdentity extends ConsumerWidget {
  const _AboutIdentity();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Column(
        children: [
          const AppBrandIcon(size: 104),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                i18n.tr('app_title'),
                maxLines: 1,
                softWrap: false,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  fontSize: 32,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutLinkTile extends StatelessWidget {
  const _AboutLinkTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tokens = AppDesignTokens.of(context);
    final rowRadius = BorderRadius.circular(tokens.radiusCard);

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: rowRadius),
      child: AppEntryInkWell(
        borderRadius: rowRadius,
        onTap: onTap,
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: rowRadius),
          leading: _AboutIconContainer(icon: icon),
          title: Text(title, style: TextStyle(color: cs.onSurface)),
          trailing: Icon(Icons.open_in_new_rounded, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _AboutVersionTile extends StatelessWidget {
  const _AboutVersionTile({required this.versionFuture});

  final Future<AppVersionInfo> versionFuture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return ListTile(
      leading: const _AboutIconContainer(icon: Icons.new_releases_outlined),
      title: Text(i18n.tr('about_version')),
      trailing: FutureBuilder<AppVersionInfo>(
        future: versionFuture,
        builder: (context, snapshot) => Text(
          snapshot.data?.versionName ?? '...',
          softWrap: true,
          textAlign: TextAlign.end,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: SettingsTileTheme.titleFontSize,
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _AboutIconContainer extends StatelessWidget {
  const _AboutIconContainer({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: SettingsTileTheme.leadingWidth,
      child: Icon(
        icon,
        color: cs.primary,
        size: AppDesignTokens.opticalIconSize(icon, SettingsTileTheme.iconSize),
      ),
    );
  }
}
