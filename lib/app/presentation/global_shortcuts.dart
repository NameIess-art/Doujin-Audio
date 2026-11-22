import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_buttons.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../features/player/presentation/playback_providers.dart';
import '../state/app_runtime_providers.dart';
import 'work_detail_navigation.dart';

class TogglePlayPauseIntent extends Intent {
  const TogglePlayPauseIntent();
}

class _TogglePlayPauseAction extends Action<TogglePlayPauseIntent> {
  _TogglePlayPauseAction({required this.enabled, required this.ref});

  final bool enabled;
  final WidgetRef ref;

  @override
  bool isEnabled(TogglePlayPauseIntent intent) {
    if (!enabled) return false;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null) {
      if (focusContext.findAncestorStateOfType<EditableTextState>() != null) {
        return false;
      }
      if (Actions.maybeFind<ActivateIntent>(focusContext) != null) {
        return false;
      }
      final modalRoute = ModalRoute.of(focusContext);
      if (modalRoute != null && modalRoute is! PageRoute<dynamic>) {
        return false;
      }
    }
    return ref.read(focusedPlaybackSessionProvider) != null;
  }

  @override
  Object? invoke(TogglePlayPauseIntent intent) {
    final session = ref.read(focusedPlaybackSessionProvider);
    if (session != null) {
      unawaited(
        ref
            .read(notificationFacadeProvider)
            .toggleSessionPlayback(session.id),
      );
    }
    return null;
  }
}

class GlobalShortcuts extends ConsumerWidget {
  const GlobalShortcuts({
    super.key,
    required this.child,
    this.enabled = true,
    this.navigatorKey,
    this.navigationAllowed,
  });

