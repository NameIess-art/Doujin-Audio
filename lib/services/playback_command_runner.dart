class PlaybackCommandToken {
  const PlaybackCommandToken({
    required this.sessionId,
    required this.generation,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;

  final String sessionId;
  final int generation;
  final bool Function() _isCurrent;

  bool get isCurrent => _isCurrent();
}

class PlaybackCommandRunner {
  const PlaybackCommandRunner();

  PlaybackCommandToken start({
    required String sessionId,
    required int generation,
    required bool Function() isCurrent,
  }) {
    return PlaybackCommandToken(
      sessionId: sessionId,
      generation: generation,
      isCurrent: isCurrent,
    );
  }
}
