import 'music_track.dart';

enum LibraryEntryKind {
  folder('folder'),
  track('track');

  const LibraryEntryKind(this.dbValue);

  final String dbValue;

  static LibraryEntryKind fromDbValue(String value) {
    return switch (value) {
      'folder' => LibraryEntryKind.folder,
      'track' => LibraryEntryKind.track,
      _ => throw StateError('Unknown library entry kind: $value'),
    };
  }
}

enum LibraryEntryState {
  active('active'),
  excluded('excluded');

  const LibraryEntryState(this.dbValue);

  final String dbValue;

  bool get isActive => this == LibraryEntryState.active;
  bool get isExcluded => this == LibraryEntryState.excluded;

  static LibraryEntryState fromDbValue(String value) {
    return switch (value) {
      'active' => LibraryEntryState.active,
      'excluded' => LibraryEntryState.excluded,
      _ => throw StateError('Unknown library entry state: $value'),
    };
  }
}

class LibraryEntry {
  const LibraryEntry({
    required this.libraryPath,
    required this.path,
    required this.kind,
    required this.state,
    this.parentPath,
    this.displayName = '',
    this.groupKey = '',
    this.groupTitle = '',
    this.groupSubtitle = '',
    this.isSingle = false,
    this.isVideo = false,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
  });

  factory LibraryEntry.folder({
    required String libraryPath,
    required String path,
    String? parentPath,
    required LibraryEntryState state,
    String displayName = '',
  }) {
    return LibraryEntry(
      libraryPath: libraryPath,
      path: path,
      kind: LibraryEntryKind.folder,
      state: state,
      parentPath: parentPath,
      displayName: displayName,
    );
  }

  factory LibraryEntry.track({
    required String libraryPath,
    required MusicTrack track,
    String? parentPath,
    required LibraryEntryState state,
  }) {
    return LibraryEntry(
      libraryPath: libraryPath,
      path: track.path,
      kind: LibraryEntryKind.track,
      state: state,
      parentPath: parentPath,
      displayName: track.displayName,
      groupKey: track.groupKey,
      groupTitle: track.groupTitle,
      groupSubtitle: track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
    );
  }

  final String libraryPath;
  final String path;
  final LibraryEntryKind kind;
  final LibraryEntryState state;
  final String? parentPath;
  final String displayName;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final bool isVideo;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;

  bool get isFolder => kind == LibraryEntryKind.folder;
  bool get isTrack => kind == LibraryEntryKind.track;
  bool get isActive => state.isActive;
  bool get isExcluded => state.isExcluded;

  LibraryEntry copyWith({
    LibraryEntryState? state,
    String? parentPath,
    String? displayName,
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    bool? isSingle,
    bool? isVideo,
    DateTime? scannedAt,
    int? fileSizeBytes,
    DateTime? modifiedAt,
  }) {
    return LibraryEntry(
      libraryPath: libraryPath,
      path: path,
      kind: kind,
      state: state ?? this.state,
      parentPath: parentPath ?? this.parentPath,
      displayName: displayName ?? this.displayName,
      groupKey: groupKey ?? this.groupKey,
      groupTitle: groupTitle ?? this.groupTitle,
      groupSubtitle: groupSubtitle ?? this.groupSubtitle,
      isSingle: isSingle ?? this.isSingle,
      isVideo: isVideo ?? this.isVideo,
      scannedAt: scannedAt ?? this.scannedAt,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }

  MusicTrack toTrack() {
    return MusicTrack(
      path: path,
      displayName: displayName,
      groupKey: groupKey,
      groupTitle: groupTitle,
      groupSubtitle: groupSubtitle,
      isSingle: isSingle,
      isVideo: isVideo,
      scannedAt: scannedAt,
      fileSizeBytes: fileSizeBytes,
      modifiedAt: modifiedAt,
    );
  }
}
