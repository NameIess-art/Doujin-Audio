import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_download_actions.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/features/library/presentation/audio_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/folder_cover_selector.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_batch_page.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

class _FakeDlsiteMetadataService extends DlsiteMetadataService {
  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.ja,
  }) async {
    return DlsiteMetadata(
      rjCode: rjCode,
      workTitle: 'Fetched title',
      circleName: 'Circle',
      voiceActors: const <String>['Voice'],
      tags: const <String>['ASMR'],
      releaseDate: DateTime(2024, 5, 6),
      duration: const Duration(hours: 1, minutes: 2, seconds: 3),
      salesCount: 1234,
      rating: 4.5,
    );
  }

  @override
  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    AppLanguage language = AppLanguage.ja,
    int limit = 6,
  }) async {
    return <DlsiteMetadata>[await fetchByRjCode('RJ123456')];
  }
}

class _PendingDlsiteMetadataService extends DlsiteMetadataService {
  final Completer<DlsiteMetadata> result = Completer<DlsiteMetadata>();

  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.ja,
  }) => result.future;
}

class _PendingSubmissionOperations extends UiOperationService {
  _PendingSubmissionOperations({this.work});

  final AsmrWork? work;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<T> run<T>({
    required UiOperationScope scope,
    required String labelKey,
    required UiOperationTask<T> task,
    FutureOr<void> Function(T value)? onSuccess,
    FutureOr<void> Function(Object error, StackTrace stackTrace)? onError,
    bool cancelPrevious = true,
  }) {
    if (scope == UiOperationScope.asmrDownloadInit) {
      return Future.value(
        (
              tree: <AsmrTrackFile>[
                AsmrTrackFile.fromJson(const {
                  'hash': 'track',
                  'title': 'track.mp3',
                  'type': 'audio',
                  'mediaDownloadUrl': 'https://example.com/track.mp3',
                }),
              ],
              destinationRoot: '/downloads',
              work: work!,
            )
            as T,
      );
    }
    return super.run<T>(
      scope: scope,
      labelKey: labelKey,
      task: (progress) async {
        final result = await task(progress);
        started.complete();
        await release.future;
        return result;
      },
      onSuccess: onSuccess,
      onError: onError,
      cancelPrevious: cancelPrevious,
    );
  }
}

class _SubmittedDownloads extends AsmrDownloadManager {
  _SubmittedDownloads() : super(persistTasks: false);

  final submitted = <int>[];

  @override
  Future<bool> destinationExists(String folderPath) async => true;

  @override
  Future<void> startDownload({
    required AsmrWork work,
    required List<AsmrTrackFile> selectedRoots,
    required String destinationRoot,
    required AsmrDownloadConflictPolicy conflictPolicy,
    bool saveMetadata = true,
    bool saveCover = true,
    int automaticFileRetryCount = kDefaultAsmrDownloadRetryCount,
    Iterable<AsmrDownloadFolderNameField> folderNameFields =
        kDefaultAsmrDownloadFolderNameFields,
    String? customWorkFolderName,
  }) async {
    submitted.add(work.id);
  }
}

class _SubmittedDetails extends AudioDetailRepository {
  _SubmittedDetails(AppRuntimeWidgetTestFixture fixture)
    : super(databaseRepository: fixture.persistenceRepository);

  AudioDetail? submitted;
  Completer<AudioDetailLoadResult>? pendingLoad;

  @override
  Future<AudioDetailLoadResult> load(AudioDetailTarget target) =>
      pendingLoad?.future ?? super.load(target);

  @override
  Future<AudioDetailSaveResult> save(AudioDetail detail) async {
    submitted = detail;
    return AudioDetailSaveResult(
      detail: detail,
      documentStatus: JsonDocumentWriteStatus.preserved,
    );
  }
}

Future<WorkDetailNavigation> _mountSubmissionNavigator(
  WidgetTester tester,
  AppRuntimeWidgetTestFixture fixture,
  _PendingSubmissionOperations operations, {
  AsmrDownloadManager? downloads,
  LibraryFacade? library,
}) async {
  final navigation = WorkDetailNavigation(
    rootNavigatorKey: GlobalKey<NavigatorState>(),
  );
  addTearDown(navigation.dispose);
  await tester.pumpWidget(
    fixture.build(
      Navigator(
        key: navigation.navigatorKey,
        observers: [navigation.observer],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Main')),
        ),
      ),
      overrides: [
        uiOperationServiceProvider.overrideWithValue(operations),
        if (library != null) libraryFacadeProvider.overrideWithValue(library),
        if (downloads != null)
          asmrDownloadManagerProvider.overrideWithValue(downloads),
      ],
    ),
  );
  unawaited(
    navigation.open(
      'A',
      (_) => MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Work A')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return navigation;
}

Future<void> _replaceDuringSubmission(
  WidgetTester tester,
  WorkDetailNavigation navigation,
  _PendingSubmissionOperations operations,
  State oldPage,
) async {
  PageRoute<void>? replacement;
  unawaited(
    navigation.open(
      'B',
      (_) => replacement = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Work B')),
      ),
    ),
  );
  await tester.pump();
  expect(oldPage.mounted, isTrue);
  expect(replacement!.animation!.isCompleted, isFalse);
  operations.release.complete();
  await tester.pump();
  expect(replacement!.isCurrent, isTrue);
  await tester.pumpAndSettle();
  expect(find.text('Work B'), findsOneWidget);
  expect(oldPage.mounted, isFalse);
  expect(tester.takeException(), isNull);
}

class _FakeAsmrMetadataService extends AsmrMetadataService {
  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    return DlsiteMetadata(
      rjCode: rjCode,
      workTitle: 'ASMR fetched title',
      circleName: '',
      voiceActors: const <String>['ASMR Voice'],
      tags: const <String>['ASMR'],
    );
  }

  @override
  Future<List<DlsiteMetadata>> searchByTitleCandidates(
    Iterable<String> titles, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    return <DlsiteMetadata>[await fetchByRjCode('RJ123456')];
  }
}

class _DetailCoverCacheService extends CoverArtworkCacheService {
  _DetailCoverCacheService({
    this.candidates = const <String>['/covers/candidate.jpg'],
    this.embeddedCoverPath,
    this.currentCoverPath,
    this.candidatesFuture,
  }) : super(libraryService: LibraryService());

  final List<String> candidates;
  final String? embeddedCoverPath;
  final String? currentCoverPath;
  final Future<List<String>>? candidatesFuture;
  int candidateQueries = 0;

  @override
  Future<String?> futureForFolder(String folderPath) async => currentCoverPath;

  @override
  Future<String?> resolveEmbeddedCoverForPath(String filePath) async =>
      embeddedCoverPath;

  @override
  String? resolvedEmbeddedCoverForPath(String filePath) => embeddedCoverPath;

  @override
  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
  }) async {
    candidateQueries++;
    return candidatesFuture ?? candidates;
  }
}

