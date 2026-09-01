import 'package:flutter/material.dart';

class AppSettingsActionTile extends StatelessWidget {
  const AppSettingsActionTile({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.busy = false,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 40,
        child: Icon(icon, color: cs.onSurface, size: 30),
      ),
      title: Text(title, softWrap: true, overflow: TextOverflow.visible),
      trailing:
          trailing ??
          (busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }
}
