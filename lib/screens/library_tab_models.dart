part of 'library_tab.dart';

class _ScannedTrack {
  const _ScannedTrack({
    required this.path,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    required this.isVideo,
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
  final bool isVideo;
  final String? displayName;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;

  factory _ScannedTrack.fromPayload(Map<Object?, Object?> payload) {
    DateTime? dateFromPayload(Object? value) {
      if (value is num) {
        return DateTime.fromMillisecondsSinceEpoch(value.toInt());
      }
      return null;
    }

    return _ScannedTrack(
      path: payload['path']?.toString() ?? '',
      groupKey: payload['groupKey']?.toString() ?? '',
      groupTitle: payload['groupTitle']?.toString() ?? '',
      groupSubtitle: payload['groupSubtitle']?.toString() ?? '',
      isSingle: payload['isSingle'] as bool? ?? false,
      isVideo: payload['isVideo'] as bool? ?? false,
      displayName: payload['displayName']?.toString(),
      scannedAt: dateFromPayload(payload['scannedAtMs']),
      fileSizeBytes: (payload['fileSizeBytes'] as num?)?.toInt(),
      modifiedAt: dateFromPayload(payload['modifiedAtMs']),
    );
  }
}
