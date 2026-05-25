import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      height: 32,
      color: cs.surface,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (details) {
                windowManager.startDragging();
              },
              child: const SizedBox.expand(),
            ),
          ),
          WindowCaption(
            brightness: isDark ? Brightness.dark : Brightness.light,
            backgroundColor: Colors.transparent,
          ),
        ],
      ),
    );
  }
}
