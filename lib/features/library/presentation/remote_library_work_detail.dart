import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/presentation/work_detail_navigation.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/widgets/app_edit_panel.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/work_review_panel.dart';
import '../../asmr/domain/asmr_models.dart';
import '../../asmr/presentation/asmr_download_page.dart';
import '../../asmr/presentation/asmr_work_detail_sheet.dart'
    show AsmrWorkDirectoryInput;
import '../application/library_facade.dart' show AudioDetailRenameException;
import '../domain/remote_media_source.dart';
import 'dlsite_metadata_review_page.dart';
import 'library_providers.dart';
import 'work_detail_entries.dart';
import 'work_detail_page.dart';

AudioDetail buildEditableAudioDetailForRemoteWork(RemoteLibraryWork work) {
  final folderLeaf = work.folderName.trim().isNotEmpty
      ? work.folderName.trim()
      : (work.title.trim().isNotEmpty ? work.title.trim() : work.workId);
  final target = AudioDetailTarget.libraryRootFolder(
    '/${work.sourceId}/$folderLeaf',
  );
  return AudioDetail(
    target: target,
    rjCode: work.rjCode,
    workTitle: work.title,
    circleName: work.circleName,
    voiceActors: work.voiceActors,
    tags: work.tags,
    releaseDate: work.releaseDateMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(work.releaseDateMs!),
    duration: work.durationMs > 0
        ? Duration(milliseconds: work.durationMs)
        : null,
    salesCount: work.salesCount,
    rating: work.rating,
    listenStatus: WorkListenStatus.tryFromWireValue(work.listenStatus),
    userRating: work.userRating,
    reviewText: work.reviewText,
    reviewUpdatedAt: work.reviewUpdatedAtMs <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(work.reviewUpdatedAtMs),
    updatedAt:
        (work.detailUpdatedAtMs > 0
                ? work.detailUpdatedAtMs
                : work.updatedAtMs) <=
            0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            work.detailUpdatedAtMs > 0
                ? work.detailUpdatedAtMs
                : work.updatedAtMs,
          ),
  );
}

Future<RemoteLibraryWork?> openRemoteWorkDetailEditor(
  BuildContext context,
  WidgetRef ref,
  RemoteLibraryWork initialWork,
) async {
  final remoteController = ref.read(remoteLibraryControllerProvider);
  final source = remoteController.sourceById(initialWork.sourceId);
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  if (source != null && !source.allowEdit) {
    showAppSnackBar(
      context,
      i18n.tr('remote_source_edit_disabled'),
      tone: AppFeedbackTone.warning,
    );
    return null;
  }

  var activeWork =
      remoteController.workByUniqueKey(initialWork.uniqueKey) ?? initialWork;
  RemoteLibraryWork? latestSaved;

  await Navigator.of(context).push<DlsiteMetadataReviewResult>(
    buildAppPageRoute<DlsiteMetadataReviewResult>(
      context: context,
      child: DlsiteMetadataReviewPage.edit(
        detail: buildEditableAudioDetailForRemoteWork(activeWork),
        remoteInitialCoverUrl: activeWork.coverUrl,
        remoteSaveEdits: (
          current,
          edited, {
          required folderName,
          required preserveDuration,
        }) async {
          final currentFolder = activeWork.folderName.trim();
          final requestedFolder = folderName.trim();
          final updated = await remoteController.saveWorkDetail(
            activeWork,
            metadata: edited,
            newFolderName:
                requestedFolder.isNotEmpty && requestedFolder != currentFolder
                ? requestedFolder
                : null,
            preserveDuration: preserveDuration,
          );
          activeWork = updated;
          latestSaved = updated;
          return buildEditableAudioDetailForRemoteWork(updated);
        },
        remoteApplyMetadata: (
          current,
          metadata, {
          required saveCover,
        }) async {
          final updated = await remoteController.saveWorkDetail(
            activeWork,
            metadata: metadata,
            saveCover: saveCover,
            preserveDuration: metadata.duration == null,
          );
          activeWork = updated;
          latestSaved = updated;
          return buildEditableAudioDetailForRemoteWork(updated);
        },
      ),
    ),
  );

  return latestSaved;
}