void _expectPrimaryFilledButton(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final element = tester.element(finder);
  final scheme = Theme.of(element).colorScheme;
  final button = tester.widget<FilledButton>(finder);
  final style = button.defaultStyleOf(element);
  expect(style.backgroundColor?.resolve(const <WidgetState>{}), scheme.primary);
  expect(
    style.foregroundColor?.resolve(const <WidgetState>{}),
    scheme.onPrimary,
  );
  expect(button.style?.shape, isNull);
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database testDatabase;

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

  testWidgets('submitted download completion cannot close a replacement work', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final work = AsmrWork.fromJson(const {'id': 1, 'title': 'Work A'});
    final operations = _PendingSubmissionOperations(work: work);
    final downloads = _SubmittedDownloads();
    addTearDown(downloads.dispose);
    final navigation = await _mountSubmissionNavigator(
      tester,
      fixture,
      operations,
      downloads: downloads,
    );
    unawaited(
      navigation.navigatorKey.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => AsmrDownloadPage(work: work)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('asmr_download_start_button')));
    await tester.pump();
    expect(operations.started.isCompleted, isTrue);
    final oldPage = tester.state(find.byType(AsmrDownloadPage));
    await _replaceDuringSubmission(tester, navigation, operations, oldPage);
    expect(downloads.submitted, [work.id]);
  });

  testWidgets('submitted edit completion cannot close a replacement work', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final operations = _PendingSubmissionOperations();
    final repository = _SubmittedDetails(fixture);
    final library = LibraryFacade.create(
      databaseRepository: fixture.persistenceRepository,
      detailRepository: repository,
      service: fixture.libraryService,
    );
    final navigation = await _mountSubmissionNavigator(
      tester,
      fixture,
      operations,
      library: library,
    );
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.singleAudioFile,
      targetPath: '/library/submission-regression.mp3',
    );
    unawaited(
      navigation.navigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => DlsiteMetadataReviewPage.edit(
            detail: AudioDetail.empty(target).copyWith(duration: Duration.zero),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('metadata_edit_audio_detail_work_title')),
        matching: find.byType(TextField),
      ),
      'Submitted title',
    );
    await tester.tap(find.byKey(const ValueKey('dlsite_review_confirm')));
    await tester.pump();
    expect(operations.started.isCompleted, isTrue);
    await tester.pump();
    final oldPage = tester.state(find.byType(DlsiteMetadataReviewPage));
    await _replaceDuringSubmission(tester, navigation, operations, oldPage);
    expect(repository.submitted!.workTitle, 'Submitted title');
  });

  testWidgets(
    'delayed local download lookup cannot open on a replacement work',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final repository = _SubmittedDetails(fixture)
        ..pendingLoad = Completer<AudioDetailLoadResult>();
      final library = LibraryFacade.create(
        databaseRepository: fixture.persistenceRepository,
        detailRepository: repository,
        service: fixture.libraryService,
      );
      final navigation = await _mountSubmissionNavigator(
        tester,
        fixture,
        _PendingSubmissionOperations(),
        library: library,
      );
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.singleAudioFile,
        targetPath: '/library/lookup-regression.mp3',
      );
      unawaited(
        navigation.navigatorKey.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => downloadAudioTargetFromAsmr(
                    context: context,
                    ref: ref,
                    target: target,
                  ),
                  child: const Text('Load download'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final oldContext = tester.element(find.text('Load download'));
      await tester.tap(find.text('Load download'));
      await tester.pump();
      unawaited(
        navigation.open(
          'B',
          (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Work B')),
          ),
        ),
      );
      await tester.pump();
      expect(oldContext.mounted, isTrue);
      repository.pendingLoad!.complete(
        AudioDetailLoadResult(
          detail: AudioDetail.empty(target).copyWith(rjCode: 'RJ123456'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Work B'), findsOneWidget);
      expect(find.byType(AsmrDownloadPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'metadata editing preserves input when a narrow pane resizes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          DlsiteMetadataReviewPage.edit(
            detail: AudioDetail.empty(
              const AudioDetailTarget(
                targetType: AudioDetailTargetType.singleAudioFile,
                targetPath: '/library/Work/audio.mp3',
              ),
            ).copyWith(duration: const Duration(minutes: 1)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byKey(const ValueKey('metadata_edit_audio_detail_work_title')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Unsaved title');
      final state = tester.state(find.byType(DlsiteMetadataReviewPage));
      tester.view.physicalSize = const Size(510, 800);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(DlsiteMetadataReviewPage)), same(state));
      expect(tester.widget<TextField>(field).controller!.text, 'Unsaved title');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'metadata review controls fit a narrow pane',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.en);
      final metadata = DlsiteMetadata(
        rjCode: 'RJ123456',
        workTitle: 'Work title',
        circleName: 'Circle',
        voiceActors: const [],
        tags: const [],
      );
      DlsiteMetadataReviewResult? completion;
      await tester.pumpWidget(
        fixture.build(
          DlsiteMetadataReviewPage(
            detail: AudioDetail.empty(
              const AudioDetailTarget(
                targetType: AudioDetailTargetType.singleAudioFile,
                targetPath: '/library/Work/audio.mp3',
              ),
            ),
            initialCandidates: [
              metadata,
              metadata.copyWith(rjCode: 'RJ654321'),
            ],
            batchIndex: 2,
            batchTotal: 3,
            onBatchNavigate: (_) {},
            onCompleted: (value) => completion = value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final navigation = find.byKey(
        const ValueKey('dlsite_review_work_navigation'),
      );
      final confirm = find.byKey(const ValueKey('dlsite_review_confirm'));
      expect(
        tester.getRect(navigation).bottom,
        lessThan(tester.getRect(confirm).top),
      );
      await tester.tap(confirm);
      await tester.pump();
      expect(completion!.isConfirmed, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'download header keeps its title readable in a narrow pane',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.en);
      await tester.pumpWidget(
        fixture.build(
          AsmrDownloadPage(
            work: AsmrWork.fromJson(const {'id': 1, 'title': 'Work title'}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final title = find.text(
        fixture.languageProvider.tr('asmr_download_title'),
      );
      expect(tester.getSize(title).width, greaterThan(50));
      expect(
        find.byTooltip(
          fixture.languageProvider.tr('asmr_download_choose_path'),
        ),
        findsOneWidget,
      );
      tester.view.physicalSize = const Size(510, 800);
      await tester.pumpAndSettle();
      expect(
        find.text(fixture.languageProvider.tr('asmr_download_choose_path')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('metadata review skeleton matches the cover and field layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final metadataService = _PendingDlsiteMetadataService();
    final fixture = AppRuntimeWidgetTestFixture(
      dlsiteMetadataService: metadataService,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(
      fixture.build(
        DlsiteMetadataReviewPage(
          detail: AudioDetail.empty(
            const AudioDetailTarget(
              targetType: AudioDetailTargetType.libraryRootFolder,
              targetPath: '/library/LoadingWork',
            ),
          ),
          rjCode: 'RJ123456',
          batchIndex: 1,
          batchTotal: 2,
          onBatchNavigate: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Scrollable), findsNothing);
    final loadingConfirm = find.byKey(
      const ValueKey<String>('dlsite_review_confirm'),
    );
    final loadingConfirmIcon = find.byKey(
      const ValueKey<String>('dlsite_review_confirm_icon'),
    );
    final skeletonPrevious = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_previous_work'),
    );
    final skeletonNext = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_next_work'),
    );
    expect(loadingConfirm, findsOneWidget);
    expect(loadingConfirmIcon, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('dlsite_review_skeleton_confirm')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: loadingConfirm,
        matching: find.byType(ShimmerContainer),
      ),
      findsNothing,
    );
    expect(
      tester.widget<InkWell>(
        find.descendant(of: loadingConfirm, matching: find.byType(InkWell)),
      ).onTap,
      isNull,
    );
    expect(skeletonPrevious, findsOneWidget);
    expect(skeletonNext, findsOneWidget);
    final loadingConfirmRect = tester.getRect(loadingConfirm);
    final loadingConfirmIconCenter = tester.getCenter(loadingConfirmIcon);
    final skeletonPreviousCenter = tester.getCenter(skeletonPrevious);
    final skeletonNextCenter = tester.getCenter(skeletonNext);

    final skeletonCover = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_cover'),
    );
    expect(skeletonCover, findsOneWidget);
    expect(find.byType(OperationSkeletonList), findsNothing);
    final coverRect = tester.getRect(skeletonCover);
    expect(coverRect.width / coverRect.height, closeTo(4 / 3, 0.01));
    final firstField = find.byKey(
      const ValueKey<String>('dlsite_review_skeleton_field_0'),
    );
    expect(tester.getRect(firstField).top, greaterThan(coverRect.bottom));
    expect(tester.getRect(firstField).width, coverRect.width);
    final skeletonFields = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'dlsite_review_skeleton_field_',
          ),
    );
    final behindConfirmElement = skeletonFields.evaluate().firstWhere((
      element,
    ) {
      final field = find.byElementPredicate(
        (candidate) => candidate == element,
      );
      return tester.getRect(field).overlaps(loadingConfirmRect);
    });
    final behindConfirm = find.byElementPredicate(
      (element) => element == behindConfirmElement,
    );
    final fieldRect = tester.getRect(behindConfirm);
    final exposedPoint = Offset(
      loadingConfirmRect.left - 20,
      (fieldRect.top > loadingConfirmRect.top
              ? fieldRect.top
              : loadingConfirmRect.top) +
          2,
    );
    expect(
      tester
          .hitTestOnBinding(exposedPoint)
          .path
          .any((entry) => entry.target == tester.renderObject(behindConfirm)),
      isTrue,
    );

    metadataService.result.complete(
      DlsiteMetadata(
        rjCode: 'RJ123456',
        workTitle: 'Loaded Work',
        circleName: 'Circle',
        voiceActors: const <String>[],
        tags: const <String>[],
        coverUrl: 'https://example.com/cover.jpg',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(skeletonCover, findsOneWidget);
    final halfFadeDuration = kPlaceholderContentTransitionDuration ~/ 2;
    await tester.pump(halfFadeDuration);
    expect(skeletonCover, findsOneWidget);
    await tester.pump(
      kPlaceholderContentTransitionDuration -
          halfFadeDuration +
          const Duration(milliseconds: 1),
    );
    expect(skeletonCover, findsNothing);
    final confirm = find.byKey(const ValueKey<String>('dlsite_review_confirm'));
    final confirmIcon = find.byKey(
      const ValueKey<String>('dlsite_review_confirm_icon'),
    );
    final previous = find.byKey(
      const ValueKey<String>('dlsite_review_previous_work'),
    );
    final next = find.byKey(const ValueKey<String>('dlsite_review_next_work'));
    expect(tester.getRect(confirm), loadingConfirmRect);
    expect(tester.getCenter(confirmIcon), loadingConfirmIconCenter);
    expect(
      tester.widget<InkWell>(
        find.descendant(of: confirm, matching: find.byType(InkWell)),
      ).onTap,
      isNotNull,
    );
    expect(tester.getCenter(previous), skeletonPreviousCenter);
    expect(tester.getCenter(next), skeletonNextCenter);
    final actualCover = find.ancestor(
      of: find.byType(AsyncRemoteCoverImage),
      matching: find.byType(AspectRatio),
    ).first;
    expect(tester.getRect(actualCover), coverRect);
    expect(find.text('Loaded Work'), findsOneWidget);
  });

  testWidgets(
    'batch metadata page defaults to missing works and shows counts',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: DlsiteMetadataBatchPage(
            entries: [
              AudioLibraryCategoryEntry(
                target: const AudioDetailTarget(
                  targetType: AudioDetailTargetType.libraryRootFolder,
                  targetPath: '/library/Complete',
                ),
                title: 'Complete',
                path: '/library/Complete',
                isFolder: true,
                detail: AudioDetail(
                  target: const AudioDetailTarget(
                    targetType: AudioDetailTargetType.libraryRootFolder,
                    targetPath: '/library/Complete',
                  ),
                  rjCode: 'RJ123456',
                  workTitle: 'Complete',
                  circleName: 'Circle',
                  voiceActors: const <String>['Voice'],
                  tags: const <String>['ASMR'],
                  releaseDate: DateTime(2024, 5, 6),
                  salesCount: 1234,
                  rating: 4.5,
                ),
                tracks: <MusicTrack>[],
              ),
              AudioLibraryCategoryEntry(
                target: const AudioDetailTarget(
                  targetType: AudioDetailTargetType.libraryRootFolder,
                  targetPath: '/library/Missing',
                ),
                title: 'Missing',
                path: '/library/Missing',
                isFolder: true,
                detail: AudioDetail.empty(
                  const AudioDetailTarget(
                    targetType: AudioDetailTargetType.libraryRootFolder,
                    targetPath: '/library/Missing',
                  ),
                ),
                tracks: const <MusicTrack>[],
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('${languageProvider.tr('batch_metadata_any_missing')} (1)'),
        findsOneWidget,
      );
      expect(
        find.text('${languageProvider.tr('batch_metadata_no_metadata')} (1)'),
        findsOneWidget,
      );
      expect(
        find.text('${languageProvider.tr('batch_metadata_has_rj_code')} (1)'),
        findsOneWidget,
      );
      expect(
        find.text('${languageProvider.tr('batch_metadata_all')} (2)'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<RadioGroup<Object?>>(
              find.byKey(const ValueKey('batch_metadata_scope_group')),
            )
            .groupValue
            .toString(),
        contains('anyMissing'),
      );
    },
  );

  testWidgets(
    'batch metadata page defaults to all data scope when initialScope is set to all',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: fixture.runtimeGraph,
          persistenceRepository: fixture.persistenceRepository,
          nativePlaybackRepository: fixture.nativePlaybackRepository,
          playbackCommandRunner:
              AppRuntimeWidgetTestFixture.playbackCommandRunner,
          libraryService: fixture.libraryService,
          playbackService: fixture.playbackService,
          timerService: fixture.timerService,
          notificationCoordinatorService:
              fixture.notificationCoordinatorService,
          settingsRepository: fixture.settings,
          languageProvider: fixture.languageProvider,
          child: const DlsiteMetadataBatchPage(
            entries: [],
            initialScope: DlsiteMetadataBatchScope.all,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester
            .widget<RadioGroup<Object?>>(
              find.byKey(const ValueKey('batch_metadata_scope_group')),
            )
            .groupValue,
        DlsiteMetadataBatchScope.all,
      );
    },
  );

  testWidgets(
    'batch metadata page directly shows real setup view without skeleton when entries omitted',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: fixture.runtimeGraph,
          persistenceRepository: fixture.persistenceRepository,
          nativePlaybackRepository: fixture.nativePlaybackRepository,
          playbackCommandRunner:
              AppRuntimeWidgetTestFixture.playbackCommandRunner,
          libraryService: fixture.libraryService,
          playbackService: fixture.playbackService,
          timerService: fixture.timerService,
          notificationCoordinatorService:
              fixture.notificationCoordinatorService,
          settingsRepository: fixture.settings,
          languageProvider: fixture.languageProvider,
          child: const DlsiteMetadataBatchPage(),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('batch_metadata_scope_group')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('batch_metadata_start')),
        findsOneWidget,
      );
      expect(find.byType(OperationSkeletonList), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('batch_metadata_scope_group')),
        findsOneWidget,
      );
      expect(find.byType(OperationSkeletonList), findsNothing);
    },
  );

  testWidgets('metadata review batch mode shows navigation with count and confirm action', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final fixture = AppRuntimeWidgetTestFixture(
      dlsiteMetadataService: _FakeDlsiteMetadataService(),
      asmrMetadataService: _FakeAsmrMetadataService(),
    );
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;
    DlsiteMetadataReviewResult? completion;

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: DlsiteMetadataReviewPage(
          detail: AudioDetail.empty(
            const AudioDetailTarget(
              targetType: AudioDetailTargetType.libraryRootFolder,
              targetPath:
                  '/library/A very long folder name that wraps across multiple lines so the floating title surface must size itself before the metadata content begins below it',
            ),
          ),
          rjCode: 'RJ123456',
          batchIndex: 2,
          batchTotal: 3,
          allowSkip: true,
          canNavigatePrevious: true,
          canNavigateNext: true,
          onBatchNavigate: (_) {},
          onCompleted: (result) {
            completion = result;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text(languageProvider.tr('dlsite_review_title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dlsite_review_header')),
      findsOneWidget,
    );
    final confirm = find.byKey(const ValueKey<String>('dlsite_review_confirm'));
    expect(confirm, findsOneWidget);
    final skip = find.byKey(const ValueKey<String>('dlsite_review_skip'));
    expect(skip, findsNothing);
    expect(
      find.descendant(of: find.byType(ListView), matching: confirm),
      findsNothing,
    );
    final previousWork = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('dlsite_review_previous_work')),
    );
    final nextWork = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('dlsite_review_next_work')),
    );
    expect(previousWork.onPressed, isNotNull);
    expect(nextWork.onPressed, isNotNull);
    final workNavigation = find.byKey(
      const ValueKey<String>('dlsite_review_work_navigation'),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('dlsite_review_header')),
        matching: workNavigation,
      ),
      findsNothing,
    );
    expect(workNavigation, findsOneWidget);
    expect(
      find.descendant(of: workNavigation, matching: find.text('2/3')),
      findsOneWidget,
    );
    expect(
      tester.getCenter(workNavigation).dx,
      lessThan(tester.getCenter(find.byType(DlsiteMetadataReviewPage)).dx),
    );
    expect(
      tester.getCenter(confirm).dx,
      greaterThan(tester.getCenter(find.byType(DlsiteMetadataReviewPage)).dx),
    );
    expect(
      (tester.getBottomLeft(workNavigation).dy -
              tester.getBottomRight(confirm).dy)
          .abs(),
      lessThan(1.0),
    );
    final targetName = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('dlsite_review_target_name')),
        matching: find.byType(Text),
      ),
    );
    expect(targetName.maxLines, 3);
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('dlsite_review_target_name')),
          )
          .height,
      greaterThan(44),
    );
    await tester.tap(confirm);
    await tester.pump();
    expect(completion?.isConfirmed, isTrue);
    expect(completion?.metadata?.workTitle, 'ASMR fetched title');
    expect(
      tester
              .getRect(
                find.text(languageProvider.tr('audio_detail_work_title')),
              )
              .top -
          tester
              .getRect(
                find.byKey(const ValueKey<String>('dlsite_review_target_name')),
              )
              .bottom,
      greaterThanOrEqualTo(8),
    );
    expect(
      find.text(languageProvider.tr('audio_detail_release_date')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('audio_detail_sales_count')),
      findsNothing,
    );
    final visibleTextFieldValues = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .whereType<String>()
        .toSet();
    expect(visibleTextFieldValues, contains('ASMR fetched title'));
    expect(visibleTextFieldValues, contains('Circle'));
    expect(visibleTextFieldValues, contains('2024-05-06'));
    expect(visibleTextFieldValues, contains('01:02:03'));
    expect(visibleTextFieldValues, isNot(contains('1234')));

    await tester.dragUntilVisible(
      find.text(languageProvider.tr('audio_detail_rating')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.text(languageProvider.tr('audio_detail_rating')),
      findsOneWidget,
    );
    final ratingField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText ==
                languageProvider.tr('audio_detail_rating'),
      ),
    );
    expect(ratingField.controller?.text, '4.5');
  });

  testWidgets(
    'metadata review batch navigation updates in place without flashing skeleton or dropping confirm action',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final fixture = AppRuntimeWidgetTestFixture();
      final metadataWork1 = DlsiteMetadata(
        rjCode: 'RJ111111',
        workTitle: 'Work One Title',
        circleName: 'Circle One',
        voiceActors: const <String>['Voice One'],
        tags: const <String>['Tag One'],
      );
      final metadataWork2 = DlsiteMetadata(
        rjCode: 'RJ222222',
        workTitle: 'Work Two Title',
        circleName: 'Circle Two',
        voiceActors: const <String>['Voice Two'],
        tags: const <String>['Tag Two'],
      );

      Widget buildReview({
        required int index,
        required AudioDetailTarget target,
        required DlsiteMetadata metadata,
      }) {
        return fixture.build(
          DlsiteMetadataReviewPage(
            key: const ValueKey<String>('dlsite_metadata_batch_review_page'),
            detail: AudioDetail.empty(target),
            batchIndex: index,
            batchTotal: 2,
            initialCandidates: <DlsiteMetadata>[metadata],
            canNavigatePrevious: index > 1,
            canNavigateNext: index < 2,
            onBatchNavigate: (_) {},
          ),
        );
      }

      await tester.pumpWidget(
        buildReview(
          index: 1,
          target: const AudioDetailTarget(
            targetType: AudioDetailTargetType.libraryRootFolder,
            targetPath: '/library/FolderOne',
          ),
          metadata: metadataWork1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Work One Title'), findsOneWidget);
      expect(find.byType(OperationSkeletonList), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dlsite_review_confirm')),
        findsOneWidget,
      );
      expect(find.text('1/2'), findsOneWidget);

      // Simulate switching to Work 2
      await tester.pumpWidget(
        buildReview(
          index: 2,
          target: const AudioDetailTarget(
            targetType: AudioDetailTargetType.libraryRootFolder,
            targetPath: '/library/FolderTwo',
          ),
          metadata: metadataWork2,
        ),
      );
      await tester.pump();

      // Immediately after the single pump (first frame of the switch):
      expect(find.byType(OperationSkeletonList), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dlsite_review_confirm')),
        findsOneWidget,
      );
      expect(find.text('Work Two Title'), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('FolderTwo'), findsOneWidget);
    },
  );

  testWidgets(
    'metadata editor shows compact cover navigation and cover state below image',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _DetailCoverCacheService(
          candidates: const <String>[
            '/covers/current.jpg',
            '/covers/alternate.jpg',
          ],
          currentCoverPath: '/covers/current.jpg',
        ),
      );
      addTearDown(fixture.dispose);
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: '/library/EditableWork',
      );

      await tester.pumpWidget(
        fixture.build(
          DlsiteMetadataReviewPage.edit(detail: AudioDetail.empty(target)),
        ),
      );

      final capsule = find.byKey(
        const ValueKey<String>('audio_detail_cover_navigation_capsule'),
      );
      for (var i = 0; i < 40 && capsule.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(capsule, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('audio_detail_cover_prev_button')),
        findsOneWidget,
      );
      final nextButton = find.byKey(
        const ValueKey<String>('audio_detail_cover_next_button'),
      );
      expect(nextButton, findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('audio_detail_current_cover')),
        findsOneWidget,
      );
      expect(
        find.text(
          fixture.languageProvider.tr('audio_detail_cover_swipe_hint'),
        ),
        findsNothing,
      );
      final actionCapsule = find.byKey(
        const ValueKey<String>('audio_detail_cover_action_capsule'),
      );
      expect(actionCapsule, findsOneWidget);
      final currentCoverLabel = tester.widget<Text>(
        find.text(fixture.languageProvider.tr('audio_detail_current_cover')),
      );
      expect(currentCoverLabel.style?.color, Colors.grey.shade400);
      expect(
        tester.widget<InkWell>(
          find.descendant(of: actionCapsule, matching: find.byType(InkWell)),
        ).onTap,
        isNull,
      );
      expect(
        find.ancestor(
          of: actionCapsule,
          matching: find.byKey(
            const ValueKey<String>('audio_detail_cover_content'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester.getCenter(actionCapsule).dx,
        lessThan(tester.getCenter(capsule).dx),
      );
      expect(
        tester.getCenter(actionCapsule).dy,
        closeTo(tester.getCenter(capsule).dy, 1),
      );

      await tester.tap(nextButton);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('2/2'), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('audio_detail_set_cover')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.text(fixture.languageProvider.tr('audio_detail_set_cover')),
            )
            .style
            ?.color,
        Colors.white,
      );
    },
  );

  test(
    'preferred title metadata fills missing ASMR fields from DLsite',
    () async {
      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;

      final metadata =
          (await runtimeGraph.library.searchPreferredMetadataByTitles(
            const <String>['Work'],
            language: AppLanguage.zh,
          )).single;

      expect(metadata.workTitle, 'ASMR fetched title');
      expect(metadata.circleName, 'Circle');
      expect(metadata.releaseDate, DateTime(2024, 5, 6));
      expect(
        metadata.duration,
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(metadata.salesCount, 1234);
      expect(metadata.rating, 4.5);
    },
  );

  testWidgets(
    'clearing a manual folder duration saves the calculated track total',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;

      const folderPath = r'C:\library\Work';
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: folderPath,
      );
      runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: r'C:\library\Work\01.mp3',
            displayName: '01',
            groupKey: folderPath,
            groupTitle: 'Work',
            groupSubtitle: folderPath,
            isSingle: false,
            duration: const Duration(minutes: 2),
          ),
          MusicTrack(
            path: r'C:\library\Work\02.mp3',
            displayName: '02',
            groupKey: folderPath,
            groupTitle: 'Work',
            groupSubtitle: folderPath,
            isSingle: false,
            duration: const Duration(minutes: 4),
          ),
        ],
        notify: false,
        persist: false,
      );
      await tester.runAsync(
        () => runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            target,
          ).copyWith(duration: const Duration(minutes: 9)),
        ),
      );

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: const AudioDetailSheet(target: target),
        ),
      );
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final durationLabel = find.text(
        languageProvider.tr('card_info_duration'),
      );
      await tester.ensureVisible(durationLabel);
      await tester.pumpAndSettle();
      final durationRow = find
          .ancestor(of: durationLabel, matching: find.byType(Row))
          .first;
      await tester.tap(
        find.descendant(
          of: durationRow,
          matching: find.byIcon(Icons.edit_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      final saveLabel = MaterialLocalizations.of(
        tester.element(find.byType(AppDialog)),
      ).saveButtonLabel;
      await tester.tap(find.widgetWithText(FilledButton, saveLabel));
      await pumpUntilNotFound(tester, find.byType(AppDialog));
      for (
        var i = 0;
        i < 100 && find.text('00:06:00').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      final saved = await tester.runAsync(
        () => runtimeGraph.library.loadAudioDetail(target),
      );
      expect(saved?.detail.duration, const Duration(minutes: 6));
      expect(
        find.text('00:06:00'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .whereType<String>()
            .join(' | '),
      );
    },
  );

  testWidgets('audio detail renders before automatic duration completes', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;
    final target = AudioDetailTarget.libraryRootFolder('/library/Work');
    await tester.runAsync(
      () => runtimeGraph.library.saveAudioDetail(AudioDetail.empty(target)),
    );
    final durationCompleter = Completer<Duration?>();

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: AudioDetailSheet(
          target: target,
          durationCalculator: (_, _) => durationCompleter.future,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (
      var i = 0;
      i < 20 &&
          find
              .text(languageProvider.tr('asmr_detail_basic_info'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      find.text(languageProvider.tr('asmr_detail_basic_info')),
      findsOneWidget,
    );
    expect(durationCompleter.isCompleted, isFalse);

    durationCompleter.complete(const Duration(minutes: 3));
    await tester.pump();
    // Cover discovery starts after the frame that installs the selector.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  });

  testWidgets(
    'duration calculation failure clears busy state and is retryable',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final target = AudioDetailTarget.libraryRootFolder(
        '/library/DurationError',
      );
      await tester.runAsync(
        () => runtimeGraph.library.saveAudioDetail(AudioDetail.empty(target)),
      );

      await tester.pumpWidget(
        fixture.build(
          AudioDetailSheet(
            target: target,
            durationCalculator: (_, _) async {
              throw StateError('duration probe failed');
            },
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text(
          fixture.languageProvider.tr(
            'audio_detail_duration_calculation_failed',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('audio detail fetch opens metadata scope page', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: '/library/Work',
    );
    await tester.runAsync(
      () => runtimeGraph.library.saveAudioDetail(AudioDetail.empty(target)),
    );

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const AudioDetailSheet(target: target),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    final fetchInfoButton = find.byTooltip(
      languageProvider.tr('audio_detail_fetch_info'),
    );
    final fetchInfoIconButton = find.byKey(
      const ValueKey<String>('audio_detail_fetch_info'),
    );
    final collapseButton = find.byTooltip(
      MaterialLocalizations.of(
        tester.element(find.byType(AudioDetailSheet)),
      ).closeButtonTooltip,
    );
    expect(fetchInfoButton, findsOneWidget);
    expect(fetchInfoIconButton, findsOneWidget);
    expect(collapseButton, findsOneWidget);
    expect(tester.widget<IconButton>(fetchInfoIconButton).style, isNull);
    expect(
      tester.getCenter(fetchInfoButton).dx,
      lessThan(tester.getCenter(collapseButton).dx),
    );
    expect(tester.getSize(fetchInfoButton), const Size.square(48));
    expect(find.byIcon(Icons.drive_file_rename_outline), findsNothing);

    await tester.tap(fetchInfoButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text(languageProvider.tr('audio_detail_fetch_scope_title')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('batch_metadata_all')),
      findsOneWidget,
    );
    expect(
      find.text(languageProvider.tr('metadata_scope_missing')),
      findsOneWidget,
    );
  });

  for (final closeDuringEntrance in [false, true]) {
    testWidgets(
      'editor defers cover discovery during Windows entrance and '
      '${closeDuringEntrance ? 'cancels it on close' : 'starts it after navigation'}',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        final observer = UiInteractionNavigatorObserver();
        final covers = _DetailCoverCacheService(
          currentCoverPath: '/covers/current.jpg',
        );
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: covers,
        );
        addTearDown(() {
          observer.dispose();
          fixture.dispose();
          interaction.resetForTest();
          debugDefaultTargetPlatformOverride = null;
        });
        await tester.pumpWidget(
          fixture.build(
            const SizedBox.shrink(),
            navigatorObservers: [observer],
          ),
        );
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            buildAppPageRoute<void>(
              context: navigator.context,
              child: DlsiteMetadataReviewPage.edit(
                detail: AudioDetail.empty(
                  const AudioDetailTarget(
                    targetType: AudioDetailTargetType.libraryRootFolder,
                    targetPath: '/library/Work',
                  ),
                ).copyWith(duration: const Duration(minutes: 1)),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(covers.candidateQueries, 0);
        if (closeDuringEntrance) navigator.pop();
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(covers.candidateQueries, closeDuringEntrance ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'library motion: cover navigation retains rapid targets and follows manual dragging ($reduceMotion)',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: _DetailCoverCacheService(
              currentCoverPath: '/covers/0.jpg',
              candidates: [for (var i = 0; i < 5; i++) '/covers/$i.jpg'],
            ),
          );
          addTearDown(fixture.dispose);
          await tester.pumpWidget(
            fixture.build(
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduceMotion),
                  child: const Center(
                    child: SizedBox(
                      width: 300,
                      child: FolderCoverSelector(
                        folderPath: '/library/Work',
                        compactNavigation: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          final viewport = find.byKey(
            const ValueKey('audio_detail_cover_content'),
          );
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          final initialPage = controller.page!.round();
          Future<void> next() async {
            if (platform == TargetPlatform.windows) {
              await tester.sendEventToBinding(
                PointerScrollEvent(
                  position: tester.getCenter(viewport),
                  scrollDelta: const Offset(0, 120),
                ),
              );
            } else {
              await tester.tap(
                find.byKey(const ValueKey('audio_detail_cover_next_button')),
              );
            }
          }

          await next();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          await next();
          await tester.pump();
          if (!reduceMotion) {
            for (
              var i = 0;
              i < 30 && controller.page! < initialPage + 0.6;
              i++
            ) {
              await tester.pump(const Duration(milliseconds: 10));
            }
          }
          await next();
          await tester.pump();
          if (reduceMotion) expect(controller.page, initialPage + 3);
          await tester.pump(const Duration(milliseconds: 300));
          expect(controller.page, initialPage + 3);
          expect(find.text('4/5'), findsOneWidget);
          await next();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          await tester.drag(viewport, const Offset(220, 0));
          await tester.pump(const Duration(milliseconds: 300));
          final draggedPage = controller.page!.round();
          await next();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(controller.page, draggedPage + 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
    testWidgets(
      'library motion: idle cover saves stop scheduling hidden progress frames',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _DetailCoverCacheService(
            currentCoverPath: '/covers/candidate.jpg',
          ),
        );
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          fixture.build(
            const Center(
              child: SizedBox(
                width: 300,
                child: FolderCoverSelector(folderPath: '/library/Work'),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('folder cover remains visible while candidates load or fail', (
    WidgetTester tester,
  ) async {
    final candidates = Completer<List<String>>();
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _DetailCoverCacheService(
        currentCoverPath: '/covers/current.jpg',
        candidatesFuture: candidates.future,
      ),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(
        const Center(
          child: SizedBox(
            width: 300,
            child: FolderCoverSelector(folderPath: '/library/Work'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<RetryingFileImage>(find.byType(RetryingFileImage)).path,
      '/covers/current.jpg',
    );
    candidates.completeError(StateError('candidate scan failed'));
    await tester.pump();
    expect(find.byType(RetryingFileImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder cover path resolves without a second loading fade', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _DetailCoverCacheService(
        currentCoverPath: '/covers/current.jpg',
      ),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(
        const Center(
          child: SizedBox(
            width: 300,
            child: FolderCoverSelector(folderPath: '/library/Work'),
          ),
        ),
      ),
    );
    final placeholder = find.byKey(
      const ValueKey('audio_detail_cover_placeholder'),
    );
    expect(placeholder, findsOneWidget);
    expect(
      find.descendant(
        of: placeholder,
        matching: find.byType(CoverFallbackArtwork),
      ),
      findsOneWidget,
    );

    await tester.pump();
    expect(placeholder, findsNothing);
    expect(find.byKey(const ValueKey('audio_detail_cover_content')),
        findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(RetryingFileImage),
        matching: find.byType(AnimatedSwitcher),
      ),
      findsNothing,
    );
  });

  testWidgets('Windows wheel advances folder cover candidates', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _DetailCoverCacheService(
        currentCoverPath: '/covers/first.jpg',
        candidates: const <String>[
          '/covers/first.jpg',
          '/covers/second.jpg',
        ],
      ),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(
        const Center(
          child: SizedBox(
            width: 300,
            child: FolderCoverSelector(folderPath: '/library/Work'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.childrenDelegate.estimatedChildCount, isNull);
    final initialPage = pageView.controller!.page!;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(
          find.byKey(const ValueKey('audio_detail_cover_content')),
        ),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(pageView.controller!.page, initialPage + 1);

    // Wheel down again cycles from last image back to first image
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(
          find.byKey(const ValueKey('audio_detail_cover_content')),
        ),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(pageView.controller!.page, initialPage + 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('audio detail cover action uses the primary button color', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _DetailCoverCacheService(),
    );
    addTearDown(fixture.dispose);
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: '/library/Work',
    );
    await tester.runAsync(
      () => fixture.runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target),
      ),
    );

    await tester.pumpWidget(
      fixture.build(const AudioDetailSheet(target: target)),
    );
    final label = fixture.languageProvider.tr('audio_detail_set_cover');
    final button = find.widgetWithText(FilledButton, label);
    for (var i = 0; i < 40 && button.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    _expectPrimaryFilledButton(tester, button);
  });

  testWidgets('single audio detail omits the title rename action', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.singleAudioFile,
      targetPath: '/library/track.mp3',
    );
    await tester.runAsync(
      () => fixture.runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target),
      ),
    );

    await tester.pumpWidget(
      fixture.build(const AudioDetailSheet(target: target)),
    );
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byIcon(Icons.drive_file_rename_outline), findsNothing);
  });

  testWidgets(
    'windows audio detail shows prev/next buttons when folder has multiple covers',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      try {
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _DetailCoverCacheService(
            candidates: const <String>[
              '/covers/c1.jpg',
              '/covers/c2.jpg',
              '/covers/c3.jpg',
            ],
          ),
        );
        addTearDown(fixture.dispose);
        const target = AudioDetailTarget(
          targetType: AudioDetailTargetType.libraryRootFolder,
          targetPath: '/library/MultiCoverWork',
        );
        await tester.runAsync(
          () => fixture.runtimeGraph.library.saveAudioDetail(
            AudioDetail.empty(target),
          ),
        );

        await tester.pumpWidget(
          fixture.build(const AudioDetailSheet(target: target)),
        );

        final nextButtonFinder = find.byKey(
          const ValueKey<String>('audio_detail_cover_next_button'),
        );
        final prevButtonFinder = find.byKey(
          const ValueKey<String>('audio_detail_cover_prev_button'),
        );

        for (var i = 0; i < 40 && nextButtonFinder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(nextButtonFinder, findsOneWidget);
        expect(prevButtonFinder, findsOneWidget);

        // Initially at index 0: both prev and next are enabled for cycling
        final prevBtn0 = tester.widget<IconButton>(prevButtonFinder);
        final nextBtn0 = tester.widget<IconButton>(nextButtonFinder);
        expect(prevBtn0.onPressed, isNotNull);
        expect(nextBtn0.onPressed, isNotNull);

        // Tap prev button at index 0 -> cycles to last cover (index 2) with animation
        await tester.tap(prevButtonFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('3 / 3'), findsOneWidget);
        final prevBtnLast = tester.widget<IconButton>(prevButtonFinder);
        final nextBtnLast = tester.widget<IconButton>(nextButtonFinder);
        expect(prevBtnLast.onPressed, isNotNull);
        expect(nextBtnLast.onPressed, isNotNull);

        // Tap next button at last cover -> cycles back to first cover (index 0) with animation
        await tester.tap(nextButtonFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('1 / 3'), findsOneWidget);

        // Tap next button -> index 1
        await tester.tap(nextButtonFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('2 / 3'), findsOneWidget);
        final prevBtn1 = tester.widget<IconButton>(prevButtonFinder);
        final nextBtn1 = tester.widget<IconButton>(nextButtonFinder);
        expect(prevBtn1.onPressed, isNotNull);
        expect(nextBtn1.onPressed, isNotNull);

        // Tap next button -> index 2
        await tester.tap(nextButtonFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('3 / 3'), findsOneWidget);
        final prevBtn2 = tester.widget<IconButton>(prevButtonFinder);
        final nextBtn2 = tester.widget<IconButton>(nextButtonFinder);
        expect(prevBtn2.onPressed, isNotNull);
        expect(nextBtn2.onPressed, isNotNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'android audio detail hides prev/next buttons even when multiple covers exist',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      try {
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _DetailCoverCacheService(
            candidates: const <String>[
              '/covers/c1.jpg',
              '/covers/c2.jpg',
            ],
          ),
        );
        addTearDown(fixture.dispose);
        const target = AudioDetailTarget(
          targetType: AudioDetailTargetType.libraryRootFolder,
          targetPath: '/library/MultiCoverWorkAndroid',
        );
        await tester.runAsync(
          () => fixture.runtimeGraph.library.saveAudioDetail(
            AudioDetail.empty(target),
          ),
        );

        await tester.pumpWidget(
          fixture.build(const AudioDetailSheet(target: target)),
        );

        final loadedContent = find.byKey(
          const ValueKey<String>('audio_detail_cover_content'),
        );
        for (var i = 0; i < 40 && loadedContent.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(
          find.byKey(const ValueKey<String>('audio_detail_cover_next_button')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('audio_detail_cover_prev_button')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('single audio detail loads embedded cover for file', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: _DetailCoverCacheService(
        embeddedCoverPath: '/cache/embedded_sample.jpg',
      ),
    );
    addTearDown(fixture.dispose);
    const target = AudioDetailTarget(
      targetType: AudioDetailTargetType.singleAudioFile,
      targetPath: '/library/track_with_embedded.flac',
    );
    await tester.runAsync(
      () => fixture.runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target),
      ),
    );

    await tester.pumpWidget(
      fixture.build(const AudioDetailSheet(target: target)),
    );
    final loadedCover = find.byKey(
      const ValueKey<String>('audio_detail_single_cover_loaded'),
    );
    for (var i = 0; i < 40 && loadedCover.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(loadedCover, findsOneWidget);
  });

  group('resolveWorkFolderDestination', () {
    test('resolves local library root folder', () {
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: 'D:\\Audio\\Works\\RJ123456',
      );
      final resolved = resolveWorkFolderDestination(target);
      expect(resolved.destinationRoot, 'D:\\Audio\\Works');
      expect(resolved.workFolderName, 'RJ123456');

      final snapshot = AsmrDownloadTaskSnapshot(
        work: _testWork(sourceId: 'RJ123456', title: 'Work Title'),
        destinationRoot: resolved.destinationRoot,
        workFolderName: resolved.workFolderName,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveCover: true,
        automaticFileRetryCount: 3,
        status: AsmrDownloadTaskStatus.idle,
        totalFiles: 0,
        completedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 0,
        downloadedBytes: 0,
        startedAt: DateTime.now(),
      );
      expect(
        snapshot.workRootPath,
        path.join('D:\\Audio\\Works', 'RJ123456'),
      );
    });

    test('resolves local single audio file to its parent folder', () {
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.singleAudioFile,
        targetPath: 'D:\\Audio\\Works\\RJ123456\\track01.mp3',
      );
      final resolved = resolveWorkFolderDestination(target);
      expect(resolved.destinationRoot, 'D:\\Audio\\Works');
      expect(resolved.workFolderName, 'RJ123456');
    });

    test('resolves Android SAF content URI with :: and subfolder', () {
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath:
            'content://com.android.externalstorage.documents/tree/1234-5678%3A/document/1234-5678%3A::ASMR/RJ123456',
      );
      final resolved = resolveWorkFolderDestination(target);
      expect(
        resolved.destinationRoot,
        'content://com.android.externalstorage.documents/tree/1234-5678%3A/document/1234-5678%3A::ASMR',
      );
      expect(resolved.workFolderName, 'RJ123456');

      final snapshot = AsmrDownloadTaskSnapshot(
        work: _testWork(sourceId: 'RJ123456', title: 'Work Title'),
        destinationRoot: resolved.destinationRoot,
        workFolderName: resolved.workFolderName,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveCover: true,
        automaticFileRetryCount: 3,
        status: AsmrDownloadTaskStatus.idle,
        totalFiles: 0,
        completedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 0,
        downloadedBytes: 0,
        startedAt: DateTime.now(),
      );
      expect(
        snapshot.workRootPath,
        'content://com.android.externalstorage.documents/tree/1234-5678%3A/document/1234-5678%3A::ASMR/RJ123456',
      );
    });

    test('resolves Android SAF content URI with :: at root', () {
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath:
            'content://com.android.externalstorage.documents/tree/1234-5678%3A/document/1234-5678%3A::RJ123456',
      );
      final resolved = resolveWorkFolderDestination(target);
      expect(
        resolved.destinationRoot,
        'content://com.android.externalstorage.documents/tree/1234-5678%3A/document/1234-5678%3A',
      );
      expect(resolved.workFolderName, 'RJ123456');

      final snapshot = AsmrDownloadTaskSnapshot(
        work: _testWork(sourceId: 'RJ123456', title: 'Work Title'),
        destinationRoot: resolved.destinationRoot,
        workFolderName: resolved.workFolderName,
        conflictPolicy: AsmrDownloadConflictPolicy.overwrite,
        saveCover: true,
        automaticFileRetryCount: 3,
        status: AsmrDownloadTaskStatus.idle,
        totalFiles: 0,
        completedFiles: 0,
        skippedFiles: 0,
        failedFiles: 0,
        totalBytes: 0,
        downloadedBytes: 0,
        startedAt: DateTime.now(),
      );
      expect(
        snapshot.workRootPath,
        'content://com.android.externalstorage.documents/tree/1234-5678%3A/document/1234-5678%3A::RJ123456',
      );
    });
  });

  testWidgets(
    'audio detail sheet does not have download button',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: '/library/SimpleWorkWithoutRj',
      );
      await tester.runAsync(
        () => fixture.runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(target).copyWith(workTitle: 'Plain Audio'),
        ),
      );

      await tester.pumpWidget(
        fixture.build(const AudioDetailSheet(target: target)),
      );

      final downloadBtn = find.byKey(
        const ValueKey<String>('audio_detail_download_asmr'),
      );
      final fetchInfoBtn = find.byKey(
        const ValueKey<String>('audio_detail_fetch_info'),
      );

      for (var i = 0; i < 40 && downloadBtn.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        find.byKey(const ValueKey<String>('audio_detail_download_asmr')),
        findsNothing,
      );
      expect(fetchInfoBtn, findsOneWidget);
    },
  );

  testWidgets(
    'metadata review and edit headers align title capsule with full page width when trailing is absent',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: _FakeDlsiteMetadataService(),
        asmrMetadataService: _FakeAsmrMetadataService(),
      );
      addTearDown(fixture.dispose);

      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.libraryRootFolder,
        targetPath: '/library/TestWork',
      );

      // 1. Edit mode: trailing is absent, title capsule must align with target name surface on right
      await tester.pumpWidget(
        fixture.build(
          DlsiteMetadataReviewPage.edit(detail: AudioDetail.empty(target)),
        ),
      );
      await tester.pump();

      final editTitleSurface = find.ancestor(
        of: find.text(fixture.languageProvider.tr('audio_detail_edit_info')),
        matching: find.byType(HeaderFloatingSurface),
      );
      final editTargetSurface = find.byKey(
        const ValueKey<String>('dlsite_review_target_name'),
      );
      expect(editTitleSurface, findsOneWidget);
      expect(editTargetSurface, findsOneWidget);
      expect(
        tester.getRect(editTitleSurface).right,
        tester.getRect(editTargetSurface).right,
      );

      // 2. Fetch mode: without extra candidates, trailing is absent and must also align
      await tester.pumpWidget(
        fixture.build(
          DlsiteMetadataReviewPage(
            detail: AudioDetail.empty(target),
            rjCode: 'RJ123456',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final fetchTitleSurface = find.ancestor(
        of: find.text(fixture.languageProvider.tr('dlsite_review_title')),
        matching: find.byType(HeaderFloatingSurface),
      );
      final fetchTargetSurface = find.byKey(
        const ValueKey<String>('dlsite_review_target_name'),
      );
      expect(fetchTitleSurface, findsOneWidget);
      expect(fetchTargetSurface, findsOneWidget);
      expect(
        tester.getRect(fetchTitleSurface).right,
        tester.getRect(fetchTargetSurface).right,
      );
    },
  );
}

AsmrWork _testWork({
  required String sourceId,
  required String title,
}) {
  return AsmrWork(
    id: sourceId.hashCode,
    title: title,
    circleName: 'Circle',
    sourceId: sourceId,
    sourceType: 'asmr',
    sourceUrl: '',
    coverUrl: 'https://example.com/cover.jpg',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: null,
    createDate: null,
    duration: Duration.zero,
    dlCount: 0,
    reviewCount: 0,
    rating: 0,
    voiceActors: const <String>['Voice'],
    tags: const <String>['ASMR'],
  );
}
