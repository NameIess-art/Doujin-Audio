import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../application/work_text_service.dart';
import '../domain/library_node.dart';
import 'work_image_viewer_page.dart';

enum WorkEntryType { folder, audio, text, image }

enum WorkEntryAction {
  open,
  play,
  add,
  remove,
  rename,
  setCover,
  copy,
  openContainingFolder,
}

class WorkEntryItem {
  const WorkEntryItem({
    required this.name,
    required this.relativePath,
    required this.type,
    this.fullPathOrUrl = '',
    this.duration,
    this.fileSizeBytes,
    this.track,
    this.remoteReference,
    this.remoteExtension,
    this.isRemoteVideo = false,
    this.textFile,
    this.imageItem,
  });

  final String name;
  final String relativePath;
  final WorkEntryType type;
  final String fullPathOrUrl;
  final Duration? duration;
  final int? fileSizeBytes;
  final MusicTrack? track;
  final Object? remoteReference;
  final String? remoteExtension;
  final bool isRemoteVideo;
  final WorkTextFile? textFile;
  final WorkImageItem? imageItem;

  String get extension =>
      remoteExtension ??
      path.posix.extension(PathDisplay.fileName(track?.path ?? relativePath));

  String get id => '${type.name}:$relativePath';
  ValueKey<String> get rowKey => ValueKey('work_detail_entry_fade_$id');

  String get displayName {
    final suffix = extension;
    if (type == WorkEntryType.folder ||
        suffix.isEmpty ||
        !name.toLowerCase().endsWith(suffix.toLowerCase())) {
      return name;
    }
    return name.substring(0, name.length - suffix.length);
  }
}

// The page can reuse a prepared directory without knowing its data source.
abstract interface class WorkDirectorySource {
  WorkDirectorySnapshot? get resolved;
  Future<WorkDirectorySnapshot> load();
}

// Weak keys release derived directories with their source snapshots.
final _directoryBuilds = Expando<_WorkDirectoryBuild>();

WorkDirectorySnapshot? resolvedWorkDirectory(Object owner, Object sources) {
  final build = _directoryBuilds[owner];
  return build?.sources == sources ? build?.snapshot : null;
}

Future<WorkDirectorySnapshot> prepareWorkDirectory<T>(
  Object owner,
  Object sources,
  T input,
  WorkDirectorySnapshot Function(T) buildSnapshot,
) {
  final previous = _directoryBuilds[owner];
  if (previous?.sources == sources) return previous!.future;
  final build = _WorkDirectoryBuild(sources);
  _directoryBuilds[owner] = build;
  build.future = compute(buildSnapshot, input).then(
    (snapshot) {
      build.snapshot = snapshot;
      return snapshot;
    },
    onError: (Object error, StackTrace stack) {
      if (identical(_directoryBuilds[owner], build)) {
        _directoryBuilds[owner] = null;
      }
      Error.throwWithStackTrace(error, stack);
    },
  );
  return build.future;
}

class _WorkDirectoryBuild {
  _WorkDirectoryBuild(this.sources);
  final Object sources;
  late final Future<WorkDirectorySnapshot> future;
  WorkDirectorySnapshot? snapshot;
}

class WorkDirectoryInput implements WorkDirectorySource {
  const WorkDirectoryInput.local({
    required this.root,
    required this.texts,
    required this.images,
    required this.folderPath,
  });

  final FolderNode? root;
  final List<WorkTextFile> texts;
  final List<CoverImageReference> images;
  final String folderPath;

  Object get _owner => root ?? (texts.isNotEmpty ? texts : images);
  Object get _sources => (root, texts, images, folderPath);

  @override
  WorkDirectorySnapshot? get resolved =>
      resolvedWorkDirectory(_owner, _sources);

  @override
  Future<WorkDirectorySnapshot> load() =>
      prepareWorkDirectory(_owner, _sources, this, buildWorkDirectorySnapshot);
}

class WorkDirectorySnapshot {
  WorkDirectorySnapshot({
    required Map<String, List<WorkEntryItem>> directories,
    required List<WorkImageItem> images,
    List<WorkTextFile> texts = const [],
    required this.hasSubtitle,
  }) : _directories = Map.unmodifiable(
         directories.map((path, entries) {
           entries.sort(
             (a, b) => compareNaturalTreeEntries(
               leftIsFolder: a.type == WorkEntryType.folder,
               leftName: a.name,
               leftPath: a.relativePath,
               rightIsFolder: b.type == WorkEntryType.folder,
               rightName: b.name,
               rightPath: b.relativePath,
             ),
           );
           return MapEntry(path, List<WorkEntryItem>.unmodifiable(entries));
         }),
       ),
       images = List.unmodifiable(images),
       texts = List.unmodifiable(texts) {
    _entryIndices = Map.unmodifiable(
      _directories.map(
        (path, entries) => MapEntry(
          path,
          Map<Key, int>.unmodifiable({
            for (var index = 0; index < entries.length; index++)
              entries[index].rowKey: index,
          }),
        ),
      ),
    );
    _localTrackKeys = Map.unmodifiable(
      _directories.map(
        (path, entries) => MapEntry(
          path,
          Set<String>.unmodifiable({
            for (final entry in entries)
              if (entry.track case final track?)
                PathMatcher.normalize(track.path),
          }),
        ),
      ),
    );
  }

