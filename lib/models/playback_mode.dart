enum SessionLoopMode {
  single,
  crossRandom,
  folderSequential,
  crossSequential,
  folderRandom,
}

enum TimerMode { manual, trigger }

extension SessionLoopModeExtension on SessionLoopMode {
  String get label {
    switch (this) {
      case SessionLoopMode.single:
        return 'Single loop';
      case SessionLoopMode.crossRandom:
        return 'Shuffle (cross-folder)';
      case SessionLoopMode.folderSequential:
        return 'Sequential (current folder)';
      case SessionLoopMode.crossSequential:
        return 'Sequential (cross-folder)';
      case SessionLoopMode.folderRandom:
        return 'Shuffle (current folder)';
    }
  }
}
