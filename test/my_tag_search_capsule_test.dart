import 'dart:async';

import 'package:doujin_audio/app/presentation/my_tag_management_page.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/page_header_inset.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/app_search_suggestions.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/gestures.dart';
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

  for (final excluded in [false, true]) {
    testWidgets(
      'interest editor thumb stays usable from top to bottom and back (excluded: $excluded)',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _TagController(
          createTestAsmrServices(),
          count: 1500,
        );
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        tester.view.physicalSize = const Size(960, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          fixture.build(
            MyTagManagementPage(excluded: excluded),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final catalog = find.byType(CustomScrollView);
        final scroll = tester
            .state<ScrollableState>(
              find.descendant(of: catalog, matching: find.byType(Scrollable)),
            )
            .position;
        final scrollbar = find.descendant(
          of: catalog,
          matching: find.byType(DragOnlyScrollbar),
        );
        final bounds = tester.getRect(scrollbar);
        final top = bounds.top + PageHeaderInset.of(tester.element(scrollbar));
        final theme = ScrollbarTheme.of(tester.element(scrollbar));
        final thumb = Offset(
          bounds.right -
              theme.crossAxisMargin! -
              theme.thickness!.resolve({})! / 2,
          top + theme.mainAxisMargin! + 20,
        );
        final viewport = Rect.fromLTRB(
          bounds.left,
          top,
          bounds.right,
          bounds.bottom,
        );
        bool visible(Finder finder) =>
            finder.evaluate().isNotEmpty &&
            tester.getRect(finder).overlaps(viewport);
        expect(scroll.maxScrollExtent.isFinite, isTrue);
        final drag = await tester.startGesture(
          thumb,
          kind: PointerDeviceKind.mouse,
        );
        final bottom = Offset(thumb.dx, bounds.bottom - 5);
        await drag.moveTo(bottom);
        await tester.pump();
        expect(scroll.pixels, greaterThan(0));
        expect(visible(find.text('Tag 999')), isTrue);

        for (final progress in [0.25, 0.5, 0.75]) {
          final previous = scroll.pixels;
          await drag.moveTo(Offset.lerp(bottom, thumb, progress)!);
          await tester.pump();
          expect(scroll.maxScrollExtent.isFinite, isTrue);
          expect(scroll.pixels, lessThan(previous));
          final chips = find.byType(AppElementChip);
          expect(
            Iterable<int>.generate(
              chips.evaluate().length,
            ).any((index) => visible(chips.at(index))),
            isTrue,
          );
        }
        await drag.moveTo(thumb.translate(0, -10));
        await drag.up();
        await tester.pumpAndSettle();
        expect(scroll.pixels, closeTo(0, 1));
        expect(visible(find.text('Tag 00')), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'search and draft edits reuse catalog snapshots until they change',
    (tester) async {
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
      await tester.tap(find.byType(AppElementChip));
      await tester.pump();
      expect(controller.catalogReads, reads);
      expect(controller.manualInterestTagKeys, isEmpty);
      expect(
        tester.widget<AppElementChip>(find.byType(AppElementChip)).selected,
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
            .widget<AppElementChip>(find.byKey(const ValueKey('online:alias')))
            .selected,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final textScale in [1.0, 1.6]) {
      testWidgets(
        'tag search floats above scrolling content on $platform at $textScale',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          final controller = _TagController(
            createTestAsmrServices(),
            count: 200,
          );
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
          final firstEntry = tester.getRect(find.byType(AppElementChip).first);
          expect(
            firstEntry.top - tester.getRect(header).bottom,
            closeTo(8, .1),
          );
          expect(firstEntry.left, closeTo(16, .1));
          expect(
            firstEntry.right,
            lessThanOrEqualTo(tester.view.physicalSize.width - 16),
          );
          await tester.enterText(field, 'Tag 05');
          await tester.pumpAndSettle();
          expect(find.byType(AppElementChip), findsOneWidget);
          await tester.tap(find.byType(AppElementChip));
          await tester.pumpAndSettle();
          expect(controller.excludedTagKeys, isEmpty);
          expect(
            tester.widget<AppElementChip>(find.byType(AppElementChip)).selected,
            isTrue,
          );
          await tester.tap(find.byIcon(Icons.clear_rounded));
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -180),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(capsule), capsuleBounds);
          expect(
            tester.getTopLeft(find.byType(AppElementChip).first).dy,
            lessThan(capsuleBounds.bottom),
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.tap(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, 'no matching tags');
          await tester.pumpAndSettle();
          expect(find.byType(AppElementChip), findsNothing);
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

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'large interest catalogs build visible rows and keep scroll on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _TagController(createTestAsmrServices(), count: 0);
        for (var i = 0; i < 5000; i++) {
          final key = 'online:$i';
          controller._state.tags[key] = AsmrTag(
            key: key,
            name: 'Element ${i.toString().padLeft(4, '0')}',
          );
        }
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 960,
          600,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
        expect(find.byType(AppElementChip).evaluate().length, lessThan(200));
        expect(find.byKey(const ValueKey('online:4999')), findsNothing);
        final reads = controller.catalogReads;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
        await tester.pumpAndSettle();
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final offset = scroll.pixels;
        expect(offset, greaterThan(0));
        final visible = find.byType(AppElementChip).hitTestable();
        final chosen = tester.widget<AppElementChip>(visible.last).key!;
        await tester.tap(find.byKey(chosen));
        await tester.pumpAndSettle();
        expect(scroll.pixels, offset);
        expect(controller.catalogReads, reads);
        expect(controller.manualInterestTagKeys, isEmpty);
        await tester.enterText(find.byType(TextField), 'Element 4999');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('online:4999')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('online:4999')));
        await tester.pumpAndSettle();
        expect(controller.catalogReads, reads);
        expect(
          tester
              .widget<AppElementChip>(find.byKey(const ValueKey('online:4999')))
              .selected,
          isTrue,
        );
        await tester.enterText(find.byType(TextField), 'Element');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AppElementChip>(find.byType(AppElementChip).first)
              .selected,
          isFalse,
        );
        expect(find.byType(AppElementChip).evaluate().length, lessThan(200));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
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
      await tester.tap(find.byType(AppElementChip));
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
      tester.widget<AppElementChip>(find.byType(AppElementChip)).selected,
      isTrue,
    );
    await tester.tap(find.byType(AppElementChip));
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
        final automatic = tester.widget<AppElementChip>(
          find.byType(AppElementChip),
        );
        expect(automatic.selected, isTrue);
        expect(automatic.onPressed, isNull);
        expect(
          find.byTooltip(fixture.languageProvider.tr('my_listened_tag')),
          findsOneWidget,
        );
        expect(controller.manualInterestTagKeys, isEmpty);
        await tester.enterText(find.byType(TextField), 'Tag 00');
        await tester.pump();
        expect(
          tester.widget<AppElementChip>(find.byType(AppElementChip)).selected,
          isFalse,
        );
        await tester.tap(find.byType(AppElementChip));
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
        Future<void> open({bool filter = true}) async {
          await tester.tap(find.text('Open tags'));
          await tester.pumpAndSettle();
          if (filter) {
            await tester.enterText(find.byType(TextField), 'Tag 05');
            await tester.pumpAndSettle();
          }
        }

        await open();
        expect(find.textContaining('（前'), findsNothing);
        await tester.tap(find.byType(AppElementChip));
        await tester.pumpAndSettle();
        expect(controller.saveCalls, 0);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await open();
        expect(
          tester.widget<AppElementChip>(find.byType(AppElementChip)).selected,
          isFalse,
        );
        await tester.tap(find.byType(AppElementChip));
        await tester.pumpAndSettle();
        controller.failSave = true;
        await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
        await tester.pumpAndSettle();
        expect(find.byType(MyTagManagementPage), findsOneWidget);
        expect(
          tester.widget<AppElementChip>(find.byType(AppElementChip)).selected,
          isTrue,
        );
        expect(controller.excludedTagKeys, isEmpty);
        expect(controller.interestTags, isEmpty);
        controller.failSave = false;
        final finishSave = controller.finishSave = Completer<void>();
        await tester.enterText(find.byType(TextField), '');
        await tester.pumpAndSettle();
        final firstChip = find.byType(AppElementChip).first;
        expect(tester.widget<AppElementChip>(firstChip).label, 'Tag 00');
        await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
        await tester.pump();
        expect(controller.saveCalls, 2);
        expect(tester.widget<AppElementChip>(firstChip).label, 'Tag 00');
        controller.finishSave = null;
        finishSave.complete();
        await tester.pumpAndSettle();
        expect(find.byType(MyTagManagementPage), findsNothing);
        expect(controller.saveCalls, 2);
        await open(filter: false);
        final first = find.byType(AppElementChip).first;
        expect(tester.widget<AppElementChip>(first).label, 'Tag 05');
        expect(tester.widget<AppElementChip>(first).selected, isTrue);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(tester.widget<AppElementChip>(first).label, 'Tag 05');
        expect(tester.widget<AppElementChip>(first).selected, isFalse);
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
  _TagController(TestAsmrServices services, {int count = 60})
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      ) {
    for (var index = 0; index < count; index++) {
      _state.resolve('Tag ${index.toString().padLeft(2, '0')}');
    }
  }

  final _state = AsmrTagPreferences();
  bool failSave = false;
  Completer<void>? finishSave;
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
    await finishSave?.future;
  }
}
