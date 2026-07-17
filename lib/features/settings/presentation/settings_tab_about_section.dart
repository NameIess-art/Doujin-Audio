part of 'settings_tab.dart';

List<Widget> _buildSettingsAboutSection({
  required AppLanguageProvider i18n,
  required TextStyle? descStyle,
  required VoidCallback onOpenAbout,
}) {
  return [
    _SectionHeader(title: i18n.tr('about')),
    _SettingsGroupCard(
      children: [
        ListTile(
          leading: const _SettingsAboutIconContainer(icon: Icons.info_outline),
          title: Text(i18n.tr('about')),
          subtitle: Text(i18n.tr('about_subtitle'), style: descStyle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onOpenAbout,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 2,
          ),
        ),
      ],
    ),
  ];
}

class _SettingsAboutIconContainer extends StatelessWidget {
  const _SettingsAboutIconContainer({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return Container(
      width: tokens.iconContainerSize,
      height: tokens.iconContainerSize,
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: cs.onPrimaryContainer),
    );
  }
}