Future<RemoteLibraryWork?> saveRemoteWorkReviewWithFeedback(
  BuildContext context,
  WidgetRef ref,
  RemoteLibraryWork work,
  WorkReviewDraft draft,
) async {
  final remoteController = ref.read(remoteLibraryControllerProvider);
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  final source = remoteController.sourceById(work.sourceId);
  if (source != null && !source.allowEdit) {
    showAppSnackBar(
      context,
      i18n.tr('remote_source_edit_disabled'),
      tone: AppFeedbackTone.warning,
    );
    return null;
  }
  try {
    final current = remoteController.workByUniqueKey(work.uniqueKey) ?? work;
    return await remoteController.saveWorkReview(
      current,
      listenStatus: draft.listenStatus,
      userRating: draft.userRating,
      reviewText: draft.reviewText,
    );
  } on HttpException catch (error) {
    if (!context.mounted) return null;
    final key = error.message.contains('remote_source_edit_disabled')
        ? 'remote_source_edit_disabled'
        : error.message.contains('remote_source_unauthorized')
        ? 'remote_source_auth_failed'
        : 'audio_detail_save_failed';
    showAppSnackBar(context, i18n.tr(key), tone: AppFeedbackTone.warning);
    return null;
  } on Object {
    if (!context.mounted) return null;
    showAppSnackBar(
      context,
      i18n.tr('audio_detail_save_failed'),
      tone: AppFeedbackTone.warning,
    );
    return null;
  }
}

Future<RemoteLibraryWork?> openRemoteWorkReviewEditor(
  BuildContext context,
  WidgetRef ref,
  RemoteLibraryWork initialWork,
) async {
  final remoteController = ref.read(remoteLibraryControllerProvider);
  final i18n = ref.read(appLanguageProviderInstanceProvider);
  final source = remoteController.sourceById(initialWork.sourceId);
  if (source != null && !source.allowEdit) {
    showAppSnackBar(
      context,
      i18n.tr('remote_source_edit_disabled'),
      tone: AppFeedbackTone.warning,
    );
    return null;
  }
  final work =
      remoteController.workByUniqueKey(initialWork.uniqueKey) ?? initialWork;
  final draft = await showWorkReviewEditPanel(
    context: context,
    workTitle: work.title,
    rjCode: work.rjCode,
    initialStatus: WorkListenStatus.tryFromWireValue(work.listenStatus),
    initialUserRating: work.userRating,
    initialReviewText: work.reviewText,
    syncsWithCloud: false,
    translate: i18n.tr,
  );
  if (draft == null || !context.mounted) return null;
  return saveRemoteWorkReviewWithFeedback(context, ref, work, draft);
}

Future<void> openRemoteLibraryWorkDetail(
  BuildContext context,
  RemoteLibraryWork work, {
  bool returnToMain = false,
}) => WorkDetailNavigation.openFrom(
  context,
  ('remote-library', work.uniqueKey),
  (routeContext) => buildAppPageRoute<void>(
    context: routeContext,
    settings: const RouteSettings(name: workDetailRouteName),
    separateHeader: true,
    child: WorkDetailPage.forRemote(work: RemoteLibraryWorkDetail(work)),
  ),
  returnToMain: returnToMain,
);

class RemoteLibraryWorkDetail implements RemoteWorkDetail {
  const RemoteLibraryWorkDetail(this.work);

  final RemoteLibraryWork work;

  @override
  String get title => work.title;

  @override
  String get folderName => work.folderName;

  @override
  Object get navigationKey => ('remote-library', work.uniqueKey);

  @override
  RemoteWorkDetail watchLatest(WidgetRef ref) {
    final latest = ref.watch(
      remoteLibraryControllerProvider.select(
        (c) => c.workByUniqueKey(work.uniqueKey),
      ),
    );
    if (latest == null || identical(latest, work)) return this;
    return RemoteLibraryWorkDetail(latest);
  }

  @override
  String get workCode => work.rjCode;

  @override
  String get rjCode => work.rjCode;

  @override
  String get circleName => work.circleName;

  @override
  bool get hasSubtitle => work.hasSubtitle;

  @override
  List<String> get voiceActors => work.voiceActors;

  @override
  List<String> get tags => work.tags;

  @override
  String? get preferredCoverUrl => work.coverUrl;

