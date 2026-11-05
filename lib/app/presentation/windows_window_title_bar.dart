import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/platform/windows_desktop_service.dart';
import '../../core/widgets/app_brand_icon.dart';
import '../localization/app_language_provider.dart';
import '../theme/app_styles.dart';

Future<void> _runWindowCommand(
  WindowsDesktopService desktop,
  WindowsWindowCommand command,
) async {
  try {
    await desktop.runWindowCommand(command);
  } catch (error, stackTrace) {
    AppLogService.warning(
      'windows_window_command_failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Moves the window like the caption when its area is dragged. Place it behind
/// interactive content so only otherwise unhandled space receives the input.
class WindowsWindowDragArea extends StatelessWidget {
  const WindowsWindowDragArea({
    super.key,
    required this.desktop,
    required this.child,
  });

  final WindowsDesktopService desktop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) =>
          unawaited(_runWindowCommand(desktop, WindowsWindowCommand.drag)),
      onDoubleTap: () => unawaited(
        _runWindowCommand(desktop, WindowsWindowCommand.toggleMaximized),
      ),
      child: child,
    );
  }
}

class WindowsWindowTitleBar extends StatelessWidget {
  const WindowsWindowTitleBar({
    super.key,
    required this.desktop,
    required this.language,
  });

  static const double height = 30.0;

  final WindowsDesktopService desktop;
  final AppLanguageProvider language;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget button(WindowsWindowCommand command, String label, IconData icon) {
      return IconButton(
        tooltip: language.tr(label),
        onPressed: () => unawaited(_runWindowCommand(desktop, command)),
        icon: Icon(icon, size: 16),
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          fixedSize: const Size(46, 30),
          minimumSize: const Size(46, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: const RoundedRectangleBorder(),
          foregroundColor: colors.onSurface,
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Material(
        color: landscapeNavigationBackground(colors),
        child: Row(
          children: [
            Expanded(
              child: WindowsWindowDragArea(
                desktop: desktop,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Image.asset(appBrandIconAsset, width: 16, height: 16),
                      const SizedBox(width: 6),
                      Text(language.tr('app_title')),
                    ],
                  ),
                ),
              ),
            ),
            button(WindowsWindowCommand.minimize, 'window_minimize', Icons.remove),
            ValueListenableBuilder<bool>(
              valueListenable: desktop.maximized,
              builder: (context, maximized, _) => button(
                WindowsWindowCommand.toggleMaximized,
                maximized ? 'window_restore' : 'window_maximize',
                maximized ? Icons.filter_none : Icons.crop_square,
              ),
            ),
            button(WindowsWindowCommand.close, 'close', Icons.close),
          ],
        ),
      ),
    );
  }
}
