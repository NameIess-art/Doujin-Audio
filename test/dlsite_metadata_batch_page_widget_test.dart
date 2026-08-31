import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_batch_page.dart';

void main() {
  testWidgets('work picker uses floating header and completion controls', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: const MaterialApp(
          home: DlsiteMetadataWorkPickerPage(
            entries: <AudioLibraryCategoryEntry>[],
            initialSelection: <AudioLibraryCategoryEntry>[],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_header')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_search')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    final searchField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('batch_metadata_picker_search')),
        matching: find.byType(TextField),
      ),
    );
    expect(searchField.textInputAction, TextInputAction.search);
    expect(
      searchField.decoration?.contentPadding,
      const EdgeInsets.only(right: 10),
    );
    expect(
      searchField.decoration?.prefixIconConstraints,
      const BoxConstraints.tightFor(width: 38, height: 38),
    );
    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.only(top: 58, bottom: 78),
    );
    expect(
      find.byKey(const ValueKey<String>('batch_metadata_picker_done')),
      findsOneWidget,
    );
    expect(find.byType(HeaderFloatingSurface), findsNWidgets(3));
  });

  testWidgets('batch setup content follows the one-line header closely', (
    tester,
  ) async {
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: const MaterialApp(home: DlsiteMetadataBatchPage(entries: [])),
      ),
    );

    expect(
      tester.widget<ListView>(find.byType(ListView)).padding,
      const EdgeInsets.fromLTRB(16, 58, 16, 24),
    );
  });

  testWidgets('picker result is ignored after batch page is disposed', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = _RecordingNavigatorObserver();
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: <NavigatorObserver>[observer],
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const DlsiteMetadataBatchPage(entries: []),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final batchRoute = observer.lastRoute;

    final specific = find.textContaining(
      languageProvider.tr('batch_metadata_specific'),
    );
    await tester.ensureVisible(specific);
    await tester.tap(specific);
    await tester.pumpAndSettle();
    expect(observer.lastRoute, isNot(same(batchRoute)));

    navigatorKey.currentState!.removeRoute(batchRoute);
    await tester.pump();
    navigatorKey.currentState!.pop(<AudioLibraryCategoryEntry>[]);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  Route<dynamic> get lastRoute => _routes.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    super.didPop(route, previousRoute);
  }
}
