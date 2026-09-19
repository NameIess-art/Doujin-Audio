import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/presentation/work_text_viewer_page.dart';

class _FakeFileCacheGateway extends Fake implements FileCachePlatformGateway {
  _FakeFileCacheGateway(this.filesMap);

  final Map<String, Uint8List> filesMap;

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async {
    return filesMap[filePath];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const file1 = WorkTextFile(
    name: '01_トラック台本.txt',
    relativePath: '台本/01_トラック台本.txt',
    path: '/works/RJ123/台本/01_トラック台本.txt',
  );
  const file2 = WorkTextFile(
    name: '02_特典台本.txt',
    relativePath: '台本/02_特典台本.txt',
    path: '/works/RJ123/台本/02_特典台本.txt',
  );
  const file3 = WorkTextFile(
    name: 'readme.txt',
    relativePath: 'readme.txt',
    path: '/works/RJ123/readme.txt',
  );

  testWidgets(
    'WorkTextViewerPage displays title bar with exit button and file name, and bottom-right switcher',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      final fakeGateway = _FakeFileCacheGateway({
        file1.path: Uint8List.fromList(utf8.encode('第一幕：お帰りなさいませ。')),
        file2.path: Uint8List.fromList(utf8.encode('第二幕：特典トラックです。')),
        file3.path: Uint8List.fromList(utf8.encode('Readme 说明文本')),
      });

      var popped = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const WorkTextViewerPage(
                          files: [file1, file2, file3],
                        ),
                      ),
                    ).then((_) {
                      popped = true;
                    });
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Title bar contains file display name without extension next to exit button
      expect(find.text('01_トラック台本'), findsOneWidget);
      expect(find.text('01_トラック台本.txt'), findsNothing);

      // Bottom-right switcher displays 1/3
      expect(find.text('1/3'), findsOneWidget);

      // Prev button is disabled at index 0
      final prevBtnFinder = find.widgetWithIcon(IconButton, Icons.chevron_left_rounded);
      final prevBtn = tester.widget<IconButton>(prevBtnFinder);
      expect(prevBtn.onPressed, isNull);

      // Next button is enabled
      final nextBtnFinder = find.widgetWithIcon(IconButton, Icons.chevron_right_rounded);
      final nextBtn = tester.widget<IconButton>(nextBtnFinder);
      expect(nextBtn.onPressed, isNotNull);

      // Tap Next button to switch to file 2
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();

      // Title updates to file 2 display name
      expect(find.text('02_特典台本'), findsOneWidget);
      expect(find.text('02_特典台本.txt'), findsNothing);
      expect(find.text('2/3'), findsOneWidget);

      // Both prev and next are enabled at index 1
      expect(tester.widget<IconButton>(prevBtnFinder).onPressed, isNotNull);
      expect(tester.widget<IconButton>(nextBtnFinder).onPressed, isNotNull);

