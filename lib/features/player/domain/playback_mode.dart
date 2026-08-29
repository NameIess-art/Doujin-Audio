enum SessionLoopMode {
  single,
  crossRandom,
  folderSequential,
  crossSequential,
  folderRandom,
  folderOnce,
  crossOnce,
  folderRandomOnce,
  crossRandomOnce,
}

enum TimerMode { manual, trigger }

extension SessionLoopModeExtension on SessionLoopMode {
  bool get isShuffle =>
      this == SessionLoopMode.crossRandom ||
      this == SessionLoopMode.folderRandom ||
      this == SessionLoopMode.folderRandomOnce ||
      this == SessionLoopMode.crossRandomOnce;

  bool get isOneShot =>
      this == SessionLoopMode.folderOnce ||
      this == SessionLoopMode.crossOnce ||
      this == SessionLoopMode.folderRandomOnce ||
      this == SessionLoopMode.crossRandomOnce;

  bool get isCrossFolder =>
      this == SessionLoopMode.crossRandom ||
      this == SessionLoopMode.crossSequential ||
      this == SessionLoopMode.crossOnce ||
      this == SessionLoopMode.crossRandomOnce;

  SessionLoopMode get nextOrderMode {
    if (isShuffle) {
      if (isOneShot) {
        return isCrossFolder
            ? SessionLoopMode.crossOnce
            : SessionLoopMode.folderOnce;
      }
      return isCrossFolder
          ? SessionLoopMode.crossSequential
          : SessionLoopMode.folderSequential;
    }
    if (isOneShot) {
      return isCrossFolder
          ? SessionLoopMode.crossRandomOnce
          : SessionLoopMode.folderRandomOnce;
    }
    return isCrossFolder
        ? SessionLoopMode.crossRandom
        : SessionLoopMode.folderRandom;
  }

  SessionLoopMode get toggledScopeMode {
    if (isCrossFolder) {
      if (isShuffle) {
        return isOneShot
            ? SessionLoopMode.folderRandomOnce
            : SessionLoopMode.folderRandom;
      }
      if (isOneShot) return SessionLoopMode.folderOnce;
      return SessionLoopMode.folderSequential;
    }
    if (isShuffle) {
      return isOneShot
          ? SessionLoopMode.crossRandomOnce
          : SessionLoopMode.crossRandom;
    }
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
      case SessionLoopMode.folderRandomOnce:
        return 'Shuffle play (current folder)';
      case SessionLoopMode.crossRandomOnce:
        return 'Shuffle play (cross-folder)';
    }
  }
}
