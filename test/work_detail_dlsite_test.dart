import 'dart:async';

import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/dlsite_metadata.dart';
import 'package:doujin_audio/core/translation/text_translation_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

const _button = ValueKey('work_detail_dlsite');
const _loading = ValueKey('work_detail_dlsite_loading');

class _Request {
  _Request(this.code, this.language);
  final String code;
  final AppLanguage language;
  final result = Completer<DlsiteMetadata>();
}

class _DlsiteService extends DlsiteMetadataService {
  final requests = <_Request>[];

  @override
  Future<DlsiteMetadata> fetchByRjCode(
    String rjCode, {
    AppLanguage language = AppLanguage.ja,
  }) {
    final request = _Request(rjCode, language);
    requests.add(request);
    return request.result.future;
  }
}

class _TranslationService extends TextTranslationService {
  @override
  String? cached(String text, String target, {String source = 'auto'}) => null;

  @override
  Future<TextTranslationResult> translate(
    List<String> texts, {
    required String target,
    String source = 'auto',
    required TextTranslationRequest request,
  }) async => TextTranslationResult(
    translations: {for (final text in texts) text: 'Translated $text'},
  );
}

AsmrWork _work({String code = 'RJ123456'}) => AsmrWork(
  id: 123456,
  title: 'Online title',
  circleName: 'Online circle',
  sourceId: code,
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
  voiceActors: const ['Online actor'],
  tags: const ['Online tag'],
);

DlsiteMetadata _metadata({
  String circle = 'DL circle',
  List<String> actors = const ['DL actor'],
  List<String> tags = const ['DL tag'],
}) => DlsiteMetadata(
  rjCode: 'RJ123456',
  workTitle: 'DL title must not replace online title',
  circleName: circle,
  voiceActors: actors,
  tags: tags,
);

