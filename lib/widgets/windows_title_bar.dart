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
      color: Colors.transparent,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Icon(
            Icons.graphic_eq_rounded,
            size: 16,
            color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8),
          ),
          const SizedBox(width: 8),
          Text(
            'Nameless Audio',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
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
