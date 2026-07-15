import '../../core/media/audio_detail.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';

/// Coordinates path changes that affect both the library and active playback.
final class AudioPathCoordinator {
  const AudioPathCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
  }) : _library = library,
       _playback = playback;

  final LibraryFacade _library;
  final PlaybackFacade _playback;

  Future<AudioDetailRenameResult> renameAudioDetailTarget(AudioDetail detail) =>
      renameAudioDetailTargetToName(detail, detail.workTitle);

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final oldPath = detail.target.targetPath;
    final result = await _library.renameAudioDetailTargetToName(
      detail,
      targetName,
    );
    if (result.renamed) {
      await _playback.retargetPath(oldPath, result.detail.target.targetPath);
    }
    return result;
  }
}
