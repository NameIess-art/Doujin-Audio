part of 'asmr_download_manager.dart';

extension AsmrDownloadPlanner on AsmrDownloadManager {
  List<_PlannedDownloadFile> _collectPlannedFiles(List<AsmrTrackFile> roots) {
    final result = <_PlannedDownloadFile>[];
    for (final root in roots) {
      _collectPlannedFilesRecursively(root, result);
    }
    return result;
  }

  _PlannedDownloadFile? _plannedCoverFile(AsmrWork work) {
    final url = work.preferredCoverUrl.trim();
    if (url.isEmpty) return null;
    return _PlannedDownloadFile.cover(
      url: url,
      relativePath: 'cover/cover.cover',
      coverFileStem: 'cover',
      maxBytes: AsmrDownloadManager._maxCoverBytes,
    );
  }

  void _collectPlannedFilesRecursively(
    AsmrTrackFile node,
    List<_PlannedDownloadFile> result,
  ) {
    if (node.isFolder) {
      if (node.children.isEmpty) {
        return;
      }
      for (final child in node.children) {
        _collectPlannedFilesRecursively(child, result);
      }
      return;
    }
    final url = _downloadUrlFor(node);
    if (url == null || url.isEmpty) {
      return;
    }
    result.add(
      _PlannedDownloadFile(
        url: url,
        relativePath: node.relativePath,
        size: node.size,
      ),
    );
  }
}
