import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/audio_provider_riverpod.dart';
import '../providers/audio_provider.dart';

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
              final provider = ref.read(audioProviderFacadeProvider);
              final state = ref.read(playbackStateProvider).valueOrNull;
              if (state != null && state.activeSessions.isNotEmpty) {
                provider.toggleSessionPlayPause(state.activeSessions.first.id);
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: child,
        ),
      ),
    );
  }
}
