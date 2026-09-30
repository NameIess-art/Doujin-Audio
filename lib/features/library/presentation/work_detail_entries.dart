import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../asmr/domain/asmr_models.dart';
import '../application/work_text_service.dart';
import '../domain/library_node.dart';
import 'work_image_viewer_page.dart';

enum WorkEntryType { folder, audio, text, image }

enum WorkEntryAction { open, play, add, remove, rename, setCover }

class WorkEntryItem {
  const WorkEntryItem({
    required this.name,
    required this.relativePath,
    required this.type,
    this.fullPathOrUrl = '',
    this.duration,
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
  final MusicTrack? track;
  final AsmrTrackFile? asmrNode;
  final WorkTextFile? textFile;
  final WorkImageItem? imageItem;
}

List<WorkEntryItem> buildLocalWorkEntries({
  required FolderNode? root,
  required List<String> pathSegments,
  required List<WorkTextFile> textFiles,
  required List<WorkImageItem> imageFiles,
  required bool Function(MusicTrack) isHidden,
}) {
  final currentRel = pathSegments.join('/');
  final entries = <WorkEntryItem>[];
  final visibleFolderPaths = <String>{};

  // Find current FolderNode
  FolderNode? currentFolder = root;
  if (currentFolder != null && pathSegments.isNotEmpty) {
    for (final segment in pathSegments) {
      FolderNode? next;
      for (final child in currentFolder!.children) {
        if (child is FolderNode && child.name == segment) {
          next = child;
          break;
        }
      }
      currentFolder = next;
      if (currentFolder == null) break;
    }
  }

  // 1. Folders & Tracks from currentFolder
  if (currentFolder != null) {
    for (final child in currentFolder.children) {
      if (child is FolderNode) {
        final childRel = currentRel.isEmpty
            ? child.name
            : '$currentRel/${child.name}';
        visibleFolderPaths.add(childRel);
        entries.add(
          WorkEntryItem(
            name: child.name,
            relativePath: childRel,
            type: WorkEntryType.folder,
            fullPathOrUrl: child.path,
          ),
        );
      } else if (child is TrackNode) {
        if (isHidden(child.track)) {
          continue;
        }
        entries.add(
          WorkEntryItem(
            name: child.track.displayName,
            relativePath: child.track.path,
            type: WorkEntryType.audio,
            fullPathOrUrl: child.track.path,
            duration: child.track.duration,
            track: child.track,
          ),
        );
      }
    }
  }

  void addFileParentFolder(String fileRelativePath) {
    final fileSegments = fileRelativePath
        .replaceAll(r'\', '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    final currentSegments = currentRel.isEmpty
        ? const <String>[]
        : currentRel.split('/');
    if (fileSegments.length <= currentSegments.length + 1) return;
    for (var index = 0; index < currentSegments.length; index++) {
      if (fileSegments[index] != currentSegments[index]) return;
    }
    final childName = fileSegments[currentSegments.length];
    final childRel = <String>[...currentSegments, childName].join('/');
    if (!visibleFolderPaths.add(childRel)) return;
    entries.add(
      WorkEntryItem(
        name: childName,
        relativePath: childRel,
        type: WorkEntryType.folder,
        fullPathOrUrl: childRel,
      ),
    );
  }

  for (final text in textFiles) {
    addFileParentFolder(text.relativePath);
  }
  for (final image in imageFiles) {
    addFileParentFolder(image.relativePath);
  }

  // 2. Text files in current directory level
  for (final text in textFiles) {
    final parentRel = _parentRelOf(text.relativePath);
    if (_isSameRelPath(parentRel, currentRel)) {
      entries.add(
        WorkEntryItem(
          name: text.name,
          relativePath: text.relativePath,
          type: WorkEntryType.text,
          fullPathOrUrl: text.path,
          textFile: text,
        ),
      );
    }
  }

  // 3. Image files in current directory level
  for (final img in imageFiles) {
    final parentRel = _parentRelOf(img.relativePath);
    if (_isSameRelPath(parentRel, currentRel)) {
      entries.add(
        WorkEntryItem(
          name: img.name,
          relativePath: img.relativePath,
          type: WorkEntryType.image,
          fullPathOrUrl: img.path,
          imageItem: img,
        ),
      );
    }
  }

  // Natural sort: folders first, then files
  entries.sort((a, b) {
    if (a.type == WorkEntryType.folder && b.type != WorkEntryType.folder) {
      return -1;
    }
    if (a.type != WorkEntryType.folder && b.type == WorkEntryType.folder) {
      return 1;
    }
    return compareNaturalTreeEntries(
      leftIsFolder: a.type == WorkEntryType.folder,
      leftName: a.name,
      leftPath: a.relativePath,
      rightIsFolder: b.type == WorkEntryType.folder,
      rightName: b.name,
      rightPath: b.relativePath,
    );
  });

  return entries;
}

List<WorkEntryItem> buildAsmrWorkEntries({
  required List<AsmrTrackFile>? tree,
  required List<String> pathSegments,
  required bool Function(AsmrTrackFile) isHidden,
}) {
  final entries = <WorkEntryItem>[];
  List<AsmrTrackFile> currentNodes = tree ?? const [];

  if (pathSegments.isNotEmpty) {
    for (final segment in pathSegments) {
      AsmrTrackFile? next;
      for (final node in currentNodes) {
        if (node.isFolder && node.title == segment) {
          next = node;
          break;
        }
      }
      if (next != null) {
        currentNodes = next.children;
      } else {
        currentNodes = const [];
        break;
      }
    }
  }

  for (final node in currentNodes) {
    if (node.isFolder) {
      entries.add(
        WorkEntryItem(
          name: node.title,
          relativePath: node.relativePath,
          type: WorkEntryType.folder,
          asmrNode: node,
        ),
      );
    } else if (node.isAudio) {
      if (isHidden(node)) {
        continue;
      }
      entries.add(
        WorkEntryItem(
          name: node.displayTitle,
          relativePath: node.relativePath,
          type: WorkEntryType.audio,
          fullPathOrUrl: node.streamUrl ?? '',
          duration: node.duration,
          asmrNode: node,
        ),
      );
    } else if (node.isText) {
      entries.add(
        WorkEntryItem(
          name: node.title,
          relativePath: node.relativePath,
          type: WorkEntryType.text,
          asmrNode: node,
        ),
      );
    } else if (node.isImage) {
      final imgUrl = node.streamUrl ?? node.downloadUrl ?? '';
      entries.add(
        WorkEntryItem(
          name: node.title,
          relativePath: node.relativePath,
          type: WorkEntryType.image,
          fullPathOrUrl: imgUrl,
          asmrNode: node,
          imageItem: WorkImageItem(
            name: node.title,
            path: imgUrl,
            relativePath: node.relativePath,
          ),
        ),
      );
    }
  }

  // Folders first, then natural sort
  entries.sort((a, b) {
    if (a.type == WorkEntryType.folder && b.type != WorkEntryType.folder) {
      return -1;
    }
    if (a.type != WorkEntryType.folder && b.type == WorkEntryType.folder) {
      return 1;
    }
    return compareNaturalTreeEntries(
      leftIsFolder: a.type == WorkEntryType.folder,
      leftName: a.name,
      leftPath: a.relativePath,
      rightIsFolder: b.type == WorkEntryType.folder,
      rightName: b.name,
      rightPath: b.relativePath,
    );
  });

  return entries;
}

String _parentRelOf(String relPath) {
  final normalized = relPath.replaceAll(r'\', '/').trim();
  final lastSlash = normalized.lastIndexOf('/');
  if (lastSlash < 0) return '';
  return normalized.substring(0, lastSlash);
}

bool _isSameRelPath(String a, String b) {
  return a.replaceAll(r'\', '/').trim() == b.replaceAll(r'\', '/').trim();
}
