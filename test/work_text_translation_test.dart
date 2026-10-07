import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/work_text_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Documents extends Fake implements FileCachePlatformGateway {
  _Documents(this.contents);
  final Map<String, String> contents;
  final reads = <String>[];

  @override
  Future<Uint8List?> readDocumentBytes(String filePath) async {
    reads.add(filePath);
    final content = contents[filePath];
    return content == null ? null : Uint8List.fromList(utf8.encode(content));
  }
}

class _Call {
  _Call(this.texts, this.target, this.request);
  final List<String> texts;
  final String target;
  final TextTranslationRequest request;
  final result = Completer<TextTranslationResult>();

  void complete() => result.complete(
    TextTranslationResult(
      translations: {for (final text in texts) text: '$target:$text'},
    ),
  );
}

class _Translations extends TextTranslationService {
  final calls = <_Call>[];

  @override
  String? cached(String text, String target, {String source = 'auto'}) => null;

  @override
  Future<TextTranslationResult> translate(
    List<String> texts, {
    required String target,
    String source = 'auto',
    required TextTranslationRequest request,
  }) {
    final call = _Call(List.of(texts), target, request);
    calls.add(call);
    return call.result.future;
  }
}

const _file = WorkTextFile(
  name: 'Original script.txt',
  relativePath: 'Original script.txt',
  path: '/works/Original script.txt',
);
const _other = WorkTextFile(
  name: 'Other script.txt',
  relativePath: 'Other script.txt',
  path: '/works/Other script.txt',
);
const _markdown = WorkTextFile(
  name: 'Original script.md',
  relativePath: 'Original script.md',
  path: '/works/Original script.md',
);
const _button = ValueKey('work_text_translation');
const _spinner = ValueKey('work_text_translation_loading');

Future<void> _batch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

