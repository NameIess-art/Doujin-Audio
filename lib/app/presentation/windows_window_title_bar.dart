import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_buttons.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/platform/platform_channels.dart';
import '../state/app_runtime_providers.dart';
import '../../core/widgets/app_brand_icon.dart';
import '../localization/app_language_en.dart';
import '../localization/app_language_ja.dart';
import '../localization/app_language_provider.dart';
import '../localization/app_language_zh.dart';
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
class WindowsWindowDragArea extends StatelessWidget {
  const WindowsWindowDragArea({
    super.key,
    required this.child,
    this.runCommand,
  });

  final Widget child;
  final Future<void> Function(WindowsWindowCommand)? runCommand;

  @override
  Widget build(BuildContext context) {
    final overrideCommand = runCommand;
    if (overrideCommand != null) {
      return _buildGesture(overrideCommand);
    }
    return Consumer(
      builder: (context, ref, _) =>
          _buildGesture(ref.watch(windowsWindowControlsProvider).runCommand),
    );
  }

  Widget _buildGesture(
    Future<void> Function(WindowsWindowCommand) commandRunner,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) =>
          unawaited(_runWindowCommand(commandRunner, WindowsWindowCommand.drag)),
      onDoubleTap: () => unawaited(
        _runWindowCommand(commandRunner, WindowsWindowCommand.toggleMaximized),
      ),
      child: child,
    );
  }
}

class WindowsWindowTitleBar extends StatelessWidget {
  const WindowsWindowTitleBar({super.key, this.language});

  static const double height = 32.0;

  final AppLanguageProvider? language;

  @override
  Widget build(BuildContext context) {
    final lang = language;
    if (lang != null) {
      return Consumer(
        builder: (context, ref, _) {
          ref.watch(appLanguageStateProvider);
          final controls = ref.watch(windowsWindowControlsProvider);
          return _buildBar(
            context,
            translate: lang.tr,
            runCommand: controls.runCommand,
            maximized: controls.maximized,
          );
        },
      );
    }
    final controls = defaultWindowsWindowControls();
    final languageCode = Localizations.maybeLocaleOf(context)?.languageCode;
    final strings = switch (languageCode) {
      'zh' => appLanguageZh,
      'ja' => appLanguageJa,
      _ => appLanguageEn,
    };
    return _buildBar(
      context,
      translate: (key) => strings[key] ?? appLanguageEn[key] ?? key,
      runCommand: controls.runCommand,
      maximized: controls.maximized,
    );
  }

  Widget _buildBar(
    BuildContext context, {
    required String Function(String key) translate,
    required Future<void> Function(WindowsWindowCommand) runCommand,
    required ValueListenable<bool> maximized,
  }) {
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
        tooltip: translate(label),
        onPressed: () => unawaited(_runWindowCommand(runCommand, command)),
        icon: Icon(icon, size: 16),
        style: appIconButtonStyle(
          IconButton.styleFrom(
            padding: EdgeInsets.zero,
            fixedSize: const Size(46, height),
            minimumSize: const Size(46, height),
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
                  runCommand: runCommand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        const AppBrandIcon(size: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            translate('app_title'),
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
                      valueListenable: maximized,
                      builder: (context, isMaximized, _) => button(
                        WindowsWindowCommand.toggleMaximized,
                        isMaximized ? 'window_restore' : 'window_maximize',
                        isMaximized ? Icons.filter_none : Icons.crop_square,
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

/// Hosts [WindowsWindowTitleBar] above a [Navigator] subtree while giving its
/// caption tooltips a full-window [Overlay] ancestor that stays separate from
/// the navigator's own root overlay.
class WindowsTitleBarShell extends StatelessWidget {
  const WindowsTitleBarShell({
    super.key,
    required this.child,
    this.language,
    this.hideTitleBar = false,
  });

  final Widget child;
  final AppLanguageProvider? language;
  final bool hideTitleBar;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            if (!hideTitleBar)
              const SizedBox(height: WindowsWindowTitleBar.height),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(size: constraints.biggest),
                  child: child,
                ),
              ),
            ),
          ],
        ),
        if (!hideTitleBar)
          Positioned.fill(
            child: Overlay.wrap(
              child: Align(
                alignment: Alignment.topCenter,
                child: WindowsWindowTitleBar(language: language),
              ),
            ),
          ),
      ],
    );
  }
}
