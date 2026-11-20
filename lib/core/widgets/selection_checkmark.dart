import 'package:flutter/material.dart';

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
              color: const Color(0xFF4CAF50),
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
