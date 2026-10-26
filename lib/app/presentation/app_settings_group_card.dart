import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

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
      children: [
        for (var index = 0; index < children.length; index++)
          AppSettingsCard(
            isFirst: index == 0,
            isLast: index == children.length - 1,
            bottomSpacing: index == children.length - 1 ? 0 : 3,
            child: children[index],
          ),
      ],
    );
  }
}

class AppSettingsCard extends StatelessWidget {
  const AppSettingsCard({
    super.key,
    required this.child,
    required this.isFirst,
    required this.isLast,
    this.bottomSpacing,
  });

  final Widget child;
  final bool isFirst;
  final bool isLast;
  final double? bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppDesignTokens.of(context);
    final outerRadius = tokens.radiusCard;
    const innerRadius = 6.0;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(isFirst ? outerRadius : innerRadius),
        topRight: Radius.circular(isFirst ? outerRadius : innerRadius),
        bottomLeft: Radius.circular(isLast ? outerRadius : innerRadius),
        bottomRight: Radius.circular(isLast ? outerRadius : innerRadius),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing ?? (isLast ? 0 : 3)),
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
        child: ListTileTheme.merge(
          shape: shape,
          child: child,
        ),
      ),
    );
  }
}
