import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/core/widgets/page_header_inset.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/work_text_viewer_page.dart';
import 'package:doujin_audio/features/library/presentation/translated_markdown_body.dart';

class _FakeFileCacheGateway extends Fake implements FileCachePlatformGateway {
  _FakeFileCacheGateway(this.filesMap);

  final Map<String, Uint8List> filesMap;

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async {
    return filesMap[filePath];
  }
}

class _PendingFileCacheGateway extends Fake
    implements FileCachePlatformGateway {
  final bytes = Completer<Uint8List?>();
  int reads = 0;

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) {
    reads++;
    return bytes.future;
  }
}

class _CountingTextService extends WorkTextService {
  _CountingTextService(FileCachePlatformGateway gateway)
    : super(platformGateway: gateway);
  int preparations = 0;
  PreparedWorkText? prepared;
  final ready = Completer<void>();
  @override
  Future<PreparedWorkText> readPreparedDocument(
    WorkTextFile file, {
    WorkTextEncoding? encodingOverride,
  }) async {
    preparations++;
    final document = await super.readPreparedDocument(
      file,
      encodingOverride: encodingOverride,
    );
    prepared = document;
    if (!ready.isCompleted) ready.complete();
    return document;
  }
}

class _PreparedTextService extends WorkTextService {
  _PreparedTextService(this.document);
  final PreparedWorkText document;
  @override
  Future<PreparedWorkText> readPreparedDocument(
    WorkTextFile file, {
    WorkTextEncoding? encodingOverride,
  }) async => document;
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

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final extension in ['md', 'txt']) {
      testWidgets(
        'one MiB $extension prepares once and lazily mounts blocks across theme and scroll on $platform',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final language = AppLanguageProvider();
          addTearDown(language.dispose);
          final file = WorkTextFile(
            name: 'large.$extension',
            relativePath: 'large.$extension',
            path: '/large.$extension',
          );
          final text = '# 标题\n\n${'正文包含汉字和😀。\n\n' * 40000}末章';
          final gateway = _FakeFileCacheGateway({
            file.path: Uint8List.fromList(utf8.encode(text)),
          });
          final service = _CountingTextService(gateway);
          addTearDown(service.dispose);
          final dark = ValueNotifier(false);
          addTearDown(dark.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appLanguageProviderInstanceProvider.overrideWithValue(language),
                workTextServiceProvider.overrideWithValue(service),
              ],
              child: ValueListenableBuilder<bool>(
                valueListenable: dark,
                builder: (context, value, _) => MaterialApp(
                  theme: value ? ThemeData.dark() : ThemeData.light(),
                  home: WorkTextViewerPage(files: [file]),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          for (
            var attempt = 0;
            attempt < 100 && !service.ready.isCompleted;
            attempt++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
          }
          expect(service.ready.isCompleted, isTrue);
          await tester.pumpAndSettle();
          expect(service.preparations, 1);
          final document = service.prepared;
          Object? node;
          if (extension == 'md') {
            expect(
              find.byType(TranslatedMarkdownBody).evaluate().length,
              inExclusiveRange(1, 100),
            );
            node = tester
                .widget<TranslatedMarkdownBody>(
                  find.byType(TranslatedMarkdownBody).first,
                )
                .nodes
                .single;
          }
          int mountedBlocks() => find
              .byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'work_document_',
                    ),
              )
              .evaluate()
              .length;
          expect(mountedBlocks(), inExclusiveRange(0, 100));
          if (extension == 'txt') {
            expect(mountedBlocks(), lessThan(document!.textBlocks.length));
          }
          dark.value = true;
          await tester.pumpAndSettle();
          if (extension == 'md') {
            expect(
              tester
                  .widget<TranslatedMarkdownBody>(
                    find.byType(TranslatedMarkdownBody).first,
                  )
                  .nodes
                  .single,
              same(node),
            );
          }
          expect(service.prepared, same(document));
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -600),
          );
          await tester.pumpAndSettle();
          expect(mountedBlocks(), lessThan(100));
          expect(service.preparations, 1);
          expect(find.byType(SelectionArea), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }

    testWidgets(
      'text selection copies Unicode and original whitespace on $platform',
      (tester) async {
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
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        addTearDown(language.dispose);
        const source = '  台本😀\t\nSecond line\n';
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              workTextServiceProvider.overrideWithValue(
                WorkTextService(
                  platformGateway: _FakeFileCacheGateway({
                    file1.path: Uint8List.fromList(utf8.encode(source)),
                  }),
                ),
              ),
            ],
            child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
          ),
        );
        await tester.pumpAndSettle();
        final region = tester.state<SelectableRegionState>(
          find.byType(SelectableRegion),
        );
        region.selectAll();
        await tester.pump();
        region.contextMenuButtonItems
            .firstWhere((item) => item.type == ContextMenuButtonType.copy)
            .onPressed!();
        await tester.pump();
        expect(copied, [source]);
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'TXT block boundary adds no empty line and remains copied on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final language = AppLanguageProvider();
        addTearDown(language.dispose);
        const first = 'First😀\n';
        const second = 'Second line';
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
        final service = _PreparedTextService(
          PreparedWorkText(
            encoding: WorkTextEncoding.utf8,
            textBlocks: const [first, second],
            markdownNodes: const [],
          ),
        );
        addTearDown(service.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appLanguageProviderInstanceProvider.overrideWithValue(language),
              workTextServiceProvider.overrideWithValue(service),
            ],
            child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
          ),
        );
        await tester.pumpAndSettle();
        final firstFinder = find.text(first);
        final secondFinder = find.text(second);
        expect(firstFinder, findsOneWidget);
        final richText = tester.widget<RichText>(
          find.descendant(of: firstFinder, matching: find.byType(RichText)),
        );
        final painter = TextPainter(
          text: TextSpan(
            text: '$first$second',
            style: tester.widget<Text>(secondFinder).style,
          ),
          textDirection: TextDirection.ltr,
          textScaler: richText.textScaler,
        )..layout(maxWidth: tester.getSize(firstFinder).width);
        expect(
          tester.getBottomRight(secondFinder).dy -
              tester.getTopLeft(firstFinder).dy,
          closeTo(painter.height, 0.01),
        );
        painter.dispose();
        final region = tester.state<SelectableRegionState>(
          find.byType(SelectableRegion),
        );
        region.selectAll();
        await tester.pump();
        region.contextMenuButtonItems
            .firstWhere((item) => item.type == ContextMenuButtonType.copy)
            .onPressed!();
        await tester.pump();
        expect(copied, ['$first$second']);
      },
      variant: TargetPlatformVariant({platform}),
    );

    for (final exitPage in [false, true]) {
      testWidgets(
        'text reads wait for opening and completion waits for ${exitPage ? 'exit' : 'next route'} on $platform',
        (tester) async {
          UiInteractionCoordinator.instance.resetForTest();
          addTearDown(UiInteractionCoordinator.instance.resetForTest);
          SharedPreferences.setMockInitialValues(const <String, Object>{});
          final language = AppLanguageProvider();
          addTearDown(language.dispose);
          final gateway = _PendingFileCacheGateway();
          final service = WorkTextService(platformGateway: gateway);
          addTearDown(service.dispose);
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appLanguageProviderInstanceProvider.overrideWithValue(language),
                workTextServiceProvider.overrideWithValue(service),
              ],
              child: MaterialApp(
                navigatorKey: navigator,
                navigatorObservers: [UiInteractionNavigatorObserver()],
                home: const Scaffold(body: Text('home')),
              ),
            ),
          );
          final homeContext = tester.element(find.text('home'));
          unawaited(
            navigator.currentState!.push<void>(
              buildAppPageRoute<void>(
                context: homeContext,
                child: const WorkTextViewerPage(files: [file1]),
                duration: const Duration(milliseconds: 500),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(gateway.reads, 0);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pump();
          expect(gateway.reads, 1);
          final viewerContext = tester.element(find.byType(WorkTextViewerPage));
          if (exitPage) {
            navigator.currentState!.pop();
          } else {
            unawaited(
              navigator.currentState!.push<void>(
                buildAppPageRoute<void>(
                  context: viewerContext,
                  child: const Scaffold(body: Text('next page')),
                  duration: const Duration(milliseconds: 500),
                ),
              ),
            );
          }
          await tester.pump();
          gateway.bytes.complete(
            Uint8List.fromList(utf8.encode('loaded script')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('loaded script', skipOffstage: false), findsNothing);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpAndSettle();
          if (exitPage) {
            expect(find.byType(WorkTextViewerPage), findsNothing);
            expect(UiInteractionCoordinator.instance.pendingCommitCount, 0);
          } else {
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            await tester.pump(const Duration(milliseconds: 200));
            await tester.pumpAndSettle();
            expect(find.text('loaded script'), findsOneWidget);
          }
          expect(gateway.reads, 1);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

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
                    Navigator.of(context)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) => const WorkTextViewerPage(
                              files: [file1, file2, file3],
                            ),
                          ),
                        )
                        .then((_) {
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

      // Both directions stay available and wrap at the list edges.
      final prevBtnFinder = find.widgetWithIcon(
        IconButton,
        Icons.chevron_left_rounded,
      );
      final prevBtn = tester.widget<IconButton>(prevBtnFinder);
      expect(prevBtn.onPressed, isNotNull);

      // Next button is enabled
      final nextBtnFinder = find.widgetWithIcon(
        IconButton,
        Icons.chevron_right_rounded,
      );
      final nextBtn = tester.widget<IconButton>(nextBtnFinder);
      expect(nextBtn.onPressed, isNotNull);

      // Tap Next button to switch to file 2
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();

      // Title updates to file 2 display name
      expect(find.text('02_特典台本'), findsOneWidget);
      expect(find.text('02_特典台本.txt'), findsNothing);
      expect(find.text('2/3'), findsOneWidget);

      // Both prev and next are enabled at index 1.
      expect(tester.widget<IconButton>(prevBtnFinder).onPressed, isNotNull);
      expect(tester.widget<IconButton>(nextBtnFinder).onPressed, isNotNull);

      // Tap Next to switch to file 3 (last file)
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('readme'), findsOneWidget);
      expect(find.text('readme.txt'), findsNothing);
      expect(find.text('3/3'), findsOneWidget);
      expect(tester.widget<IconButton>(nextBtnFinder).onPressed, isNotNull);

      // Next wraps from the last file back to the first.
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();
      expect(find.text('01_トラック台本'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);

      // Previous wraps from the first file to the last.
      await tester.tap(prevBtnFinder);
      await tester.pumpAndSettle();
      expect(find.text('readme'), findsOneWidget);
      expect(find.text('3/3'), findsOneWidget);

      // Test exit button in title bar
      final backButton = find.widgetWithIcon(
        IconButton,
        Icons.arrow_back_rounded,
      );
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
          child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('01_トラック台本'), findsOneWidget);
      expect(find.text('01_トラック台本.txt'), findsNothing);
      expect(find.text('自动探测编码台本テキスト'), findsOneWidget);
    },
  );

  testWidgets('WorkTextViewerPage allows scrolling text up and down smoothly', (
    tester,
  ) async {
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
        child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
      ),
    );
    await tester.pumpAndSettle();

    final scrollableFinder = find.byType(Scrollable);
    expect(scrollableFinder, findsOneWidget);
    final scrollableState = tester.state<ScrollableState>(scrollableFinder);
    expect(scrollableState.position.pixels, 0.0);

    // Drag up to scroll down
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(scrollableState.position.pixels, greaterThan(200.0));

    // Drag down to scroll back up
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(scrollableState.position.pixels, lessThan(50.0));
  });

  testWidgets(
    'WorkTextViewerPage lazily mounts text blocks near the scroll end',
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

      expect(find.textContaining(deferredMarker), findsNothing);

      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      await tester.scrollUntilVisible(
        find.textContaining(deferredMarker),
        5000,
        scrollable: find.byType(Scrollable),
        maxScrolls: 100,
      );
      expect(scrollView.controller!.position.pixels, greaterThan(0));
      expect(find.textContaining(deferredMarker), findsOneWidget);
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
          child: const MaterialApp(home: WorkTextViewerPage(files: [mdFile])),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('README'), findsOneWidget);
      expect(find.text('README.md'), findsNothing);
      expect(find.textContaining('作品说明'), findsOneWidget);
    },
  );

  testWidgets(
    'WorkTextViewerPage lazily mounts parsed markdown blocks near the scroll end',
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

      expect(find.text(deferredMarker), findsNothing);
      expect(
        find.byType(TranslatedMarkdownBody).evaluate().length,
        lessThan(100),
      );

      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      scrollView.controller!.jumpTo(
        scrollView.controller!.position.maxScrollExtent,
      );
      await tester.pump();

      expect(find.text(deferredMarker), findsOneWidget);
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
            home: WorkTextViewerPage(files: [txtFile, mdFile]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('01_台本'), findsOneWidget);
      expect(find.text('普通纯文本台本'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);

      // Switch to .md file
      final nextBtnFinder = find.widgetWithIcon(
        IconButton,
        Icons.chevron_right_rounded,
      );
      await tester.tap(nextBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('特典'), findsOneWidget);
      expect(find.text('特典.md'), findsNothing);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.textContaining('特典剧本'), findsOneWidget);
    },
  );

  for (final locale in AppLanguage.values) {
    testWidgets('WorkTextViewerPage localizes PDF load failure in $locale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final language = AppLanguageProvider();
      addTearDown(language.dispose);
      await language.setLanguage(locale);

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
          child: const MaterialApp(home: WorkTextViewerPage(files: [pdfFile])),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('manual'), findsOneWidget);
      expect(find.text('manual.pdf'), findsNothing);
      expect(find.text(language.tr('text_file_load_failed')), findsOneWidget);
      expect(find.text(language.tr('retry')), findsOneWidget);
    });
  }

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
          child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
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
            child: const MaterialApp(home: WorkTextViewerPage(files: [file1])),
          ),
        );
        await tester.pumpAndSettle();

        // Find MediaQuery wrapping the content inside Scaffold
        final scrollableFinder = find.byType(CustomScrollView);
        expect(scrollableFinder, findsOneWidget);

        final scrollableContext = tester.element(scrollableFinder);

        // The custom desktop scrollbar reads the shared page-header inset.
        expect(PageHeaderInset.of(scrollableContext), greaterThanOrEqualTo(58));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('WorkTextViewerPage fades in text content smoothly over 450ms', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final language = AppLanguageProvider();
    addTearDown(language.dispose);
    await language.setLanguage(AppLanguage.zh);

    final fakeGateway = _FakeFileCacheGateway({
      file1.path: Uint8List.fromList(utf8.encode('台本文本淡入测试')),
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

    // Initially loading
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Pump to complete async loading and build first frame of text content
    await tester.pump();
    await tester.pump();

    // Find Opacity ancestor of the Text widget
    final textFinder = find.text('台本文本淡入测试');
    expect(textFinder, findsOneWidget);

    final opacityFinder = find.ancestor(
      of: textFinder,
      matching: find.byType(Opacity),
    );
    expect(opacityFinder, findsOneWidget);

    final initialOpacity = tester.widget<Opacity>(opacityFinder).opacity;
    expect(initialOpacity, lessThan(0.5));

    // Advance by 200ms
    await tester.pump(const Duration(milliseconds: 200));
    final midOpacity = tester.widget<Opacity>(opacityFinder).opacity;
    expect(midOpacity, greaterThan(initialOpacity));
    expect(midOpacity, lessThan(1.0));

    // Advance past 450ms (200 + 300 = 500ms > 450ms)
    await tester.pump(const Duration(milliseconds: 300));
    final finalOpacity = tester.widget<Opacity>(opacityFinder).opacity;
    expect(finalOpacity, equals(1.0));
  });
}
