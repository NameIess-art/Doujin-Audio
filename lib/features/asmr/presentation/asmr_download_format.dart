import 'package:flutter/material.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../../../core/media/media_file_support.dart' show formatMediaFileSize;
import '../../library/presentation/work_image_entry_thumbnail.dart';
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

Widget asmrDownloadFileLeading(
  BuildContext context,
  AsmrTrackFile track, {
  bool expanded = false,
}) {
  final icon = _fileIcon(track, expanded: expanded);
  final tokens = AppDesignTokens.of(context);
  final colors = Theme.of(context).colorScheme;
  final fallback = Icon(
    icon,
    size: AppDesignTokens.fileEntryIconSize,
    color: switch (icon) {
      AppDesignTokens.folderIcon ||
      AppDesignTokens.openFolderIcon => tokens.folderColor,
      AppDesignTokens.audioFileIcon ||
      Icons.videocam_outlined => colors.primary,
      AppDesignTokens.textFileIcon => tokens.textFileColor,
      AppDesignTokens.imageFileIcon => tokens.imageFileColor,
      _ => colors.onSurfaceVariant,
    },
  );
  final url = track.remoteImageUrl;
  return url == null
      ? fallback
      : WorkImageEntryThumbnail(path: url, fallbackIcon: fallback);
}

IconData _fileIcon(AsmrTrackFile track, {required bool expanded}) {
  if (track.isFolder) {
    return expanded
        ? AppDesignTokens.openFolderIcon
        : AppDesignTokens.folderIcon;
  }
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
