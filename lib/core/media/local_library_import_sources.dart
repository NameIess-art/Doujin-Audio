class LocalLibraryImportSources {
  const LocalLibraryImportSources({
    this.libraries = const <String>[],
    this.folders = const <String>[],
    this.files = const <String>[],
  });

  factory LocalLibraryImportSources.fromJson(Object? value) {
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('Invalid local library source manifest.');
    }

    List<String> paths(String key) {
      final raw = value[key];
      if (raw is! List || raw.any((item) => item is! String)) {
        throw const FormatException('Invalid local library source paths.');
      }
      return _distinctPaths(raw.cast<String>());
    }

    return LocalLibraryImportSources(
      libraries: paths('libraries'),
      folders: paths('folders'),
      files: paths('files'),
    );
  }

  final List<String> libraries;
  final List<String> folders;
  final List<String> files;

  bool get isEmpty => libraries.isEmpty && folders.isEmpty && files.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'libraries': _distinctPaths(libraries),
    'folders': _distinctPaths(folders),
    'files': _distinctPaths(files),
  };
}

List<String> _distinctPaths(Iterable<String> values) {
  final paths = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty || !seen.add(value)) continue;
    paths.add(value);
  }
  return List<String>.unmodifiable(paths);
}
