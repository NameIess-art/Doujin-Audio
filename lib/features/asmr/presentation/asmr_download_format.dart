import 'package:flutter/material.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/media_file_support.dart' show formatMediaFileSize;
import '../domain/asmr_models.dart';

export '../../../core/media/media_file_support.dart' show formatMediaFileSize;

String formatAsmrDownloadTotalSize({
  required int total,
  required bool unknown,
  required String unknownLabel,
  int? estimate,
}) {
  if (!unknown) return formatMediaFileSize(total);
  return estimate == null ? unknownLabel : '≈ ${formatMediaFileSize(estimate)}';
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
