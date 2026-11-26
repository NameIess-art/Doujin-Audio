import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../core/widgets/app_feedback.dart';
import 'library_providers.dart';

Future<void> openLocalContainingFolder(
  BuildContext context,
  WidgetRef ref,
  String targetPath,
) async {
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  final opened = await ref
      .read(libraryFacadeProvider)
      .openContainingFolder(targetPath);
  if (!opened && context.mounted) {
    showAppSnackBar(
      context,
      i18n.tr('operation_failed_retry'),
      tone: AppFeedbackTone.destructive,
    );
  }
}
