part of 'audio_provider.dart';

extension AudioProviderLibraryCategories on AudioProvider {
  AudioLibraryCategorySnapshot? get audioLibraryCategorySnapshotSync =>
      _librarySnapshotCacheService.categorySnapshotSync;

  Future<AudioLibraryCategorySnapshot> audioLibraryCategorySnapshot() {
    return _librarySnapshotCacheService.categorySnapshot(
      onCommitted: () {
        _syncLibraryStateSlice();
        _notifyPresentationListeners();
      },
    );
  }
}
