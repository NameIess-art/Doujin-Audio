import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

const _windowsTitleBarIconColor = Color(0xFFC94D63);

class WindowsTitleBar extends StatelessWidget {
  const WindowsTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 40,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            if (constraints.maxWidth >= 420) ...[
              const SizedBox(width: 20),
              const Icon(
                Icons.graphic_eq_rounded,
                size: 18,
                color: _windowsTitleBarIconColor,
              ),
              const SizedBox(width: 10),
              Text(
                'Nameless Audio',
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (details) {
                  windowManager.startDragging();
                },
                child: const SizedBox.expand(),
              ),
            ),
            SizedBox(
              width: 138,
              height: 40,
              child: WindowCaption(
                brightness: isDark ? Brightness.dark : Brightness.light,
                backgroundColor: Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
