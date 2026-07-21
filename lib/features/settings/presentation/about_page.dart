import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../app/theme/app_styles.dart';
import '../../../core/widgets/app_brand_icon.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/top_page_header.dart';
import '../application/app_update_service.dart';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key, required this.versionFuture});

  final Future<AppVersionInfo> versionFuture;

  static const _repositoryUrl = AppUpdateService.repositoryPage;
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final tokens = AppDesignTokens.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                tokens.pageHorizontalPadding,
                104,
                tokens.pageHorizontalPadding,
                bottomInset + AppSpacing.xl,
              ),
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
                      onTap: () => unawaited(_openRepository(context, ref)),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    _AboutLinkTile(
                      icon: Icons.menu_book_outlined,
                      title: i18n.tr('about_wiki'),
                      onTap: () => unawaited(_openRepository(context, ref)),
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
                      title: Text(
                        i18n.tr('about_author'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      trailing: const Text(
                        'NameIess-art',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: () => unawaited(_openSponsor(context, ref)),
                        icon: const Icon(Icons.favorite_border_rounded),
                        label: Text(
                          i18n.tr('about_reward'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              leading: BackButton(
                color: Theme.of(context).colorScheme.onSurface,
              ),
              title: i18n.tr('about'),
              padding: const EdgeInsets.fromLTRB(8, 6, 16, 0),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(children: children),
    );
  }
}

class _AboutIdentity extends StatelessWidget {
  const _AboutIdentity();

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.lg,
        top: AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      child: Row(
        children: [
          const AppBrandIcon(size: 84),
          const SizedBox(width: AppSpacing.md),
          Flexible(
            child: Text(
              i18n.tr('app_title'),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                fontSize: 32,
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
    return ListTile(
      leading: _AboutIconContainer(icon: icon),
      title: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      trailing: Icon(
        Icons.open_in_new_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
    );
  }
}

class _AboutVersionTile extends StatelessWidget {
  const _AboutVersionTile({required this.versionFuture});

  final Future<AppVersionInfo> versionFuture;

  @override
  Widget build(BuildContext context) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return ListTile(
      leading: const _AboutIconContainer(icon: Icons.info_outline_rounded),
      title: Text(
        i18n.tr('about_version'),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      trailing: FutureBuilder<AppVersionInfo>(
        future: versionFuture,
        builder: (context, snapshot) => Text(
          snapshot.data?.versionName ?? '...',
          softWrap: true,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
    );
  }
}

class _AboutIconContainer extends StatelessWidget {
  const _AboutIconContainer({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return Container(
      width: tokens.iconContainerSize,
      height: tokens.iconContainerSize,
      alignment: Alignment.center,
      child: Icon(icon, color: cs.primary),
    );
  }
}