  @override
  List<String?> get alternateCoverUrls => const <String?>[];

  @override
  WorkDirectorySource? cachedDirectory(WidgetRef ref) {
    final tree = ref.read(remoteLibraryControllerProvider).cachedTreeFor(work);
    return tree == null ? null : AsmrWorkDirectoryInput(tree);
  }

  @override
  Future<void> initialize(WidgetRef ref) =>
      ref.read(remoteLibraryControllerProvider).initialize();

  @override
  Future<WorkDirectorySource> refreshDirectory(
    WidgetRef ref, {
    bool forceRefresh = true,
  }) async {
    final controller = ref.read(remoteLibraryControllerProvider);
    await controller.initialize();
    var latest = controller.workByUniqueKey(work.uniqueKey);
    if (latest == null && controller.sourceById(work.sourceId) != null) {
      try {
        await controller.refreshSource(work.sourceId);
        latest = controller.workByUniqueKey(work.uniqueKey);
      } on Object {
        // Let ensureWorkTree report network or auth errors consistently.
      }
    }
    final tree = await controller.ensureWorkTree(
      latest ?? work,
      forceRefresh: forceRefresh,
    );
    return AsmrWorkDirectoryInput(tree);
  }

  @override
  String directoryErrorLabel(AppLanguageProvider i18n, Object error) {
    if (error is HttpException &&
        error.message.contains('remote_source_unauthorized')) {
      return i18n.tr('remote_source_auth_failed');
    }
    return i18n.tr('remote_source_load_failed');
  }

  @override
  bool get supportsReview => true;

  @override
  WorkReviewDraft watchReview(WidgetRef ref) {
    final latest =
        ref.watch(
          remoteLibraryControllerProvider.select(
            (c) => c.workByUniqueKey(work.uniqueKey),
          ),
        ) ??
        work;
    return (
      listenStatus: WorkListenStatus.tryFromWireValue(latest.listenStatus),
      userRating: latest.userRating,
      reviewText: latest.reviewText,
    );
  }

  @override
  bool syncsReviewWithCloud(WidgetRef ref) => false;

  @override
  Future<void> saveReview(
    BuildContext context,
    WidgetRef ref,
    WorkReviewDraft draft,
  ) async {
    await saveRemoteWorkReviewWithFeedback(context, ref, work, draft);
  }

  @override
  bool get supportsEditInfo => true;

  @override
  Future<RemoteWorkDetail?> editInfo(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final updated = await openRemoteWorkDetailEditor(context, ref, work);
    return updated == null ? null : RemoteLibraryWorkDetail(updated);
  }

  @override
  bool get supportsEntryMutation => true;

