import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/windows_desktop_service.dart';
import '../../features/player/presentation/playback_providers.dart';
import '../state/app_runtime_providers.dart';

class TogglePlayPauseIntent extends Intent {
  const TogglePlayPauseIntent();
}

class GlobalShortcuts extends ConsumerWidget {
  const GlobalShortcuts({
    super.key,
    required this.child,
    this.enabled = true,
    this.navigatorKey,
  });

  final Widget child;
  final bool enabled;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return Focus(
        autofocus: true,
        onKeyEvent: (_, event) => _handleWindowsKey(context, ref, event),
        child: child,
      );
    }
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.space): const TogglePlayPauseIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          TogglePlayPauseIntent: CallbackAction<TogglePlayPauseIntent>(
            onInvoke: (TogglePlayPauseIntent intent) {
              final playback = ref.read(playbackFacadeProvider);
              final state = ref.read(playbackStateProvider).value;
              if (state != null && state.activeSessions.isNotEmpty) {
                playback.toggleSessionPlayPause(state.activeSessions.first.id);
              }
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }

  KeyEventResult _handleWindowsKey(
    BuildContext context,
    WidgetRef ref,
    KeyEvent event,
  ) {
    if (!enabled || event is! KeyDownEvent) return KeyEventResult.ignored;
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
    if (!control && !alt && key == LogicalKeyboardKey.f1) {
      unawaited(_showHelp(routeContext, ref));
      return KeyEventResult.handled;
    }
    if (!control && !alt && key == LogicalKeyboardKey.escape) {
      final navigator =
          navigatorKey?.currentState ?? Navigator.maybeOf(routeContext);
      if (navigator == null || !navigator.canPop()) {
        return KeyEventResult.ignored;
      }
      unawaited(navigator.maybePop());
      return KeyEventResult.handled;
    }
    if (focusContext?.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored;
    }
    final toggle = !alt && key == LogicalKeyboardKey.space;
    final skip =
        control &&
        !alt &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight);
    final seek =
        alt &&
        !control &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight);
    final volume =
        alt &&
        !control &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown);
    if (!toggle && !skip && !seek && !volume) {
      return KeyEventResult.ignored;
    }
    if (toggle && !control && focusContext != null) {
      final action = Actions.maybeFind<ActivateIntent>(focusContext);
      if (action != null) {
        // Let Material's normal space shortcut activate the focused control.
        return KeyEventResult.ignored;
      }
    }
    final notifications = ref.read(notificationFacadeProvider);
    if (toggle) {
      unawaited(notifications.togglePrimarySessionPlayPause());
    } else if (skip) {
      unawaited(
        key == LogicalKeyboardKey.arrowRight
            ? notifications.skipPrimarySessionToNext()
            : notifications.skipPrimarySessionToPrevious(),
      );
    } else {
      final session = notifications.notificationActionSession;
      if (session == null) return KeyEventResult.handled;
      if (seek) {
        unawaited(
          notifications.seekPrimarySession(
            session.position +
                Duration(
                  seconds: key == LogicalKeyboardKey.arrowRight ? 5 : -5,
                ),
          ),
        );
      } else {
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
    }
    return KeyEventResult.handled;
  }

  Future<void> _showHelp(BuildContext context, WidgetRef ref) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.tr('keyboard_shortcuts_title')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(i18n.tr('keyboard_shortcuts_local')),
                const SizedBox(height: 16),
                Text(i18n.tr('keyboard_shortcuts_global')),
                FutureBuilder<Map<String, bool>>(
                  future: WindowsDesktopService.instance.getHotkeyStatus(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(
                        '${i18n.tr('keyboard_shortcuts_status_error')}: ${snapshot.error}',
                      );
                    }
                    if (!snapshot.hasData) {
                      return const LinearProgressIndicator();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final entry in const {
                          'toggle': 'Ctrl + Alt + Space',
                          'previous': 'Ctrl + Alt + ←',
                          'next': 'Ctrl + Alt + →',
                          'showWindow': 'Ctrl + Alt + ↑',
                        }.entries)
                          Text(
                            '${entry.value}: ${i18n.tr(snapshot.data![entry.key] == true ? 'keyboard_shortcuts_registered' : 'keyboard_shortcuts_unavailable')}',
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.tr('close')),
          ),
        ],
      ),
    );
  }
}