  final Widget child;
  final bool enabled;
  final GlobalKey<NavigatorState>? navigatorKey;
  final ValueListenable<bool>? navigationAllowed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final shortcuts = Focus(
        autofocus: true,
        onKeyEvent: (_, event) => _handleWindowsKey(context, ref, event),
        child: child,
      );
      return navigationAllowed == null
          ? shortcuts
          : AppNavigationInputLock(
              navigationAllowed: navigationAllowed!,
              onLockedKeyEvent: (event) => _handleWindowsKey(
                context,
                ref,
                event,
                allowNavigation: false,
              ),
              child: shortcuts,
            );
    }
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.space): const TogglePlayPauseIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          TogglePlayPauseIntent: _TogglePlayPauseAction(
            enabled: enabled,
            ref: ref,
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }

  KeyEventResult _handleBackNavigation(
    BuildContext context,
    BuildContext routeContext,
    BuildContext? focusContext,
  ) {
    final navigator =
        navigatorKey?.currentState ?? Navigator.maybeOf(routeContext);
    if (navigator != null && navigator.canPop()) {
      unawaited(navigator.maybePop());
      return KeyEventResult.handled;
    }
    final detail = WorkDetailNavigationScope.maybeOf(context);
    final dismissMenu = detail?.menuDismiss.value;
    if (dismissMenu != null) {
      dismissMenu();
      return KeyEventResult.handled;
    }
    final preferred = detail?.preferredBackNavigator(focusContext);
    if (preferred != null && preferred.canPop()) {
      unawaited(preferred.maybePop());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _hasModalOrMenuActive(BuildContext context, BuildContext? focusContext) {
    if (_isHelpOpen) return true;
    if (WorkDetailNavigationScope.maybeOf(context)?.menuDismiss.value != null) {
      return true;
    }
    if (focusContext != null) {
      final modalRoute = ModalRoute.of(focusContext);
      if (modalRoute != null && modalRoute is! PageRoute<dynamic>) {
        return true;
      }
    }
    return false;
  }

  bool _focusHandlesArrowKey(
    BuildContext rootContext,
    BuildContext? focusContext, {
    required bool vertical,
  }) {
    if (focusContext == null) return false;
    final scrollable = Scrollable.maybeOf(focusContext);
    if (scrollable != null) {
      final isVerticalScroll =
          axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical;
      if (isVerticalScroll == vertical) return true;
    }
    final localScroll = Actions.maybeFind<ScrollIntent>(focusContext);
    final rootScroll = Actions.maybeFind<ScrollIntent>(rootContext);
    if (localScroll != null && !identical(localScroll, rootScroll)) {
      return true;
    }
    final localDirectional = Actions.maybeFind<DirectionalFocusIntent>(
      focusContext,
    );
    final rootDirectional = Actions.maybeFind<DirectionalFocusIntent>(
      rootContext,
    );
    if (localDirectional != null &&
        !identical(localDirectional, rootDirectional)) {
      return true;
    }
    return false;
  }

  KeyEventResult _handleWindowsKey(
    BuildContext context,
    WidgetRef ref,
    KeyEvent event, {
    bool allowNavigation = true,
  }) {
    final isRepeat = event is KeyRepeatEvent;
    if (!enabled || (event is! KeyDownEvent && !isRepeat)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final routeContext =
        navigatorKey?.currentState?.overlay?.context ?? focusContext ?? context;
    final key = event.logicalKey;
    final control = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    if (!isRepeat &&
        allowNavigation &&
        !control &&
        !alt &&
        key == LogicalKeyboardKey.f1) {
      if (!_isHelpOpen) {
        unawaited(showHelp(routeContext, ref));
      }
      return KeyEventResult.handled;
    }
    if (!isRepeat && allowNavigation) {
      final isEscape = !control && !alt && key == LogicalKeyboardKey.escape;
      final isBrowserBack =
          (!control && alt && key == LogicalKeyboardKey.arrowLeft) ||
          (!control && !alt && key == LogicalKeyboardKey.browserBack);
      if (isEscape || isBrowserBack) {
        return _handleBackNavigation(context, routeContext, focusContext);
      }
    }
    if (focusContext?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    final toggle = !isRepeat && !alt && key == LogicalKeyboardKey.space;
    final skip =
        !isRepeat &&
        control &&
        !alt &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight);
    final seek =
        !alt &&
        !control &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight);
    final volume =
        !alt &&
        !control &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown);
    if (!toggle && !skip && !seek && !volume) {
      return KeyEventResult.ignored;
    }
    final isPlainShortcut = !control && !alt;
    if (isPlainShortcut && _hasModalOrMenuActive(context, focusContext)) {
      return KeyEventResult.ignored;
    }
    if (toggle && !control && focusContext != null) {
      final action = Actions.maybeFind<ActivateIntent>(focusContext);
      if (action != null) {
        // Let Material's normal space shortcut activate the focused control.
        return KeyEventResult.ignored;
      }
    }
    if ((seek || volume) &&
        _focusHandlesArrowKey(context, focusContext, vertical: volume)) {
      return KeyEventResult.ignored;
    }
    final session = ref.read(focusedPlaybackSessionProvider);
    if (session == null) {
      return KeyEventResult.ignored;
    }
    final notifications = ref.read(notificationFacadeProvider);
    if (toggle) {
      unawaited(notifications.toggleSessionPlayback(session.id));
    } else if (skip) {
      unawaited(
        key == LogicalKeyboardKey.arrowRight
            ? notifications.skipSessionToNext(session.id)
            : notifications.skipSessionToPrevious(session.id),
      );
    } else if (seek) {
      final offset = key == LogicalKeyboardKey.arrowRight
          ? const Duration(seconds: 5)
          : const Duration(seconds: -5);
      unawaited(notifications.seekSessionByOffset(session.id, offset));
    } else if (volume) {
      unawaited(
        ref
            .read(playbackFacadeProvider)
            .setSessionVolume(
              session.id,
              session.volume +
                  (key == LogicalKeyboardKey.arrowUp ? 0.05 : -0.05),
            ),
      );
    }
    return KeyEventResult.handled;
  }

  static bool _isHelpOpen = false;

  static Future<void> showHelp(BuildContext context, WidgetRef ref) async {
    if (_isHelpOpen) return;
    _isHelpOpen = true;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    try {
      await showAppDialog<void>(
        context: context,
        maxWidth: 680,
        builder: (context) {
          final theme = Theme.of(context);
          void closeHelp() {
            if (readAppRoute(context)?.isCurrent == true) {
              Navigator.of(context).pop();
            }
          }

          TableRow row(String keys, String action, {String? status}) {
            return TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                  child: Text(
                    keys,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(action, style: theme.textTheme.bodyMedium),
                      if (status != null)
                        Text(
                          status,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          }

          Widget table(List<TableRow> rows) => Table(
            columnWidths: const {
              0: FractionColumnWidth(0.4),
              1: FlexColumnWidth(),
            },
            children: [
              row(
                i18n.tr('keyboard_shortcuts_key'),
                i18n.tr('keyboard_shortcuts_action'),
              ),
              ...rows,
            ],
          );

          return CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.f1,
                includeRepeats: false,
              ): closeHelp,
            },
            child: AppDialog(
              title: i18n.tr('keyboard_shortcuts_title'),
              icon: Icons.keyboard_rounded,
              content: SizedBox(
                width: 620,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        i18n.tr('keyboard_shortcuts_local'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      table([
                        for (final (keys, action) in [
                          ('Space / Ctrl + Space', 'toggle'),
                          ('Ctrl + ← / →', 'skip'),
                          ('← / →', 'seek'),
                          ('↑ / ↓', 'volume'),
                          ('Ctrl + 1–5 / Ctrl + Tab', 'tabs'),
                          ('Tab / Shift + Tab', 'focus'),
                          ('Enter / Space', 'activate'),
                          (i18n.tr('keyboard_shortcuts_arrows'), 'adjust'),
                          ('Esc / Alt + ←', 'back'),
                          ('F1', 'help'),
                        ])
                          row(keys, i18n.tr('keyboard_shortcuts_$action')),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        i18n.tr('keyboard_shortcuts_editing'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        i18n.tr('keyboard_shortcuts_global'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Consumer(
                        builder: (context, ref, _) {
                          final status = ref.watch(windowsHotkeyStatusProvider);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              table([
                                for (final (id, keys, action) in const [
                                  (
                                    'toggle',
                                    'Ctrl + Alt + Space',
                                    'keyboard_shortcuts_toggle',
                                  ),
                                  (
                                    'previous',
                                    'Ctrl + Alt + ←',
                                    'previous_track',
                                  ),
                                  ('next', 'Ctrl + Alt + →', 'next_track'),
                                  (
                                    'showWindow',
                                    'Ctrl + Alt + ↑',
                                    'keyboard_shortcuts_show_window',
                                  ),
                                ])
                                  row(
                                    keys,
                                    i18n.tr(action),
                                    status: status.value == null
                                        ? null
                                        : i18n.tr(
                                            status.value![id] == true
                                                ? 'keyboard_shortcuts_registered'
                                                : 'keyboard_shortcuts_unavailable',
                                          ),
                                  ),
                              ]),
                              if (status.isLoading)
                                const LinearProgressIndicator()
                              else if (status.hasError)
                                Text(
                                  i18n.tr('keyboard_shortcuts_status_error'),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ).withWindowsSmoothScroll(),
              ),
              actions: AppDialogActions(
                children: [
                  AppPrimaryButton(
                    autofocus: true,
                    onPressed: closeHelp,
                    label: i18n.tr('close'),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      _isHelpOpen = false;
    }
  }
}
