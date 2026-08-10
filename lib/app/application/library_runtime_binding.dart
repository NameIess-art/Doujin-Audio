import 'dart:async';

import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import 'runtime_binding.dart';

final class LibraryRuntimeBinding implements RuntimeBinding {
  LibraryRuntimeBinding._(this._library);

  static final Expando<LibraryRuntimeBinding> _attached =
      Expando<LibraryRuntimeBinding>();

  static LibraryRuntimeBinding attach({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    required void Function() syncLibraryState,
    required void Function() syncPlaybackState,
    bool Function()? preferEmbeddedAudioCover,
  }) {
    final existing = _attached[library];
    if (existing != null && !existing._disposed) return existing;
    library.attachTrackRemovalHandler((removedPaths) {
      unawaited(playback.removeSessionsForTrackPaths(removedPaths));
    });
    library.attachCoverChangeHandler(() {
      playback.markSessionStateDirty();
      notifications.syncPlaybackState();
      syncLibraryState();
      syncPlaybackState();
    });
    library.configureCoverArtworkRuntime(
      isActiveCoverKey: notifications.isActiveCoverKey,
      onActiveCoverChanged: () {
        notifications.syncPlaybackState();
        syncPlaybackState();
      },
      preferEmbeddedAudioCover: preferEmbeddedAudioCover,
    );
    final binding = LibraryRuntimeBinding._(library);
    _attached[library] = binding;
    return binding;
  }

  final LibraryFacade _library;
  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _library.detachRuntimeHandlers();
    _attached[_library] = null;
  }
}
