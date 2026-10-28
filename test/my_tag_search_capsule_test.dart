import 'package:doujin_audio/app/presentation/my_tag_management_page.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/widgets/page_header_inset.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPreferences.init();
  });

  testWidgets('search and draft edits reuse catalog order until it changes', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _TagController(createTestAsmrServices());
    controller._state.mergeTag(
      AsmrTag(
        key: 'online:alias',
        name: 'Other name',
        aliases: ['Search alias'],
      ),
    );
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        const MyTagManagementPage(excluded: false),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final reads = controller.catalogReads;
    await tester.enterText(find.byType(TextField), 'search alias');
    await tester.pump();
    expect(find.text('Other name'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(controller.catalogReads, reads);
    expect(controller.manualInterestTagKeys, isEmpty);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );

    controller._state.mergeTag(
      AsmrTag(key: 'online:new', name: 'New name', aliases: ['Search alias']),
    );
    controller.notifyListeners();
    await tester.pump();
    expect(controller.catalogReads, reads + 1);
    expect(find.text('New name'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('online:alias')))
          .value,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final textScale in [1.0, 1.6]) {
      testWidgets(
        'tag search floats above scrolling content on $platform at $textScale',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          final controller = _TagController(createTestAsmrServices());
          addTearDown(fixture.dispose);
          addTearDown(controller.dispose);
          tester.view.physicalSize = Size(
            platform == TargetPlatform.android ? 390 : 960,
            600,
          );
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            fixture.build(
              Theme(
                data: ThemeData(platform: platform),
                child: const MyTagManagementPage(excluded: true),
              ),
              overrides: [
                asmrLibraryControllerProvider.overrideWithValue(controller),
              ],
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byType(TextField);
          final capsule = find.byKey(const ValueKey('my_tag_search_capsule'));
          final header = find.byType(TopPageHeader);
          expect(find.descendant(of: header, matching: field), findsOneWidget);
          expect(tester.getSize(capsule).height, 38);
          final confirm = find.byKey(const ValueKey('my_tags_confirm'));
          final confirmSurface = tester.widget<HeaderFloatingSurface>(confirm);
          expect(confirmSurface.height, 46);
          expect(confirmSurface.radius, 23);
          expect(tester.getSize(confirm).height, 46);
          expect(
            tester
                .widget<Material>(
                  find
                      .descendant(of: confirm, matching: find.byType(Material))
                      .first,
                )
                .color,
            Theme.of(tester.element(confirm)).colorScheme.primary,
          );
          final titleCapsule = find
              .descendant(
                of: header,
                matching: find.byType(HeaderFloatingSurface),
              )
              .first;
          expect(
            tester.getRect(capsule).top - tester.getRect(titleCapsule).bottom,
            closeTo(6, .1),
          );
          expect(tester.widget<HeaderFloatingSurface>(capsule).radius, 19);
          expect(tester.widget<TextField>(field).style?.fontSize, 14);
          expect(tester.widget<TextField>(field).decoration?.filled, isFalse);
          expect(
            tester.widget<TextField>(field).decoration?.border,
            InputBorder.none,
          );
          expect(
            PageHeaderInset.of(tester.element(find.byType(CustomScrollView))),
            greaterThanOrEqualTo(tester.getBottomLeft(capsule).dy),
          );
          final capsuleBounds = tester.getRect(capsule);
          final firstEntry = tester.getRect(
            find.byType(CheckboxListTile).first,
          );
          expect(
            firstEntry.top - tester.getRect(header).bottom,
            closeTo(8, .1),
          );
          expect(firstEntry.left, closeTo(16, .1));
          expect(
            firstEntry.right,
            closeTo(tester.view.physicalSize.width - 16, .1),
          );
          await tester.enterText(field, 'Tag 05');
          await tester.pumpAndSettle();
          expect(find.byType(CheckboxListTile), findsOneWidget);
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
          expect(controller.excludedTagKeys, isEmpty);
          expect(
            tester
                .widget<CheckboxListTile>(find.byType(CheckboxListTile))
                .value,
            isTrue,
          );
          await tester.tap(find.byIcon(Icons.clear_rounded));
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -90),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(capsule), capsuleBounds);
          expect(
            tester.getTopLeft(find.byType(CheckboxListTile).first).dy,
            lessThan(capsuleBounds.bottom),
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.tap(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, 'no matching tags');
          await tester.pumpAndSettle();
          expect(find.byType(CheckboxListTile), findsNothing);
          expect(tester.takeException(), isNull);
          tester.testTextInput.hide();
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
          await tester.pumpAndSettle();
          expect(controller.excludedTagKeys, contains('local:tag 05'));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('more than twenty interests remain selected after confirmation', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _TagController(createTestAsmrServices());
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MyTagManagementPage(excluded: false),
              ),
            ),
            child: const Text('Open tags'),
          ),
        ),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open tags'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 25; index++) {
      await tester.enterText(
        find.byType(TextField),
        'Tag ${index.toString().padLeft(2, '0')}',
      );
      await tester.pump();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
    }
    expect(controller.interestTags, isEmpty);
    await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
    await tester.pumpAndSettle();
    expect(controller.manualInterestTagKeys, hasLength(25));
    await tester.tap(find.text('Open tags'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Tag 24');
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(controller.manualInterestTagKeys, hasLength(25));
    await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
    await tester.pumpAndSettle();
    expect(controller.manualInterestTagKeys, hasLength(24));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'automatic listening tags and manual recommendation choices are separate on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _TagController(createTestAsmrServices());
        for (var i = 0; i < 21; i++) {
          controller._state.learned[controller._state.resolve(
                'Tag ${i.toString().padLeft(2, '0')}',
              )] =
              i + 1.0;
        }
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        final before = controller.interestTags.map((e) => e.tag.key).toList();
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyTagManagementPage(excluded: false),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Tag 20');
        await tester.pump();
        final automatic = tester.widget<CheckboxListTile>(
          find.byType(CheckboxListTile),
        );
        expect(automatic.value, isTrue);
        expect(automatic.onChanged, isNull);
        expect(
          find.text(fixture.languageProvider.tr('my_listened_tag')),
          findsOneWidget,
        );
        expect(controller.manualInterestTagKeys, isEmpty);
        await tester.enterText(find.byType(TextField), 'Tag 00');
        await tester.pump();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isFalse,
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        expect(controller.manualInterestTagKeys, isEmpty);
        await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
        await tester.pumpAndSettle();
        expect(controller.manualInterestTagKeys, {'local:tag 00'});
        expect(controller.interestTags.map((e) => e.tag.key), before);
        expect(controller._state.recommendationWeights, contains('tag 00'));
      },
    );
  }

  for (final excluded in [false, true]) {
    testWidgets(
      'tag drafts require confirmation, retry failures, and discard on back: $excluded',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _TagController(createTestAsmrServices());
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MyTagManagementPage(excluded: excluded),
                  ),
                ),
                child: const Text('Open tags'),
              ),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        Future<void> open() async {
          await tester.tap(find.text('Open tags'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'Tag 05');
          await tester.pumpAndSettle();
        }

        await open();
        expect(find.textContaining('（前'), findsNothing);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        expect(controller.saveCalls, 0);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await open();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isFalse,
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        controller.failSave = true;
        await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
        await tester.pumpAndSettle();
        expect(find.byType(MyTagManagementPage), findsOneWidget);
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue,
        );
        expect(controller.excludedTagKeys, isEmpty);
        expect(controller.interestTags, isEmpty);
        controller.failSave = false;
        await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
        await tester.pumpAndSettle();
        expect(find.byType(MyTagManagementPage), findsNothing);
        expect(controller.saveCalls, 2);
        await open();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue,
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        expect(controller.saveCalls, 2);
        await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
        await tester.pumpAndSettle();
        expect(controller.excludedTagKeys, isEmpty);
        expect(controller.interestTags, isEmpty);
      },
    );
  }
}