      // Tap Next to switch to file 3 (last file)
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('readme'), findsOneWidget);
      expect(find.text('readme.txt'), findsNothing);
      expect(find.text('3/3'), findsOneWidget);
      expect(tester.widget<IconButton>(nextBtnFinder).onPressed, isNull);

      // Test exit button in title bar
      final backButton = find.widgetWithIcon(IconButton, Icons.arrow_back_rounded);
      expect(backButton, findsOneWidget);
      await tester.tap(backButton);
      await tester.pumpAndSettle();
      expect(popped, isTrue);
    },
  );

  testWidgets(
    'WorkTextViewerPage displays file display name without extension and auto-decodes text',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      final fakeGateway = _FakeFileCacheGateway({
        file1.path: Uint8List.fromList(utf8.encode('自动探测编码台本テキスト')),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(
            home: WorkTextViewerPage(
              files: [file1],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('01_トラック台本'), findsOneWidget);
      expect(find.text('01_トラック台本.txt'), findsNothing);
      expect(find.text('自动探测编码台本テキスト'), findsOneWidget);
    },
  );

  testWidgets(
    'WorkTextViewerPage allows scrolling text up and down smoothly',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      final longText = List.generate(100, (i) => 'Line $i: 台本文本测试内容').join('\n');
      final fakeGateway = _FakeFileCacheGateway({
        file1.path: Uint8List.fromList(utf8.encode(longText)),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(
            home: WorkTextViewerPage(
              files: [file1],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollableFinder = find.byType(Scrollable);
      expect(scrollableFinder, findsOneWidget);
      final scrollableState = tester.state<ScrollableState>(scrollableFinder);
      expect(scrollableState.position.pixels, 0.0);

      // Drag up to scroll down
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(scrollableState.position.pixels, greaterThan(200.0));

      // Drag down to scroll back up
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(scrollableState.position.pixels, lessThan(50.0));
    },
  );

  testWidgets(
    'WorkTextViewerPage lazily appends large text documents near the scroll end',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      const deferredMarker = 'DEFERRED_TEXT_SECTION';
      final longText = '${'首段内容。\n' * 3000}$deferredMarker';
      final fakeGateway = _FakeFileCacheGateway({
        file1.path: Uint8List.fromList(utf8.encode(longText)),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
        ),
      );
      await tester.pumpAndSettle();

      Text renderedText() => tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data?.startsWith('首段内容') == true,
        ),
      );

      expect(renderedText().data, isNot(contains(deferredMarker)));

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      scrollView.controller!.jumpTo(
        scrollView.controller!.position.maxScrollExtent,
      );
      await tester.pump();

      expect(renderedText().data, contains(deferredMarker));
    },
  );

  testWidgets(
    'WorkTextViewerPage renders markdown (.md) documents with MarkdownBody',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      const mdFile = WorkTextFile(
        name: 'README.md',
        relativePath: 'README.md',
        path: '/works/RJ123/README.md',
      );

      final fakeGateway = _FakeFileCacheGateway({
        mdFile.path: Uint8List.fromList(
          utf8.encode('# 作品说明\n\n这是**加粗说明**和*斜体文本*。'),
        ),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(
            home: WorkTextViewerPage(
              files: [mdFile],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('README'), findsOneWidget);
      expect(find.text('README.md'), findsNothing);
      expect(find.textContaining('作品说明'), findsOneWidget);
    },
  );

  testWidgets(
    'WorkTextViewerPage lazily appends large markdown documents near the scroll end',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      const mdFile = WorkTextFile(
        name: 'README.md',
        relativePath: 'README.md',
        path: '/works/RJ123/README.md',
      );
      const deferredMarker = 'DEFERRED_MARKDOWN_SECTION';
      final markdown = '${'正文段落。\n\n' * 3000}## $deferredMarker';
      final fakeGateway = _FakeFileCacheGateway({
        mdFile.path: Uint8List.fromList(utf8.encode(markdown)),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(home: WorkTextViewerPage(files: [mdFile])),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        isNot(contains(deferredMarker)),
      );

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      scrollView.controller!.jumpTo(
        scrollView.controller!.position.maxScrollExtent,
      );
      await tester.pump();

      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        contains(deferredMarker),
      );
    },
  );

  testWidgets(
    'WorkTextViewerPage handles switching between .txt and .md files smoothly',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      const txtFile = WorkTextFile(
        name: '01_台本.txt',
        relativePath: '01_台本.txt',
        path: '/works/RJ123/01_台本.txt',
      );
      const mdFile = WorkTextFile(
        name: '特典.md',
        relativePath: '特典.md',
        path: '/works/RJ123/特典.md',
      );

      final fakeGateway = _FakeFileCacheGateway({
        txtFile.path: Uint8List.fromList(utf8.encode('普通纯文本台本')),
        mdFile.path: Uint8List.fromList(utf8.encode('### 特典剧本')),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(
            home: WorkTextViewerPage(
              files: [txtFile, mdFile],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('01_台本'), findsOneWidget);
      expect(find.text('普通纯文本台本'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);

      // Switch to .md file
      final nextBtnFinder = find.widgetWithIcon(IconButton, Icons.chevron_right_rounded);
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('特典'), findsOneWidget);
      expect(find.text('特典.md'), findsNothing);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.textContaining('特典剧本'), findsOneWidget);
    },
  );

  testWidgets(
    'WorkTextViewerPage displays error state when PDF file cannot be loaded',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      const pdfFile = WorkTextFile(
        name: 'manual.pdf',
        relativePath: 'manual.pdf',
        path: '/works/RJ123/manual.pdf',
      );

      final fakeGateway = _FakeFileCacheGateway({});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(
            home: WorkTextViewerPage(
              files: [pdfFile],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('manual'), findsOneWidget);
      expect(find.text('manual.pdf'), findsNothing);
      expect(find.text('Failed to load PDF file'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'WorkTextViewerPage uses TopPageHeader with fade mask and spans full width',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(AppLanguage.zh);

      final fakeGateway = _FakeFileCacheGateway({
        file1.path: Uint8List.fromList(utf8.encode('台本文本内容')),
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
            workTextServiceProvider.overrideWithValue(
              WorkTextService(platformGateway: fakeGateway),
            ),
          ],
          child: const MaterialApp(
            home: WorkTextViewerPage(
              files: [file1],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final headerFinder = find.byType(TopPageHeader);
      expect(headerFinder, findsOneWidget);

      // Verify the header spans full width (same width as the screen / 800)
      final headerSize = tester.getSize(headerFinder);
      expect(headerSize.width, 800.0);

      // TopPageHeader includes the AppEdgeFadeMask
      final maskFinder = find.byType(AppEdgeFadeMask);
      expect(maskFinder, findsOneWidget);
      final mask = tester.widget<AppEdgeFadeMask>(maskFinder);
      expect(mask.direction, AppEdgeFadeDirection.towardTop);
    },
  );

  testWidgets(
    'WorkTextViewerPage configures MediaQuery top padding on Windows to keep scrollbar below header',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final language = AppLanguageProvider();
        addTearDown(language.dispose);
        await language.setLanguage(AppLanguage.zh);

        final fakeGateway = _FakeFileCacheGateway({
          file1.path: Uint8List.fromList(utf8.encode('台本文本内容')),
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              workTextServiceProvider.overrideWithValue(
                WorkTextService(platformGateway: fakeGateway),
              ),
            ],
            child: const MaterialApp(
              home: WorkTextViewerPage(
                files: [file1],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Find MediaQuery wrapping the content inside Scaffold
        final scrollableFinder = find.byType(SingleChildScrollView);
        expect(scrollableFinder, findsOneWidget);

        final scrollableContext = tester.element(scrollableFinder);
        final mediaQuery = MediaQuery.of(scrollableContext);

        // Top padding on Windows is contentTopInset (58.0 without system status bar) so scrollbar starts below title bar
        expect(mediaQuery.padding.top, greaterThanOrEqualTo(58.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