  @override
  Future<bool> renameEntry(
    BuildContext context,
    WidgetRef ref,
    WorkEntryItem item,
  ) async {
    if (item.relativePath.trim().isEmpty) return false;
    final remoteController = ref.read(remoteLibraryControllerProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final source = remoteController.sourceById(work.sourceId);
    if (source != null && !source.allowEdit) {
      showAppSnackBar(
        context,
        i18n.tr('remote_source_edit_disabled'),
        tone: AppFeedbackTone.warning,
      );
      return false;
    }

    final initialName = item.type == WorkEntryType.folder
        ? item.name
        : item.displayName;
    final targetName = await showAppTextInputPanel<String>(
      context: context,
      header: AppEditPanelHeader(
        title: i18n.tr('rename'),
        icon: Icons.drive_file_rename_outline_rounded,
      ),
      initialValue: initialName,
      decoration: InputDecoration(hintText: i18n.tr('rename')),
      cancelLabel: i18n.tr('cancel'),
      submitLabel: i18n.tr('save'),
      parse: (value) => value,
    );
    if (targetName == null || !context.mounted) return false;
    final trimmed = targetName.trim();
    if (trimmed.isEmpty || trimmed == initialName) return false;

    try {
      final latest = remoteController.workByUniqueKey(work.uniqueKey) ?? work;
      await remoteController.renameWorkEntry(
        latest,
        relativePath: item.relativePath,
        newName: trimmed,
        isDirectory: item.type == WorkEntryType.folder,
        isMedia: item.type == WorkEntryType.audio,
      );
      return true;
    } on AudioDetailRenameException catch (error) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr(
            error.reason == 'nameConflict'
                ? 'audio_detail_rename_conflict'
                : 'audio_detail_rename_failed',
          ),
          tone: AppFeedbackTone.warning,
        );
      }
      return false;
    } on HttpException catch (error) {
      if (context.mounted) {
        final key = error.message.contains('remote_source_edit_disabled')
            ? 'remote_source_edit_disabled'
            : 'audio_detail_rename_failed';
        showAppSnackBar(context, i18n.tr(key), tone: AppFeedbackTone.warning);
      }
      return false;
    } on Object {
      if (context.mounted) {
        showAppSnackBar(
          context,
          i18n.tr('audio_detail_rename_failed'),
          tone: AppFeedbackTone.warning,
        );
      }
      return false;
    }
  }

  @override
  Future<bool> setEntryAsCover(
    BuildContext context,
    WidgetRef ref,
    WorkEntryItem item,
  ) async {
    if (item.relativePath.trim().isEmpty) return false;
    final remoteController = ref.read(remoteLibraryControllerProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final source = remoteController.sourceById(work.sourceId);
    if (source != null && !source.allowEdit) {
      showAppSnackBar(
        context,
        i18n.tr('remote_source_edit_disabled'),
        tone: AppFeedbackTone.warning,
      );
      return false;
    }
    try {
      final latest = remoteController.workByUniqueKey(work.uniqueKey) ?? work;
      await remoteController.setWorkCoverFromEntry(
        latest,
        relativeImagePath: item.relativePath,
      );
      return true;
    } on HttpException catch (error) {
      if (context.mounted) {
        final key = error.message.contains('remote_source_edit_disabled')
            ? 'remote_source_edit_disabled'
            : 'operation_failed_retry';
        showAppSnackBar(context, i18n.tr(key), tone: AppFeedbackTone.warning);
      }
      return false;
    }
  }

  @override
  Future<void> download(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final controller = container.read(remoteLibraryControllerProvider);
    final current = controller.workByUniqueKey(work.uniqueKey) ?? work;
    final syntheticWork = buildDownloadableWork(current);
    await Navigator.of(context).push<AsmrDownloadPageResult>(
      buildAppPageRoute<AsmrDownloadPageResult>(
        context: context,
        child: AsmrDownloadPage(
          work: syntheticWork,
          customTreeLoader: () => controller.ensureWorkTree(current),
        ),
      ),
    );
  }

  @override
  Future<bool> play(WidgetRef ref, WorkEntryItem item) {
    final controller = ref.read(remoteLibraryControllerProvider);
    final current = controller.workByUniqueKey(work.uniqueKey) ?? work;
    return controller.playTrack(current, item.remoteReference as AsmrTrackFile);
  }

  @override
  Future<bool> addToPlaylist(WidgetRef ref, WorkEntryItem item) {
    final controller = ref.read(remoteLibraryControllerProvider);
    final current = controller.workByUniqueKey(work.uniqueKey) ?? work;
    return controller.addTrackToPlaylist(
      current,
      item.remoteReference as AsmrTrackFile,
    );
  }

  static AsmrWork buildDownloadableWork(RemoteLibraryWork work) {
    final numericRj = int.tryParse(
      work.rjCode.replaceAll(RegExp(r'[^0-9]'), ''),
    );
    return AsmrWork(
      id: numericRj ?? work.workId.hashCode.abs(),
      title: work.title,
      circleName: work.circleName,
      sourceId: work.rjCode.isNotEmpty ? work.rjCode : work.workId,
      sourceType: 'remote-source',
      sourceUrl: work.directoryUri ?? '',
      coverUrl: work.coverUrl ?? '',
      thumbnailUrl: work.coverUrl ?? '',
      mainCoverUrl: work.coverUrl ?? '',
      releaseDate: work.releaseDateMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(work.releaseDateMs!),
      createDate: null,
      duration: Duration(milliseconds: work.durationMs),
      dlCount: work.salesCount ?? 0,
      reviewCount: 0,
      rating: work.rating ?? 0,
      voiceActors: work.voiceActors,
      tags: work.tags,
      hasSubtitle: work.hasSubtitle,
    );
  }
}