class _TagController extends AsmrLibraryController {
  _TagController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      ) {
    for (var index = 0; index < 60; index++) {
      _state.resolve('Tag ${index.toString().padLeft(2, '0')}');
    }
  }

  final _state = AsmrTagPreferences();
  bool failSave = false;
  int saveCalls = 0;
  int catalogReads = 0;
  @override
  List<AsmrTagInterest> get interestTags => _state.interests;
  @override
  List<AsmrTagInterest> get listenedTagInterests => _state.listenedInterests;
  @override
  Set<String> get manualInterestTagKeys => _state.manualInterests;
  @override
  List<AsmrTag> get allTags {
    catalogReads++;
    return _state.tags.values.toList();
  }

  @override
  Set<String> get excludedTagKeys => _state.excluded;
  @override
  bool get tagCatalogComplete => true;
  @override
  Future<void> ensureTagCatalog({bool force = false}) async {}
  @override
  Future<void> applyTagSelections({
    required bool excluded,
    required Map<String, bool> changes,
  }) async {
    saveCalls++;
    if (failSave) throw StateError('save failed');
    for (final entry in changes.entries) {
      if (!excluded) {
        _state.setInterested(entry.key, entry.value);
      } else if (entry.value) {
        _state.excluded.add(entry.key);
      } else {
        _state.excluded.remove(entry.key);
      }
    }
    notifyListeners();
  }
}
