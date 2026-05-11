part of 'audio_provider.dart';

extension AudioProviderAudioDetails on AudioProvider {
  static const LibraryOrganizer _detailLibraryOrganizer = LibraryOrganizer();

  AudioDetailTarget audioDetailTargetForTrack(MusicTrack track) {
    if (track.isSingle) {
      return AudioDetailTarget.singleAudioFile(track.path);
    }
    final watchedRoots = _watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    return AudioDetailTarget.libraryRootFolder(
      _detailLibraryOrganizer.rootPathForTrack(track, watchedRoots),
    );
  }

  AudioDetailTarget? audioDetailTargetForSession(String sessionId) {
    final trackPath = sessionTrackPath(sessionId);
    if (trackPath == null || trackPath.isEmpty) return null;
    final track = trackByPath(trackPath);
    if (track == null) {
      return AudioDetailTarget.singleAudioFile(trackPath);
    }
    return audioDetailTargetForTrack(track);
  }

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) {
    return _audioDetailRepository.load(target);
  }

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) {
    return _audioDetailRepository.save(detail);
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) {
    return _audioDetailRepository.delete(target);
  }

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCodeFromText(
    AudioDetailTarget target,
    String text,
  ) {
    return _audioDetailRepository.prefillRjCodeFromText(target, text);
  }
}
