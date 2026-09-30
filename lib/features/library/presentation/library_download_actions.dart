import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_display.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../asmr/presentation/asmr_download_page.dart';
import 'library_providers.dart';
import 'audio_detail_sheet.dart';

Future<void> downloadAudioTargetFromAsmr({
  required BuildContext context,
  required WidgetRef ref,
  required AudioDetailTarget target,
}) async {
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);

  var detail = ref.read(libraryFacadeProvider).resolvedAudioDetail(target);
  var rjCode =
      (detail != null ? AudioDetail.findRjCodeInText(detail.rjCode) : null) ??
      AudioDetail.findRjCodeInText(PathDisplay.folderName(target.targetPath)) ??
      AudioDetail.findRjCodeInText(target.targetPath) ??
      (detail != null ? AudioDetail.findRjCodeInText(detail.workTitle) : null);

  if (rjCode == null) {
    try {
      final loaded = await ref
          .read(libraryFacadeProvider)
          .loadAudioDetail(target);
      detail = loaded.detail;
      rjCode =
          AudioDetail.findRjCodeInText(detail.rjCode) ??
          AudioDetail.findRjCodeInText(detail.workTitle);
    } catch (_) {
      // Best-effort load.
    }
  }

  if (!context.mounted) return;

  if (rjCode == null || rjCode.isEmpty) {
    showAppSnackBar(
      context,
      i18n.tr('audio_detail_missing_rj_for_download'),
      tone: AppFeedbackTone.warning,
    );
    return;
  }

  final effectiveRjCode = rjCode;
  final destination = resolveWorkFolderDestination(target);

  await Navigator.of(context).push<void>(
    buildAppPageRoute<void>(
      context: context,
      child: AsmrDownloadPage(
        initialRjCode: effectiveRjCode,
        customDestinationRoot: destination.destinationRoot,
        customWorkFolderName: destination.workFolderName,
      ),
    ),
  );
}
