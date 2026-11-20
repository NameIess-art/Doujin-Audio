import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_buttons.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/platform/platform_channels.dart';
import '../state/app_runtime_providers.dart';
import '../../core/widgets/app_brand_icon.dart';
import '../localization/app_language_provider.dart';
import '../theme/app_styles.dart';

Future<void> _runWindowCommand(
  Future<void> Function(WindowsWindowCommand) runCommand,
  WindowsWindowCommand command,
) async {
  try {
    await runCommand(command);
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
class WindowsWindowDragArea extends ConsumerWidget {
  const WindowsWindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runCommand = ref.watch(windowsWindowControlsProvider).runCommand;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) =>
          unawaited(_runWindowCommand(runCommand, WindowsWindowCommand.drag)),
      onDoubleTap: () => unawaited(
        _runWindowCommand(runCommand, WindowsWindowCommand.toggleMaximized),
      ),
      child: child,
    );
  }
}

class WindowsWindowTitleBar extends ConsumerWidget {
  const WindowsWindowTitleBar({super.key, required this.language});

  static const double height = 30.0;

  final AppLanguageProvider language;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(windowsWindowControlsProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    Widget button(WindowsWindowCommand command, String label, IconData icon) {
      final isClose = command == WindowsWindowCommand.close;
      const closeHoverColor = Color(0xFFC42B1C);
      const closePressColor = Color(0xFFB3261E);
      final captionHoverColor = colors.onSurface.withValues(
        alpha: isDark ? 0.10 : 0.07,
      );
      final captionPressColor = colors.onSurface.withValues(
        alpha: isDark ? 0.16 : 0.12,
      );
      return IconButton(
        tooltip: language.tr(label),
        onPressed: () =>
            unawaited(_runWindowCommand(controls.runCommand, command)),
        icon: Icon(icon, size: 16),
        style: appIconButtonStyle(
          IconButton.styleFrom(
            padding: EdgeInsets.zero,
            fixedSize: const Size(46, 30),
            minimumSize: const Size(46, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.standard,
            shape: const RoundedRectangleBorder(),
          ).copyWith(
            animationDuration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 130),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return Colors.transparent;
              }
              if (states.contains(WidgetState.pressed)) {
                return isClose ? closePressColor : captionPressColor;
              }
              if (states.contains(WidgetState.hovered)) {
                return isClose ? closeHoverColor : captionHoverColor;
              }
              return Colors.transparent;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.onSurface.withValues(alpha: 0.38);
              }
              if (isClose &&
                  (states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.pressed))) {
                return Colors.white;
              }
              return colors.onSurface;
            }),
          ),
          null,
          false,
        ),
      );
    }

    final titleBarColor = landscapeNavigationBackground(colors);
    final showPureBlackDivider = isDark && titleBarColor == colors.surface;
    return SizedBox(
      height: height,
      child: Material(
        color: titleBarColor,
        child: DecoratedBox(
          decoration: showPureBlackDivider
              ? BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: 0.22),
                    ),
                  ),
                )
              : const BoxDecoration(),
          child: Row(
            children: [
              Expanded(
                child: WindowsWindowDragArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Image.asset(appBrandIconAsset, width: 16, height: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            language.tr('app_title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ExcludeFocus(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    button(
                      WindowsWindowCommand.minimize,
                      'window_minimize',
                      Icons.remove,
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: controls.maximized,
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
            ],
          ),
        ),
      ),
    );
  }
}
