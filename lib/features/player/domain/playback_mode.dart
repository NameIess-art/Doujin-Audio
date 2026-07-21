enum SessionLoopMode {
  single,
  crossRandom,
  folderSequential,
  crossSequential,
  folderRandom,
  folderOnce,
  crossOnce,
}

enum TimerMode { manual, trigger }

extension SessionLoopModeExtension on SessionLoopMode {
  bool get isShuffle =>
      this == SessionLoopMode.crossRandom ||
      this == SessionLoopMode.folderRandom;

  bool get isOneShot =>
      this == SessionLoopMode.folderOnce || this == SessionLoopMode.crossOnce;

  bool get isCrossFolder =>
      this == SessionLoopMode.crossRandom ||
      this == SessionLoopMode.crossSequential ||
      this == SessionLoopMode.crossOnce;

  SessionLoopMode get nextOrderMode {
    if (isShuffle) {
      return isCrossFolder
          ? SessionLoopMode.crossSequential
          : SessionLoopMode.folderSequential;
    }
    if (isOneShot) {
      return isCrossFolder
          ? SessionLoopMode.crossRandom
          : SessionLoopMode.folderRandom;
    }
    return isCrossFolder
        ? SessionLoopMode.crossOnce
        : SessionLoopMode.folderOnce;
  }

  SessionLoopMode get toggledScopeMode {
    if (isCrossFolder) {
      if (isShuffle) return SessionLoopMode.folderRandom;
      if (isOneShot) return SessionLoopMode.folderOnce;
      return SessionLoopMode.folderSequential;
    }
    if (isShuffle) return SessionLoopMode.crossRandom;
    if (isOneShot) return SessionLoopMode.crossOnce;
    return SessionLoopMode.crossSequential;
  }

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
      case SessionLoopMode.folderOnce:
        return 'Sequential play (current folder)';
      case SessionLoopMode.crossOnce:
        return 'Sequential play (cross-folder)';
    }
  }
}
