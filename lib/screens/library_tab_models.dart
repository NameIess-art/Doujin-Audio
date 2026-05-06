part of 'library_tab.dart';

class _ScannedTrack {
  const _ScannedTrack({
    required this.path,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    this.displayName,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
  });

  final String path;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final String? displayName;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;
}
