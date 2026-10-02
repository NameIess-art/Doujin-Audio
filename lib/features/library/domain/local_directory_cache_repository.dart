/// Rebuildable directory discoveries, separate from the writable library index.
abstract interface class LocalDirectoryCacheRepository {
  Future<Map<String, Object?>?> loadDirectorySnapshot({
    required String kind,
    required String key,
  });
  Future<void> saveDirectorySnapshot({
    required String kind,
    required String key,
    required Map<String, Object?> payload,
  });
  Future<void> clearDirectorySnapshots();
}
