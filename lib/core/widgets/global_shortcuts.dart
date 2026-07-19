import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/state/app_runtime_providers.dart';

class TogglePlayPauseIntent extends Intent {
  const TogglePlayPauseIntent();
}

class GlobalShortcuts extends ConsumerWidget {
  final Widget child;

  const GlobalShortcuts({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
}
