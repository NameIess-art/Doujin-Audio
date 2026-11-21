import 'package:flutter/material.dart';

import '../../app/theme/app_design_tokens.dart';
import 'app_transitions.dart';

class SelectionCheckmark extends StatelessWidget {
  const SelectionCheckmark({
    super.key,
    required this.indicatorKey,
    required this.isSelected,
  });

  final Key indicatorKey;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = AppDesignTokens.of(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AppDeferredFade(
          visible: isSelected,
          beginScale: 0.86,
          fadeInDuration: kAppMotionFast,
          child: Container(
            key: indicatorKey,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tokens.success,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 2,
              ),
            ),
            child: Icon(
              Icons.check_rounded,
              size: 14,
              color: tokens.onSuccess,
            ),
          ),
        ),
      ),
    );
  }
}
