import 'dart:async';

import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final prepared in [false, true]) {
    testWidgets(
      'event route reads retain page on push/pop (prepared: $prepared)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        var builds = 0;
        late BuildContext pageContext;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android: AppPageTransitionsBuilder(),
                  TargetPlatform.windows: AppPageTransitionsBuilder(),
                },
              ),
            ),
            home: const Scaffold(),
          ),
        );
        final page = Builder(
          builder: (context) {
            builds++;
            pageContext = context;
            return const Scaffold(body: Text('page'));
          },
        );
        final route = prepared
            ? buildAppPageRoute<void>(
                context: navigator.currentContext!,
                child: page,
              )
            : MaterialPageRoute<void>(builder: (_) => page);
        unawaited(navigator.currentState!.push(route));
        await tester.pumpAndSettle();
        // An event callback reads identity; it must not establish dependencies.
        expect(readAppRoute(pageContext), same(route));
        final initialBuilds = builds;
        for (var i = 0; i < 2; i++) {
          unawaited(
            navigator.currentState!.push(
              buildAppPageRoute<void>(
                context: pageContext,
                child: const Scaffold(body: Text('cover')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(readAppRoute(pageContext)?.isCurrent, isFalse);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(readAppRoute(pageContext)?.isCurrent, isTrue);
          expect(builds, initialBuilds);
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'nested unmanaged routes and popups do not read the outer route',
    (tester) async {
      final nested = GlobalKey<NavigatorState>();
      late BuildContext nestedContext;
      late Route<void> nestedRoute;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {TargetPlatform.android: AppPageTransitionsBuilder()},
            ),
          ),
          home: Navigator(
            key: nested,
            onGenerateRoute: (_) => nestedRoute = PageRouteBuilder<void>(
              pageBuilder: (context, _, _) {
                nestedContext = context;
                return const Scaffold(body: Text('nested'));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(readAppRoute(nestedContext), same(nestedRoute));
      late ModalRoute<dynamic>? popupRoute;
      late ModalRoute<dynamic>? readRoute;
      unawaited(
        showDialog<void>(
          context: nestedContext,
          useRootNavigator: false,
          builder: (context) {
            popupRoute = ModalRoute.of(context);
            readRoute = readAppRoute(context);
            return const AlertDialog(content: Text('popup'));
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(readRoute, same(popupRoute));
      expect(readRoute, isNot(same(nestedRoute)));
      nested.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
