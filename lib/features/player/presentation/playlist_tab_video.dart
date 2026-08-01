part of 'playlist_tab.dart';

bool _isSessionVideoReady(PlaybackSession session, MusicTrack? track) {
  final loadedPath = session.loadedPath;
  return Platform.isAndroid &&
      track?.isVideo == true &&
      loadedPath != null &&
      PathMatcher.equalsNormalized(loadedPath, track!.path);
}

Future<void> _showSessionVideoFullscreen(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String trackPath,
}) async {
  final orientationController = ref.read(appOrientationControllerProvider);
  final lease = await orientationController.enterVideoFullscreen();
  if (!context.mounted) {
    await lease.release();
    return;
  }
  try {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _SessionVideoFullscreenPage(
          sessionId: sessionId,
          trackPath: trackPath,
        ),
      ),
    );
  } finally {
    await lease.release();
  }
}

class _SessionVideoFullscreenPage extends ConsumerStatefulWidget {
  const _SessionVideoFullscreenPage({
    required this.sessionId,
    required this.trackPath,
  });

  final String sessionId;
  final String trackPath;

  @override
  ConsumerState<_SessionVideoFullscreenPage> createState() =>
      _SessionVideoFullscreenPageState();
}

class _SessionVideoFullscreenPageState
    extends ConsumerState<_SessionVideoFullscreenPage> {
  bool _exitScheduled = false;

  void _exitAfterBuild() {
    if (_exitScheduled) return;
    _exitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(Navigator.of(context).maybePop());
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionDetailUiProvider(widget.sessionId));
    final playback = ref.read(playbackFacadeProvider);
    final paths = ref.read(audioPathCoordinatorProvider);
    final session = playback.sessionById(widget.sessionId);
    final track = session == null
        ? null
        : paths.trackByPath(session.currentTrackPath);
    final stillCurrentVideo =
        session != null &&
        track?.isVideo == true &&
        PathMatcher.equalsNormalized(
          session.currentTrackPath,
          widget.trackPath,
        );
    if (!stillCurrentVideo) {
      _exitAfterBuild();
      return const ColoredBox(color: Colors.black);
    }
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SessionVideoViewport(
        poster: const ColoredBox(color: Colors.black),
        videoReady: _isSessionVideoReady(session, track),
        surfaceBuilder: (_) =>
            NativeSessionVideoSurface(sessionId: widget.sessionId),
        onFullscreen: () => Navigator.of(context).maybePop(),
        fullscreenTooltip: i18n.tr('exit_fullscreen'),
        isFullscreen: true,
      ),
    );
  }
}