Future<({AppLanguageProvider language, _Documents documents})> _mount(
  WidgetTester tester,
  _Translations translations, {
  Map<String, String> contents = const {
    '/works/Original script.txt': 'Original body',
  },
  List<WorkTextFile> files = const [_file],
}) async {
  final language = AppLanguageProvider();
  addTearDown(language.dispose);
  await language.setLanguage(AppLanguage.zh);
  final documents = _Documents(contents);
  final service = WorkTextService(platformGateway: documents);
  addTearDown(service.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appLanguageProviderInstanceProvider.overrideWithValue(language),
        workTextServiceProvider.overrideWithValue(service),
        textTranslationServiceProvider.overrideWithValue(translations),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: tester.view.physicalSize,
            textScaler: const TextScaler.linear(1.5),
          ),
          child: WorkTextViewerPage(files: files),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (language: language, documents: documents);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'viewer translation stays top-right and restores original on $platform',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(360, 800)
            : const Size(960, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _Translations();
        final mounted = await _mount(tester, service);
        expect(service.calls, isEmpty);
        final header = tester.getRect(find.byType(TopPageHeader));
        final button = tester.getRect(find.byKey(_button));
        expect(button.center.dx, greaterThan(header.center.dx));
        expect(button.top, lessThan(80));
        expect(button.right, lessThanOrEqualTo(header.right));
        await tester.tap(find.byKey(_button));
        await _batch(tester);
        expect(service.calls.single.texts, contains('Original body'));
        expect(find.byKey(_spinner), findsOneWidget);
        service.calls.single.complete();
        await _batch(tester);
        expect(find.text('zh-CN:Original body'), findsOneWidget);
        await tester.tap(find.byKey(_button));
        await tester.pump();
        expect(find.text('Original body'), findsOneWidget);
        expect(mounted.documents.reads, [_file.path]);
        expect(_file.path, '/works/Original script.txt');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('loading can be cancelled and late results are ignored', (
    tester,
  ) async {
    final service = _Translations();
    await _mount(tester, service);
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    final call = service.calls.single;
    await tester.tap(find.byKey(_button));
    await tester.pump();
    expect(call.request.cancelled, isTrue);
    call.complete();
    await _batch(tester);
    expect(find.text('Original body'), findsOneWidget);
    expect(find.text('zh-CN:Original body'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('language change replaces requests and exit cancels work', (
    tester,
  ) async {
    final service = _Translations();
    final mounted = await _mount(tester, service);
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    final original = service.calls.single;
    await mounted.language.setLanguage(AppLanguage.ja);
    await _batch(tester);
    expect(original.request.cancelled, isTrue);
    expect(service.calls.last.target, 'ja');
    original.complete();
    service.calls.last.complete();
    await _batch(tester);
    expect(find.text('ja:Original body'), findsOneWidget);
    expect(find.text('zh-CN:Original body'), findsNothing);
    await mounted.language.setLanguage(AppLanguage.en);
    await _batch(tester);
    final leaving = service.calls.last;
    expect(leaving.target, 'en');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(leaving.request.cancelled, isTrue);
    leaving.complete();
    await _batch(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching file resets original and ignores previous reply', (
    tester,
  ) async {
    final service = _Translations();
    final mounted = await _mount(
      tester,
      service,
      files: const [_file, _other],
      contents: {_file.path: 'Original body', _other.path: 'Other body'},
    );
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    final original = service.calls.single;
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(original.request.cancelled, isTrue);
    original.complete();
    await _batch(tester);
    expect(find.text('Other body'), findsOneWidget);
    expect(service.calls, hasLength(1));
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    expect(service.calls.last.texts, contains('Other body'));
    expect(service.calls.last.texts, isNot(contains('Original body')));
    service.calls.last.complete();
    await _batch(tester);
    expect(find.text('zh-CN:Other body'), findsOneWidget);
    expect(mounted.documents.reads, [_file.path, _other.path]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scroll only requests new loaded lines, not the whole document', (
    tester,
  ) async {
    final service = _Translations();
    final content = List.generate(1600, (i) => 'Original line $i').join('\n');
    await _mount(tester, service, contents: {_file.path: content});
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    final first = service.calls.single;
    expect(first.texts, contains('Original line 0'));
    expect(first.texts, isNot(contains('Original line 1599')));
    first.complete();
    await _batch(tester);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await _batch(tester);
    expect(service.calls, hasLength(2));
    expect(service.calls.last.texts, contains('Original line 1599'));
    expect(
      service.calls.last.texts.toSet().intersection(first.texts.toSet()),
      isEmpty,
    );
    service.calls.last.complete();
    await _batch(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Markdown translates prose without sending links or code', (
    tester,
  ) async {
    const content =
        '# Heading\n\n[Link label](https://example.com/keep)\n\n'
        '**Strong text** and `inlineCode()`\n\n```dart\nkeepCode();\n```';
    final service = _Translations();
    await _mount(
      tester,
      service,
      files: const [_markdown],
      contents: {_markdown.path: content},
    );
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
      content,
    );
    await tester.tap(find.byKey(_button));
    await _batch(tester);
    final call = service.calls.single;
    expect(call.texts, containsAll(['Heading', 'Link label', 'Strong text']));
    expect(call.texts, isNot(contains('inlineCode()')));
    expect(call.texts.join(), isNot(contains('keepCode()')));
    expect(call.texts.join(), isNot(contains('https://example.com/keep')));
    call.complete();
    await _batch(tester);
    expect(find.text('zh-CN:Heading', findRichText: true), findsWidgets);
    expect(find.text('zh-CN:Link label', findRichText: true), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('inlineCode()'),
      ),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('keepCode();'),
      ),
      findsWidgets,
    );
    await tester.tap(find.byKey(_button));
    await tester.pump();
    expect(find.text('Heading', findRichText: true), findsWidgets);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
      content,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('PDF viewer has no translation entry', (tester) async {
    const pdf = WorkTextFile(
      name: 'Preview.pdf',
      relativePath: 'Preview.pdf',
      path: '/works/Preview.pdf',
    );
    final service = _Translations();
    await _mount(tester, service, files: const [pdf], contents: const {});
    expect(find.byKey(_button), findsNothing);
    expect(service.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
