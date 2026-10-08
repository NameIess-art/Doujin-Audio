import 'package:flutter/material.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../domain/asmr_models.dart';

String formatAsmrDownloadSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
}

IconData asmrDownloadFileIcon(AsmrTrackFile track) {
  if (track.isFolder) return AppDesignTokens.folderIcon;
  if (track.isVideo) return Icons.videocam_outlined;
  if (track.isAudio) return AppDesignTokens.audioFileIcon;
  if (track.isText || track.isSubtitle) return AppDesignTokens.textFileIcon;
  if (track.isImage) return AppDesignTokens.imageFileIcon;
  switch (track.resolvedExtension) {
    case '.json':
    case '.cue':
      return AppDesignTokens.textFileIcon;
    case '.zip':
    case '.7z':
    case '.rar':
      return Icons.archive_rounded;
    default:
      return Icons.insert_drive_file_rounded;
  }
}

Color asmrDownloadFileColor(
  AsmrTrackFile track, {
  required Color audioColor,
  required Color fallbackColor,
}) => switch (asmrDownloadFileIcon(track)) {
  AppDesignTokens.folderIcon => AppDesignTokens.folderIconColor,
  AppDesignTokens.audioFileIcon || Icons.videocam_outlined => audioColor,
  AppDesignTokens.textFileIcon => AppDesignTokens.textFileIconColor,
  AppDesignTokens.imageFileIcon => AppDesignTokens.imageFileIconColor,
  _ => fallbackColor,
};
