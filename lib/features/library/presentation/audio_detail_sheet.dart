import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../app/presentation/work_detail_navigation.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import 'dlsite_metadata_review_page.dart';
import 'library_providers.dart';
import 'work_detail_page.dart';

({String destinationRoot, String workFolderName}) resolveWorkFolderDestination(
  AudioDetailTarget target,
) {
  final isWindows =
      RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)').hasMatch(target.targetPath) ||
      target.targetPath.contains(r'\');
  final pContext = isWindows ? path.windows : path.context;
  final folderPath = target.isLibraryRootFolder
      ? target.targetPath
      : (PathMatcher.parentPath(target.targetPath) ??
            pContext.dirname(target.targetPath));

  if (PathMatcher.isContentUri(folderPath)) {
    if (folderPath.contains('::')) {
      final marker = folderPath.indexOf('::');
      final base = folderPath.substring(0, marker);
      final rel = folderPath
          .substring(marker + 2)
          .replaceAll(r'\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      if (rel.contains('/')) {
        final lastSlash = rel.lastIndexOf('/');
        final parentRel = rel.substring(0, lastSlash);
        final folderName = rel.substring(lastSlash + 1);
        return (
          destinationRoot: parentRel.isEmpty ? base : '$base::$parentRel',
          workFolderName: folderName,
        );
      }
      return (destinationRoot: base, workFolderName: rel);
    }
    final parent = PathMatcher.parentPath(folderPath) ?? folderPath;
    final folderName = PathDisplay.folderName(folderPath);
    return (destinationRoot: parent, workFolderName: folderName);
  }

  var sanitized = folderPath.trim();
  while (sanitized.length > 1 &&
      (sanitized.endsWith('/') || sanitized.endsWith(r'\')) &&
      !sanitized.endsWith(':/') &&
      !sanitized.endsWith(r':\')) {
    sanitized = sanitized.substring(0, sanitized.length - 1);
  }
  final normalized = pContext.normalize(sanitized);
  final destinationRoot = pContext.dirname(normalized);
  final workFolderName = pContext.basename(normalized);
  return (
    destinationRoot: destinationRoot,
    workFolderName: workFolderName.isEmpty ? normalized : workFolderName,
  );
}

Future<void> showAudioDetailSheet(
  BuildContext context,
  AudioDetailTarget target, {
  bool returnToMain = false,
  AudioDetail? initialDetail,
  String? initialCoverPath,
}) => WorkDetailNavigation.openFrom(
  context,
  ('local', target),
  (routeContext) => buildAppPageRoute<void>(
    context: routeContext,
    settings: const RouteSettings(name: workDetailRouteName),
    separateHeader: true,
    child: WorkDetailPage.forLocal(
      target: target,
      initialDetail: initialDetail,
      initialCoverPath: initialCoverPath,
    ),
  ),
  returnToMain: returnToMain,
);

Future<DlsiteMetadataReviewResult?> showAudioDetailEditor(
  BuildContext context,
  WidgetRef ref,
  AudioDetailTarget target,
) async {
  final navigator = Navigator.of(context);
  final origin = readAppRoute(context);
  try {
    final result = await ref
        .read(libraryFacadeProvider)
        .loadAudioDetail(target);
    if (!context.mounted || !navigator.mounted || origin?.isCurrent == false) {
      return null;
    }
    return await navigator.push<DlsiteMetadataReviewResult>(
      buildAppPageRoute(
        context: context,
        child: DlsiteMetadataReviewPage.edit(detail: result.detail),
      ),
    );
  } catch (error, stackTrace) {
    AppLogService.warning(
      'audio_detail_editor_load_failed',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      showAppSnackBar(
        context,
        ref
            .read(appLanguageProviderInstanceProvider)
            .tr('audio_detail_load_failed'),
        tone: AppFeedbackTone.warning,
      );
    }
    return null;
  }
}
