import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../asmr/domain/asmr_models.dart';
import '../application/work_text_service.dart';
import '../domain/library_node.dart';
import 'work_image_viewer_page.dart';

enum WorkEntryType { folder, audio, text, image }

enum WorkEntryAction { open, play, add, remove, rename, setCover, copy }

class WorkEntryItem {
  const WorkEntryItem({
    required this.name,
    required this.relativePath,
    required this.type,
    this.fullPathOrUrl = '',
    this.duration,
    this.fileSizeBytes,
    this.track,
    this.asmrNode,
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
  final AsmrTrackFile? asmrNode;
  final WorkTextFile? textFile;
  final WorkImageItem? imageItem;

  String get extension =>
      asmrNode?.resolvedExtension ??
      path.posix.extension(PathDisplay.fileName(track?.path ?? relativePath));

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

// Derived presentation data, shared by reopened pages without retaining a page
// or another writable library. Weak keys release it with the source snapshot.
final _directoryBuilds = Expando<_WorkDirectoryBuild>();

typedef _DirectorySources = (
  FolderNode?,
  List<WorkTextFile>,
  List<CoverImageReference>,
  List<AsmrTrackFile>?,
  String,
);

class WorkDirectoryInput {
  const WorkDirectoryInput.local({
    required this.root,
    required this.texts,
    required this.images,
    required this.folderPath,
  }) : tree = null;

  const WorkDirectoryInput.asmr(this.tree)
    : root = null,
      texts = const [],
      images = const [],
      folderPath = '';

  final FolderNode? root;
  final List<WorkTextFile> texts;
  final List<CoverImageReference> images;
  final String folderPath;
  final List<AsmrTrackFile>? tree;

  Object get _owner => root ?? tree ?? (texts.isNotEmpty ? texts : images);
  _DirectorySources get _sources => (root, texts, images, tree, folderPath);

  WorkDirectorySnapshot? get resolved {
    final build = _directoryBuilds[_owner];
    return build?.sources == _sources ? build?.snapshot : null;
  }

  Future<WorkDirectorySnapshot> load() {
    final previous = _directoryBuilds[_owner];
    if (previous?.sources == _sources) return previous!.future;
    final build = _WorkDirectoryBuild(_sources);
    _directoryBuilds[_owner] = build;
    build.future = compute(buildWorkDirectorySnapshot, this).then(
      (snapshot) {
        build.snapshot = snapshot;
        return snapshot;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_directoryBuilds[_owner], build)) {
          _directoryBuilds[_owner] = null;
        }
        Error.throwWithStackTrace(error, stack);
      },
    );
    return build.future;
  }
}

class _WorkDirectoryBuild {
  _WorkDirectoryBuild(this.sources);
  final _DirectorySources sources;
  late final Future<WorkDirectorySnapshot> future;
  WorkDirectorySnapshot? snapshot;
}

class WorkDirectorySnapshot {
  WorkDirectorySnapshot({
    required Map<String, List<WorkEntryItem>> directories,
    required this.images,
    required this.hasSubtitle,
  }) : directories = Map.unmodifiable(directories);

  final Map<String, List<WorkEntryItem>> directories;
  final List<WorkImageItem> images;
  final bool hasSubtitle;

  List<WorkEntryItem> entriesAt(List<String> segments) =>
      directories[segments.join('/')] ?? const [];

  int validDepth(List<String> segments) {
    var path = '';
    var depth = 0;
    for (final segment in segments) {
      path = path.isEmpty ? segment : '$path/$segment';
      if (!directories.containsKey(path)) break;
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

  void remoteTree(List<AsmrTrackFile> nodes, String path) {
    final entries = directories.putIfAbsent(path, () => []);
    for (final node in nodes) {
      hasSubtitle |= node.isSubtitle;
      if (node.isFolder) {
        entries.add(
          WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: WorkEntryType.folder,
            asmrNode: node,
          ),
        );
        remoteTree(node.children, childPath(path, node.title));
      } else if (node.isAudio) {
        entries.add(
          WorkEntryItem(
            name: node.displayTitle,
            relativePath: node.relativePath,
            type: WorkEntryType.audio,
            fullPathOrUrl: node.streamUrl ?? '',
            duration: node.duration,
            fileSizeBytes: node.size,
            asmrNode: node,
          ),
        );
      } else if (node.isText) {
        entries.add(
          WorkEntryItem(
            name: node.title,
            relativePath: node.relativePath,
            type: WorkEntryType.text,
            fileSizeBytes: node.size,
            asmrNode: node,
          ),
        );
      } else if (node.isImage) {
        final image = WorkImageItem(
          name: node.title,
          path: node.streamUrl ?? node.downloadUrl ?? '',
          relativePath: node.relativePath,
        );
        images.add(image);
        entries.add(
          WorkEntryItem(
            name: image.name,
            relativePath: image.relativePath,
            type: WorkEntryType.image,
            fileSizeBytes: node.size,
            fullPathOrUrl: image.path,
            asmrNode: node,
            imageItem: image,
          ),
        );
      }
    }
  }

  if (input.tree != null) {
    remoteTree(input.tree!, '');
  } else {
    if (input.root != null) localTree(input.root!, '');
    for (final text in input.texts) {
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
  }
  for (final path in directories.keys.toList(growable: false)) {
    final entries = directories[path]!;
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
    directories[path] = List.unmodifiable(entries);
  }
  return WorkDirectorySnapshot(
    directories: directories,
    images: List.unmodifiable(images),
    hasSubtitle: hasSubtitle,
  );
}
