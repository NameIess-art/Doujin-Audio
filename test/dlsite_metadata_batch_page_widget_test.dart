import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/models/audio_library_category.dart';
import 'package:nameless_audio/screens/dlsite_metadata_batch_page.dart';
import 'package:provider/provider.dart' as legacy_provider;

void main() {
  testWidgets('picker result is ignored after batch page is disposed', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = _RecordingNavigatorObserver();
    final languageProvider = AppLanguageProvider();

    await tester.pumpWidget(
      ProviderScope(
        child: legacy_provider.ChangeNotifierProvider.value(
          value: languageProvider,
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
