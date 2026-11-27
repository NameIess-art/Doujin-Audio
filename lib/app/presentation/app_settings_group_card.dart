import 'package:flutter/material.dart';

import '../theme/app_styles.dart';

class AppSettingsGroupCard extends StatelessWidget {
  const AppSettingsGroupCard({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 3,
      children: [
        for (final child in children) AppSettingsCard(child: child),
      ],
    );
  }
}

class AppSettingsCard extends StatelessWidget {
  const AppSettingsCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const shape = RoundedRectangleBorder(borderRadius: AppRadius.borderSmall);
    return Card(
      clipBehavior: Clip.antiAlias,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: shape,
      child: ListTileTheme.merge(shape: shape, child: child),
    );
  }
}
