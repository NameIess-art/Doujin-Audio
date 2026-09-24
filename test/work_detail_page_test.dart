import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/library/presentation/work_image_viewer_page.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'support/app_runtime_test_fixture.dart';
import 'support/test_playback_commands.dart';

class _WorkDetailAsmrMetadataService extends AsmrMetadataService {
  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.zh,
  }) async {
    return DlsiteMetadata(
      rjCode: rjCode,
      workTitle: 'Fetched work title',
      circleName: 'Fetched circle',
      voiceActors: const <String>[],
      tags: const <String>[],
    );
  }
}

class _WorkDetailFileGateway extends Fake implements FileCachePlatformGateway {
  _WorkDetailFileGateway(this.textFile);

  final File textFile;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    return [
      {'name': 'notes.txt', 'relativePath': 'notes.txt', 'path': textFile.path},
    ];
  }
}

class _NestedWorkDetailFileGateway extends Fake
    implements FileCachePlatformGateway {
  _NestedWorkDetailFileGateway(this.entries);

  final List<Map<String, String>> entries;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    return entries;
  }
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

  group('WorkDetailPage', () {
    testWidgets(
      'local tree shows folders containing only text or image files',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final root = (await tester.runAsync<Directory>(
          () => Directory.systemTemp.createTemp('work_non_audio_folders_'),
        ))!;
        addTearDown(() async {
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
          try {
            if (await root.exists()) await root.delete(recursive: true);
          } on FileSystemException {
            // A failed assertion can leave the image decoder alive briefly.
          }
        });
        final textDirectory = Directory(
          '${root.path}${Platform.pathSeparator}Scripts',
        );
        final imageDirectory = Directory(
          '${root.path}${Platform.pathSeparator}Gallery',
        );
        final textFile = File(
          '${textDirectory.path}${Platform.pathSeparator}notes.txt',
        );
        final imageFile = File(
          '${imageDirectory.path}${Platform.pathSeparator}cover.jpg',
        );
        await tester.runAsync(() async {
          await textDirectory.create();
          await imageDirectory.create();
          await textFile.writeAsString('notes');
          await imageFile.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
        });
        fixture.library.addWatchedFolder(root.path, notify: false);

        await tester.pumpWidget(
          fixture.build(
            WorkDetailPage.forLocal(
              target: AudioDetailTarget.libraryRootFolder(root.path),
            ),
            overrides: [
              workTextServiceProvider.overrideWithValue(
                WorkTextService(
                  platformGateway: _NestedWorkDetailFileGateway([
                    {
                      'name': 'notes.txt',
                      'relativePath': 'Scripts/notes.txt',
                      'path': textFile.path,
                    },
                  ]),
                ),
              ),
            ],
          ),
        );

        for (
          var i = 0;
          i < 40 && find.text('Scripts').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        expect(find.text('Scripts'), findsOneWidget);
        expect(find.text('Gallery'), findsOneWidget);

        final folderMore = find.byKey(
          const ValueKey<String>('work_entry_more_Scripts'),
        );
        expect(folderMore, findsOneWidget);
        await tester.tap(folderMore);
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.text(fixture.languageProvider.tr('rename')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('audio_detail_rename_file')),
          findsNothing,
        );
        await tester.tapAt(Offset.zero);
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('Scripts'));
        await tester.pumpAndSettle();
        expect(find.text('notes.txt'), findsOneWidget);

        await tester.tap(
          find.text(fixture.languageProvider.tr('root_directory')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Gallery'));
        await tester.pumpAndSettle();
        expect(find.text('cover.jpg'), findsOneWidget);
      },
    );

    testWidgets('local text and image entries use contextual more menus', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final root = (await tester.runAsync<Directory>(
        () => Directory.systemTemp.createTemp('work_actions_'),
      ))!;
      addTearDown(() async {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } on FileSystemException {
          // A failed assertion can leave the image decoder alive briefly.
        }
      });
      final textFile = File('${root.path}${Platform.pathSeparator}notes.txt');
      final imageFile = File('${root.path}${Platform.pathSeparator}cover.jpg');
      await tester.runAsync(() async {
        await textFile.writeAsString('notes');
        await imageFile.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);
      });
      fixture.library.addWatchedFolder(root.path, notify: false);
      final target = AudioDetailTarget.libraryRootFolder(root.path);

      await tester.pumpWidget(
        fixture.build(
          WorkDetailPage.forLocal(target: target),
          overrides: [
            workTextServiceProvider.overrideWithValue(
              WorkTextService(
                platformGateway: _WorkDetailFileGateway(textFile),
              ),
            ),
          ],
        ),
      );
      for (
        var i = 0;
        i < 40 && find.text('notes.txt').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      final textMore = find.byKey(
        const ValueKey<String>('work_entry_more_notes.txt'),
      );
      final imageMore = find.byKey(
        const ValueKey<String>('work_entry_more_cover.jpg'),
      );
      expect(textMore, findsOneWidget);
      expect(imageMore, findsOneWidget);

      await tester.tap(imageMore);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text(fixture.languageProvider.tr('rename')), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('audio_detail_set_cover')),
        findsOneWidget,
      );
      await tester.tapAt(Offset.zero);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(textMore);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text(fixture.languageProvider.tr('audio_detail_set_cover')),
        findsNothing,
      );
      expect(find.text(fixture.languageProvider.tr('rename')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });

    testWidgets(
      'audio and video menus add one item without starting playback and remove with undo',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        var prepareCount = 0;
        var playSucceeds = true;
        fixture.playback.detachCommandPort();
        fixture.playback.attachPlaybackCommands(
          prepareSession:
              (
                session, {
                required nextPath,
                autoPlay = true,
                forceStartAtZero = false,
                showLoading = true,
                targetQueueIndex,
              }) async {
                prepareCount++;
                session.currentTrackPath = nextPath;
                return playSucceeds;
              },
          pauseSession: (_) async {},
          startSession: (_, {required shouldStartTriggerCountdown}) async =>
              true,
          resolveAdvance: (_, {required forward}) => null,
          hasAdjacent: (_, {required forward}) => false,
        );
        await tester.binding.setSurfaceSize(const Size(1000, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const folderPath = '/library/menu-work';
        const target = AudioDetailTarget(
          targetType: AudioDetailTargetType.libraryRootFolder,
          targetPath: folderPath,
        );
        final tracks = [
          for (final video in [false, true])
            MusicTrack(
              path: '$folderPath/${video ? 'video.mp4' : 'audio.mp3'}',
              displayName: video ? 'Video entry' : 'Audio entry',
              groupKey: folderPath,
              groupTitle: 'Menu work',
              groupSubtitle: '',
              isSingle: false,
              isVideo: video,
            ),
        ];
        fixture.library.addWatchedFolder(folderPath, notify: false);
        fixture.library.addTracks(tracks, persist: false);
        await tester.pumpWidget(
          fixture.build(const WorkDetailPage.forLocal(target: target)),
        );
        for (
          var i = 0;
          i < 40 && find.text('Audio entry').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(find.text('Audio entry'), findsOneWidget);
        expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
        expect(find.byIcon(Icons.more_vert_rounded), findsNWidgets(2));
        final more = find.byKey(
          ValueKey('work_entry_more_${tracks.first.path}'),
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(find.text(fixture.languageProvider.tr('play')), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('rename')),
          findsOneWidget,
        );
        await tester.tap(
          find.text(fixture.languageProvider.tr('detail_add_to_queue')),
        );
        await tester.pumpAndSettle();
        expect(fixture.playback.sessions.length, 1);
        expect(fixture.playback.sessions.values.single.isTemporary, isFalse);
        expect(
          fixture.playback.sessions.values.single.effectivePlaying,
          isFalse,
        );
        expect(
          fixture.playback.sessions.values.single.currentTrackPath,
          tracks.first.path,
        );
        expect(prepareCount, 0);

        await tester.tap(find.text('Video entry'));
        await tester.pumpAndSettle();
        expect(prepareCount, 1);
        expect(fixture.playback.sessions.length, 2);
        final temporary = fixture.playback.sessions.values.singleWhere(
          (session) => session.isTemporary,
        );
        expect(temporary.currentTrackPath, tracks.last.path);
        expect(temporary.customQueueTracks?.length, 2);

        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.text(fixture.languageProvider.tr('remove')));
        await tester.pumpAndSettle();
        expect(find.text('Audio entry'), findsNothing);
        expect(find.text('Video entry'), findsOneWidget);
        await fixture.undoableRemovalService.undoPending();
        await tester.pumpAndSettle();
        expect(find.text('Audio entry'), findsOneWidget);
        playSucceeds = false;
        await tester.tap(find.text('Video entry'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(prepareCount, 2);
        expect(
          find.textContaining(
            fixture.languageProvider.tr('operation_failed_retry'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders local work detail header, pinned RJ row and action buttons',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture(
          asmrMetadataService: _WorkDetailAsmrMetadataService(),
        );
        addTearDown(fixture.dispose);

        const folderPath = r'C:\library\RJ123456 - Test Work';
        const target = AudioDetailTarget(
          targetType: AudioDetailTargetType.libraryRootFolder,
          targetPath: folderPath,
        );

        final detail = AudioDetail(
          target: target,
          rjCode: 'RJ123456',
          workTitle: 'Test Local Work Title',
          circleName: 'Test Circle',
          voiceActors: const <String>['CV Alice', 'CV Bob'],
          tags: const <String>['ASMR', 'Ear Cleaning', 'Whisper'],
        );
        await tester.runAsync(
          () => fixture.runtimeGraph.library.saveAudioDetail(detail),
        );

        await tester.pumpWidget(
          fixture.build(const WorkDetailPage.forLocal(target: target)),
        );
        for (
          var i = 0;
          i < 20 &&
              find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();

        final headerCover = tester.widget<LocalCoverImage>(
          find.byType(LocalCoverImage).first,
        );
        expect(
          coverCacheWidth(
            resolution: fixture.settings.coverImageResolution,
            cacheWidth: headerCover.cacheWidth,
            useDefaultCacheWidth: headerCover.useDefaultCacheWidth,
          ),
          coverCacheWidthForResolution(fixture.settings.coverImageResolution),
          reason: 'The work header must reuse the library card decode size.',
        );
        // Top-left floating back button
        expect(
          find.byKey(const ValueKey<String>('work_detail_back_button')),
          findsOneWidget,
        );
        final editButton = find.byKey(
          const ValueKey<String>('work_detail_edit'),
        );
        expect(editButton, findsOneWidget);
        expect(
          find.descendant(
            of: editButton,
            matching: find.text(fixture.languageProvider.tr('edit')),
          ),
          findsNothing,
        );
        expect(tester.widget<IconButton>(editButton).tooltip, isNotEmpty);
        expect(
          find.ancestor(
            of: editButton,
            matching: find.byType(HeaderFloatingButton),
          ),
          findsOneWidget,
        );
        final backFloatingButton = find.ancestor(
          of: find.byKey(const ValueKey<String>('work_detail_back_button')),
          matching: find.byType(HeaderFloatingButton),
        );
        final editFloatingButton = find.ancestor(
          of: editButton,
          matching: find.byType(HeaderFloatingButton),
        );
        expect(
          tester.getSize(editFloatingButton),
          tester.getSize(backFloatingButton),
        );

        // Title at bottom of cover shows folder name instead of metadata title
        expect(find.text('RJ123456 - Test Work'), findsOneWidget);
        expect(find.text('Test Local Work Title'), findsNothing);

        // Pinned RJ | Circle row
        expect(find.text('RJ123456'), findsOneWidget);
        expect(find.text('Test Circle'), findsOneWidget);

        // CVs & Tags
        expect(find.text('CV Alice'), findsOneWidget);
        expect(find.text('CV Bob'), findsOneWidget);
        expect(find.text('#ASMR'), findsOneWidget);
        expect(find.text('#Ear Cleaning'), findsOneWidget);
        expect(find.text('#Whisper'), findsOneWidget);

        // Local action buttons: 补充信息, 下载
        expect(
          find.byKey(const ValueKey<String>('work_detail_fetch_info')),
          findsOneWidget,
        );
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey<String>('work_detail_fetch_info')),
              )
              .height,
          greaterThanOrEqualTo(46),
        );
        expect(
          find.byKey(const ValueKey<String>('work_detail_download')),
          findsOneWidget,
        );
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey<String>('work_detail_download')),
              )
              .height,
          greaterThanOrEqualTo(46),
        );
        expect(
          find.byKey(const ValueKey<String>('work_detail_pin')),
          findsNothing,
        );

        await tester.tap(editButton);
        await tester.pumpAndSettle();

        expect(find.byType(DlsiteMetadataReviewPage), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('audio_detail_edit_info')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('dlsite_save_cover')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey<String>('dlsite_review_confirm')),
            matching: find.text(fixture.languageProvider.tr('save')),
          ),
          findsOneWidget,
        );

        final fieldKeys = <String>[
          'audio_detail_folder_name',
          'audio_detail_work_title',
          'audio_detail_rj_code',
          'audio_detail_circle_name',
          'audio_detail_voice_actors',
          'audio_detail_tags',
          'audio_detail_release_date',
          'card_info_duration',
          'audio_detail_rating',
        ];
        final editList = find.descendant(
          of: find.byType(DlsiteMetadataReviewPage),
          matching: find.byType(ListView),
        );
        for (final fieldKey in fieldKeys) {
          final field = find.byKey(ValueKey<String>('metadata_edit_$fieldKey'));
          for (var i = 0; i < 20 && field.evaluate().isEmpty; i++) {
            await tester.drag(editList, const Offset(0, -200));
            await tester.pump();
          }
          final textField = tester.widget<TextField>(
            find.descendant(of: field, matching: find.byType(TextField)),
          );
          expect(
            textField.decoration?.labelText,
            fixture.languageProvider.tr(fieldKey),
          );
          if (fieldKey == 'audio_detail_work_title') {
            await tester.enterText(
              find.descendant(of: field, matching: find.byType(TextField)),
              'Edited local work title',
            );
            tester.testTextInput.hide();
            await tester.pump();
          }
        }
        await tester.tap(
          find.byKey(const ValueKey<String>('dlsite_review_confirm')),
        );
        for (
          var i = 0;
          i < 80 && find.byType(DlsiteMetadataReviewPage).evaluate().isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();

        expect(find.byType(WorkDetailPage), findsOneWidget);
        final savedDetail = await tester.runAsync(
          () => fixture.runtimeGraph.library.loadAudioDetail(target),
        );
        expect(savedDetail?.detail.workTitle, 'Edited local work title');

        await tester.tap(
          find.byKey(const ValueKey<String>('work_detail_fetch_info')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(DlsiteMetadataReviewPage), findsOneWidget);
        expect(find.text('Fetched work title'), findsOneWidget);
      },
    );

    testWidgets('renders ASMR.ONE work detail header and actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 9999,
        title: 'ASMR Remote Work Title',
        circleName: 'Remote Circle',
        sourceId: 'RJ9999',
        sourceType: 'asmr',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>['Remote CV'],
        tags: const <String>['Roleplay'],
        hasSubtitle: true,
      );

      await tester.pumpWidget(
        fixture.build(WorkDetailPage.forAsmr(work: asmrWork)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Title & pinned row
      expect(find.text('ASMR Remote Work Title'), findsOneWidget);
      expect(find.text('RJ9999'), findsOneWidget);
      expect(find.text('Remote Circle'), findsOneWidget);
      expect(
        find.text(fixture.languageProvider.tr('asmr_has_subtitle')),
        findsOneWidget,
      );
      final subtitleStatus = find.text(
        fixture.languageProvider.tr('asmr_has_subtitle'),
      );
      final statusCapsule = find.byKey(
        const ValueKey<String>('work_detail_subtitle_status'),
      );
      expect(
        find.ancestor(
          of: subtitleStatus,
          matching: find.byType(HeaderFloatingSurface),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: statusCapsule,
          matching: find.byIcon(Icons.subtitles_rounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(statusCapsule).top,
        tester.getRect(
          find.ancestor(
            of: find.byKey(
              const ValueKey<String>('work_detail_back_button'),
            ),
            matching: find.byType(HeaderFloatingButton),
          ),
        ).top,
      );
      expect(tester.getRect(statusCapsule).right, 304);
      expect(find.text('|'), findsOneWidget);
      expect(tester.widget<Text>(find.text('RJ9999')).style?.fontSize, 13);
      expect(
        tester.widget<Text>(find.text('Remote Circle')).style?.fontSize,
        13,
      );
      final highlightedStyle = tester.widget<Text>(subtitleStatus).style!;
      expect(
        highlightedStyle.color,
        isNot(
          Theme.of(tester.element(subtitleStatus)).colorScheme.onSurfaceVariant,
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('work_detail_edit')),
        findsNothing,
      );

      // CV & tags
      expect(find.text('Remote CV'), findsOneWidget);
      expect(find.text('#Roleplay'), findsOneWidget);
      expect(find.text('根目录'), findsOneWidget);

      // ASMR.ONE buttons: 下载, 收藏/取消收藏
      expect(
        find.byKey(const ValueKey<String>('asmr_work_detail_download')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('asmr_work_detail_favorite')),
        findsOneWidget,
      );
    });

    testWidgets('back button navigates back', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final asmrWork = AsmrWork(
        id: 8888,
        title: 'Nav Work',
        circleName: 'Nav Circle',
        sourceId: 'RJ8888',
        sourceType: 'asmr',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>[],
        tags: const <String>[],
      );

      await tester.pumpWidget(
        fixture.build(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              WorkDetailPage.forAsmr(work: asmrWork),
                        ),
                      );
                    },
                    child: const Text('Go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(fixture.languageProvider.tr('asmr_no_subtitle')),
        findsOneWidget,
      );
      final noSubtitleStatus = find.text(
        fixture.languageProvider.tr('asmr_no_subtitle'),
      );
      expect(
        find.ancestor(
          of: noSubtitleStatus,
          matching: find.byType(HeaderFloatingSurface),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('work_detail_subtitle_status')),
          matching: find.byIcon(Icons.subtitles_off_rounded),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(noSubtitleStatus).style?.color,
        Theme.of(tester.element(noSubtitleStatus)).colorScheme.onSurfaceVariant,
      );

      expect(
        find.byKey(const ValueKey<String>('work_detail_back_button')),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey<String>('work_detail_back_button')),
          matching: find.byType(HeaderFloatingButton),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('work_detail_back_button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Go'), findsOneWidget);
    });

    testWidgets(
      'tags render in capsule style and clicking a tag copies to clipboard',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        final asmrWork = AsmrWork(
          id: 123456,
          title: 'Work with tags',
          circleName: 'Circle',
          sourceId: 'RJ123456',
          sourceType: 'asmr',
          sourceUrl: '',
          coverUrl: '',
          thumbnailUrl: '',
          mainCoverUrl: '',
          releaseDate: null,
          createDate: null,
          duration: Duration.zero,
          dlCount: 0,
          reviewCount: 0,
          rating: 0,
          voiceActors: const <String>['CV1'],
          tags: const <String>['耳かき', '#癒やし'],
        );

        await tester.pumpWidget(
          fixture.build(WorkDetailPage.forAsmr(work: asmrWork)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('#耳かき'), findsOneWidget);
        expect(find.text('#癒やし'), findsOneWidget);

        await tester.tap(find.text('#耳かき'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(copied, contains('耳かき'));

        await tester.tap(find.text('#癒やし'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(copied, contains('癒やし'));
      },
    );
  });

  group('WorkImageViewerPage', () {
    testWidgets(
      'displays images, switches with prev/next, and sets manual cover',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        var coverSelected = '';

        final images = [
          const WorkImageItem(
            name: '01.jpg',
            path: 'path/to/01.jpg',
            relativePath: '01.jpg',
          ),
          const WorkImageItem(
            name: '02.jpg',
            path: 'path/to/02.jpg',
            relativePath: '02.jpg',
          ),
        ];

        await tester.pumpWidget(
          fixture.build(
            WorkImageViewerPage(
              images: images,
              onSetAsCover: (img) async {
                coverSelected = img.path;
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.byKey(const ValueKey<String>('work_image_header')),
          findsOneWidget,
        );
        expect(find.byType(TopPageHeader), findsOneWidget);

        final prevBtn = find.byKey(
          const ValueKey<String>('image_viewer_prev_button'),
        );
        final nextBtn = find.byKey(
          const ValueKey<String>('image_viewer_next_button'),
        );
        expect(prevBtn, findsOneWidget);
        expect(nextBtn, findsOneWidget);

        final prevSurface = find.ancestor(
          of: prevBtn,
          matching: find.byType(HeaderFloatingSurface),
        );
        final nextSurface = find.ancestor(
          of: nextBtn,
          matching: find.byType(HeaderFloatingSurface),
        );
        expect(tester.widget(prevSurface), same(tester.widget(nextSurface)));

        expect(find.text('1 / 2'), findsOneWidget);
        expect(find.text('01.jpg'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('work_image_blurred_backdrop')),
          findsOneWidget,
        );
        final fullscreenPlaceholder = find.byKey(
          const ValueKey<String>('work_image_fullscreen_placeholder'),
        );
        expect(fullscreenPlaceholder, findsOneWidget);
        expect(
          tester.getRect(fullscreenPlaceholder),
          Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio,
        );
        expect(find.byType(ImageFiltered), findsOneWidget);
        final pageView = tester.widget<PageView>(find.byType(PageView));
        expect(pageView.physics, isA<PageScrollPhysics>());
        final foregroundImages = tester.widgetList<RetryingFileImage>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('work_image_viewport')),
            matching: find.byType(RetryingFileImage),
          ),
        );
        expect(foregroundImages, isNotEmpty);
        expect(
          foregroundImages.every((image) => image.fit == BoxFit.contain),
          isTrue,
        );
        expect(
          foregroundImages.every(
            (image) => image.displayMode == CoverImageDisplayMode.fill,
          ),
          isTrue,
        );
        expect(
          tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('work_image_viewport')),
              )
              .dy,
          greaterThanOrEqualTo(
            tester
                    .getBottomLeft(
                      find.byKey(const ValueKey<String>('work_image_header')),
                    )
                    .dy +
                20,
          ),
        );

        expect(
          tester
              .getBottomRight(
                find.byKey(const ValueKey<String>('work_image_viewport')),
              )
              .dy,
          lessThanOrEqualTo(tester.getTopRight(prevBtn).dy - 10),
        );

        // Previous button is disabled at first image (no loop)
        expect(tester.widget<IconButton>(prevBtn).onPressed, isNull);

        // Swipe left switches to next image
        await tester.drag(
          find.byKey(const ValueKey<String>('work_image_viewport')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('02.jpg'), findsOneWidget);

        // Swipe right switches back to previous image
        await tester.drag(
          find.byKey(const ValueKey<String>('work_image_viewport')),
          const Offset(500, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsOneWidget);
        expect(find.text('01.jpg'), findsOneWidget);

        // Next button animates to next image
        await tester.tap(nextBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('02.jpg'), findsOneWidget);

        // Next button is disabled at last image (no loop)
        expect(tester.widget<IconButton>(nextBtn).onPressed, isNull);

        // Set as cover button
        final setCoverBtn = find.byKey(
          const ValueKey<String>('viewer_set_as_cover_button'),
        );
        expect(setCoverBtn, findsOneWidget);
        await tester.tap(setCoverBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(coverSelected, 'path/to/02.jpg');
      },
    );

    testWidgets('double-tap toggles zoom and blocks swiping when zoomed', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      final images = [
        const WorkImageItem(
          name: '01.jpg',
          path: 'path/to/01.jpg',
          relativePath: '01.jpg',
        ),
        const WorkImageItem(
          name: '02.jpg',
          path: 'path/to/02.jpg',
          relativePath: '02.jpg',
        ),
      ];

      await tester.pumpWidget(
        fixture.build(WorkImageViewerPage(images: images)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final viewportFinder = find.byKey(
        const ValueKey<String>('work_image_viewport'),
      );
      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<PageScrollPhysics>(),
      );

      // Double-tap to zoom
      await tester.tap(viewportFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(viewportFinder);
      await tester.pumpAndSettle();

      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );

      // Double-tap to reset zoom
      await tester.tap(viewportFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(viewportFinder);
      await tester.pumpAndSettle();

      expect(
        tester.widget<PageView>(find.byType(PageView)).physics,
        isA<PageScrollPhysics>(),
      );
    });

    testWidgets('loads ASMR image URLs as network images', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.build(
          const WorkImageViewerPage(
            images: [
              WorkImageItem(
                name: 'remote.jpg',
                path: 'https://example.com/remote.jpg',
                relativePath: 'images/remote.jpg',
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(RetryingNetworkImage), findsNWidgets(2));
      expect(find.byType(LocalCoverImage), findsNothing);
      final foregroundImage = tester.widget<RetryingNetworkImage>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('work_image_viewport')),
          matching: find.byType(RetryingNetworkImage),
        ),
      );
      expect(foregroundImage.fit, BoxFit.contain);
      expect(foregroundImage.displayMode, CoverImageDisplayMode.fill);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'WorkDetailPage more menu renders in overlay above playback dock',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final root = (await tester.runAsync<Directory>(
          () => Directory.systemTemp.createTemp('work_dock_menu_'),
        ))!;
        addTearDown(() async {
          try {
            if (await root.exists()) await root.delete(recursive: true);
          } on FileSystemException {
            // A failed assertion can leave the directory locked briefly.
          }
        });
        final textFile = File('${root.path}${Platform.pathSeparator}notes.txt');
        await tester.runAsync(() async {
          await textFile.writeAsString('notes');
        });
        fixture.library.addWatchedFolder(root.path, notify: false);
        final target = AudioDetailTarget.libraryRootFolder(root.path);

        final menuOverlayKey = GlobalKey<OverlayState>();
        await tester.pumpWidget(
          fixture.build(
            MobileOverlayInset(
              bottomInset: 80,
              menuOverlayKey: menuOverlayKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  WorkDetailPage.forLocal(target: target),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 64,
                    child: SizedBox(
                      key: ValueKey<String>('mock_playback_dock'),
                    ),
                  ),
                  Overlay(key: menuOverlayKey),
                ],
              ),
            ),
            overrides: [
              workTextServiceProvider.overrideWithValue(
                WorkTextService(
                  platformGateway: _WorkDetailFileGateway(textFile),
                ),
              ),
            ],
          ),
        );
        for (
          var i = 0;
          i < 40 && find.text('notes.txt').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        final textMore = find.byKey(
          const ValueKey<String>('work_entry_more_notes.txt'),
        );
        expect(textMore, findsOneWidget);
        await tester.tap(textMore);
        await tester.pump(const Duration(milliseconds: 250));

        final menuItem = find.text(fixture.languageProvider.tr('rename'));
        expect(menuItem, findsOneWidget);
        final mockDock = find.byKey(
          const ValueKey<String>('mock_playback_dock'),
        );
        expect(mockDock, findsOneWidget);

        final paintOrder = tester.allWidgets.toList(growable: false);
        expect(
          paintOrder.indexOf(tester.widget(mockDock)),
          lessThan(paintOrder.indexOf(tester.widget(menuItem))),
        );

        await tester.tapAt(Offset.zero);
        await tester.pump(const Duration(milliseconds: 500));
        expect(menuItem, findsNothing);
      },
    );
  });
}