  final Map<String, List<WorkEntryItem>> _directories;
  late final Map<String, Map<Key, int>> _entryIndices;
  late final Map<String, Set<String>> _localTrackKeys;
  final List<WorkImageItem> images;
  final List<WorkTextFile> texts;
  final bool hasSubtitle;

  List<WorkEntryItem> entriesAt(List<String> segments) =>
      _directories[segments.join('/')] ?? const [];

  Map<Key, int> indicesAt(List<String> segments) =>
      _entryIndices[segments.join('/')] ?? const {};

  bool containsLocalTrack(List<String> segments, String normalizedPath) =>
      _localTrackKeys[segments.join('/')]?.contains(normalizedPath) ?? false;

  int validDepth(List<String> segments) {
    var path = '';
    var depth = 0;
    for (final segment in segments) {
      path = path.isEmpty ? segment : '$path/$segment';
      if (!_directories.containsKey(path)) break;
      depth++;
    }
    return depth;
  }
}

WorkDirectorySnapshot buildWorkDirectorySnapshot(WorkDirectoryInput input) {
  final directories = <String, List<WorkEntryItem>>{'': []};
  final images = <WorkImageItem>[];
  var hasSubtitle = false;

  String childPath(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  void localTree(FolderNode folder, String path) {
    final entries = directories.putIfAbsent(path, () => []);
    for (final child in folder.children) {
      if (child is FolderNode) {
        final relative = childPath(path, child.name);
        entries.add(
          WorkEntryItem(
            name: child.name,
            relativePath: relative,
            type: WorkEntryType.folder,
            fullPathOrUrl: child.path,
          ),
        );
        localTree(child, relative);
      } else if (child is TrackNode) {
        final track = child.track;
        entries.add(
          WorkEntryItem(
            name: track.displayName,
            relativePath: track.path,
            type: WorkEntryType.audio,
            fullPathOrUrl: track.path,
            duration: track.duration,
            fileSizeBytes: track.fileSizeBytes,
            track: track,
          ),
        );
      }
    }
  }

  // File-only folders have no audio FolderNode. Insert each ancestor once,
  // instead of rescanning every discovered file for every visited directory.
  List<WorkEntryItem> fileParent(String relative) {
    final segments = relative.replaceAll(r'\', '/').trim().split('/');
    var path = '';
    for (final name in segments.take(segments.length - 1)) {
      if (name.trim().isEmpty) continue;
      final next = childPath(path, name);
      if (!directories.containsKey(next)) {
        directories[path]!.add(
          WorkEntryItem(
            name: name,
            relativePath: next,
            type: WorkEntryType.folder,
            fullPathOrUrl: next,
          ),
        );
        directories[next] = [];
      }
      path = next;
    }
    return directories[path]!;
  }

  if (input.root != null) localTree(input.root!, '');
  for (final text in input.texts) {
    if (text.isSubtitle) {
      hasSubtitle = true;
      continue;
    }
    fileParent(text.relativePath).add(
      WorkEntryItem(
        name: text.name,
        relativePath: text.relativePath,
        type: WorkEntryType.text,
        fullPathOrUrl: text.path,
        fileSizeBytes: text.fileSizeBytes,
        textFile: text,
      ),
    );
  }
  for (final reference in input.images) {
    final name = PathDisplay.folderName(reference.sourcePath);
    final relative =
        PathMatcher.relativeWithin(reference.sourcePath, input.folderPath) ??
        name;
    final image = WorkImageItem(
      name: name,
      path: reference.displayPath,
      relativePath: relative.startsWith('..') ? name : relative,
    );
    images.add(image);
    fileParent(image.relativePath).add(
      WorkEntryItem(
        name: name,
        relativePath: image.relativePath,
        type: WorkEntryType.image,
        fullPathOrUrl: image.path,
        fileSizeBytes: reference.fileSizeBytes,
        imageItem: image,
      ),
    );
  }
  return WorkDirectorySnapshot(
    directories: directories,
    images: images,
    hasSubtitle: hasSubtitle,
  );
}