Future<void> _settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (attempt > 4 && !tester.binding.hasScheduledFrame) break;
  }
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;
  setUpAll(
    () async => database = await AppRuntimeTestFixture.installSharedDatabase(),
  );
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'online DLsite toggle loads on demand and reuses page result on $platform',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(360, 800)
            : const Size(960, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _DlsiteService();
        final fixture = AppRuntimeWidgetTestFixture(
          dlsiteMetadataService: service,
        );
        addTearDown(fixture.dispose);
        final work = _work();
        await tester.pumpWidget(
          fixture.build(WorkDetailPage.forAsmr(work: work)),
        );
        await _settle(tester);
        expect(service.requests, isEmpty);
        expect(
          tester.getRect(find.byKey(_button)).right,
          lessThanOrEqualTo(
            tester
                .getRect(find.byKey(const ValueKey('work_detail_translation')))
                .left,
          ),
        );
        expect(
          tester.widget<IconButton>(find.byKey(_button)).tooltip,
          '显示 DL 中信息',
        );
        await tester.tap(find.byKey(_button));
        await tester.pump();
        expect(find.byKey(_loading), findsOneWidget);
        expect(
          tester.widget<IconButton>(find.byKey(_button)).onPressed,
          isNull,
        );
        expect(service.requests.single.code, 'RJ123456');
        expect(service.requests.single.language, AppLanguage.zh);
        expect(find.text('Online circle'), findsOneWidget);
        service.requests.single.result.complete(_metadata());
        await _settle(tester);
        expect(find.byKey(_loading), findsNothing);
        expect(find.text('DL circle'), findsOneWidget);
        expect(find.text('Online title'), findsOneWidget);
        expect(tester.widget<IconButton>(find.byKey(_button)).tooltip, '显示原信息');
        // Metadata rows are lazy on the shorter Windows viewport.
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await _settle(tester);
        expect(find.text('DL actor'), findsOneWidget);
        expect(find.text('#DL tag'), findsOneWidget);
        expect(work.circleName, 'Online circle');
        expect(work.voiceActors, ['Online actor']);
        expect(work.tags, ['Online tag']);
        await tester.tap(find.byKey(_button));
        await _settle(tester);
        expect(find.text('Online circle'), findsOneWidget);
        expect(find.text('Online actor'), findsOneWidget);
        expect(find.text('#Online tag'), findsOneWidget);
        await tester.tap(find.byKey(_button));
        await _settle(tester);
        expect(find.text('DL circle'), findsOneWidget);
        expect(service.requests, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      'DLsite metadata keeps translation active and copies source text on $platform',
      (tester) async {
        final service = _DlsiteService();
        final fixture = AppRuntimeWidgetTestFixture(
          dlsiteMetadataService: service,
        );
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
        await tester.pumpWidget(
          fixture.build(
            WorkDetailPage.forAsmr(work: _work()),
            overrides: [
              textTranslationServiceProvider.overrideWithValue(
                _TranslationService(),
              ),
            ],
          ),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('work_detail_translation')));
        await _settle(tester);
        await tester.tap(find.byKey(_button));
        service.requests.single.result.complete(_metadata());
        await _settle(tester);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await _settle(tester);
        expect(find.text('Translated Online title'), findsOneWidget);
        expect(find.text('#Translated DL tag'), findsOneWidget);
        expect(find.text('DL actor'), findsOneWidget);
        expect(find.text('DL circle'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('work_detail_tag_#DL tag')),
          buttons: platform == TargetPlatform.windows
              ? kSecondaryMouseButton
              : kPrimaryMouseButton,
        );
        await tester.pump();
        expect(copied, contains('DL tag'));
        await tester.tap(find.byKey(_button));
        await _settle(tester);
        for (
          var attempt = 0;
          attempt < 40 &&
              find.text('#Translated Online tag').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('#Translated Online tag'), findsOneWidget);
        expect(find.text('Translated Online title'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('partial DLsite response preserves missing original fields', (
    tester,
  ) async {
    final service = _DlsiteService();
    final fixture = AppRuntimeWidgetTestFixture(dlsiteMetadataService: service);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(WorkDetailPage.forAsmr(work: _work())),
    );
    await _settle(tester);
    await tester.tap(find.byKey(_button));
    service.requests.single.result.complete(_metadata(circle: '', tags: []));
    await _settle(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await _settle(tester);
    expect(find.text('Online circle'), findsOneWidget);
    expect(find.text('DL actor'), findsOneWidget);
    expect(find.text('#Online tag'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failure in ['network', 'not found', 'empty']) {
    testWidgets('$failure preserves original metadata and permits retry', (
      tester,
    ) async {
      final service = _DlsiteService();
      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: service,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(WorkDetailPage.forAsmr(work: _work())),
      );
      await _settle(tester);
      await tester.tap(find.byKey(_button));
      if (failure == 'empty') {
        service.requests.single.result.complete(
          _metadata(circle: '', actors: [], tags: []),
        );
      } else {
        service.requests.single.result.completeError(
          DlsiteMetadataException(
            'test failure',
            isNetworkFailure: failure == 'network',
            kind: failure == 'not found'
                ? DlsiteMetadataFailureKind.notFound
                : DlsiteMetadataFailureKind.request,
          ),
        );
      }
      await _settle(tester);
      expect(find.text('Online circle'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byKey(_button)).tooltip,
        '显示 DL 中信息',
      );
      expect(
        find.text(switch (failure) {
          'empty' => 'DLsite 未提供此作品的声优、社团或标签信息。',
          'not found' => 'DLsite 未找到此作品，请稍后重试。',
          _ => '获取 DLsite 信息失败，请检查网络后重试。',
        }),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_button));
      expect(service.requests, hasLength(2));
      service.requests.last.result.complete(_metadata());
      await _settle(tester);
      expect(find.text('DL circle'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('missing RJ disables DLsite and local detail has no toggle', (
    tester,
  ) async {
    final service = _DlsiteService();
    final fixture = AppRuntimeWidgetTestFixture(dlsiteMetadataService: service);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(WorkDetailPage.forAsmr(work: _work(code: ''))),
    );
    await _settle(tester);
    expect(tester.widget<IconButton>(find.byKey(_button)).onPressed, isNull);
    expect(service.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    final target = AudioDetailTarget.libraryRootFolder('C:/dlsite/local');
    await tester.pumpWidget(
      fixture.build(
        WorkDetailPage.forLocal(
          target: target,
          initialDetail: AudioDetail.empty(target),
        ),
      ),
    );
    await _settle(tester);
    expect(find.byKey(_button), findsNothing);
    expect(service.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('closing ignores late result and reopening starts original', (
    tester,
  ) async {
    final service = _DlsiteService();
    final fixture = AppRuntimeWidgetTestFixture(dlsiteMetadataService: service);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(WorkDetailPage.forAsmr(work: _work())),
    );
    await _settle(tester);
    await tester.tap(find.byKey(_button));
    await tester.pumpWidget(const SizedBox.shrink());
    service.requests.single.result.complete(_metadata());
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      fixture.build(WorkDetailPage.forAsmr(work: _work())),
    );
    await _settle(tester);
    expect(find.text('Online circle'), findsOneWidget);
    await tester.tap(find.byKey(_button));
    expect(service.requests, hasLength(2));
    service.requests.last.result.complete(_metadata());
    await _settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'language changes clear cache and ignore older in-flight results',
    (tester) async {
      final service = _DlsiteService();
      final fixture = AppRuntimeWidgetTestFixture(
        dlsiteMetadataService: service,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(WorkDetailPage.forAsmr(work: _work())),
      );
      await _settle(tester);
      await tester.tap(find.byKey(_button));
      service.requests.single.result.complete(_metadata());
      await _settle(tester);
      expect(find.text('DL circle'), findsOneWidget);
      await fixture.languageProvider.setLanguage(AppLanguage.ja);
      await _settle(tester);
      expect(find.text('Online circle'), findsOneWidget);
      await tester.tap(find.byKey(_button));
      expect(service.requests.last.language, AppLanguage.ja);
      final stale = service.requests.last;
      await fixture.languageProvider.setLanguage(AppLanguage.en);
      await _settle(tester);
      expect(find.byKey(_loading), findsNothing);
      await tester.tap(find.byKey(_button));
      expect(service.requests.last.language, AppLanguage.en);
      stale.result.complete(_metadata(circle: 'Stale Japanese circle'));
      await tester.pump();
      expect(find.text('Stale Japanese circle'), findsNothing);
      expect(find.byKey(_loading), findsOneWidget);
      service.requests.last.result.complete(
        _metadata(circle: 'English circle'),
      );
      await _settle(tester);
      expect(find.text('English circle'), findsOneWidget);
      expect(service.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
