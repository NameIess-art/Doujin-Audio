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
            closeTo(4, .1),
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
          expect(controller.excludedTagKeys, contains('local:tag 05'));
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
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
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
  @override
  List<AsmrTag> get allTags => _state.tags.values.toList();
  @override
  Set<String> get excludedTagKeys => _state.excluded;
  @override
  bool get tagCatalogComplete => true;
  @override
  Future<void> ensureTagCatalog({bool force = false}) async {}
  @override
  Future<void> setTagExcluded(String key, bool excluded) async {
    if (excluded) {
      _state.excluded.add(key);
    } else {
      _state.excluded.remove(key);
    }
    notifyListeners();
  }
}
