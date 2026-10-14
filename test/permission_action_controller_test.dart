import 'dart:async';

import 'package:doujin_audio/core/ui/permission_action_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final phase in ['dialog', 'settings']) {
    for (final dispose in [false, true]) {
      testWidgets(
        '${dispose ? "dispose" : "clear"} invalidates pending $phase',
        (tester) async {
          final controller = PermissionActionController();
          addTearDown(controller.dispose);
          final settings = Completer<bool>();
          var opens = 0;
          var callbacks = 0;
          late BuildContext context;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (value) {
                  context = value;
                  return const Scaffold();
                },
              ),
            ),
          );
          final ensure = controller.ensureGrantedAndRun(
            context: context,
            title: 'Permission',
            message: 'Grant permission',
            confirmLabel: 'Grant',
            isGranted: () async => false,
            openSettings: () {
              opens++;
              return settings.future;
            },
            onGranted: () async => callbacks++,
          );
          await tester.pumpAndSettle();
          if (phase == 'settings') {
            await tester.tap(find.text('Grant'));
            await tester.pumpAndSettle();
            expect(opens, 1);
          }
          if (dispose) {
            controller.dispose();
          } else {
            controller.clear();
          }
          if (phase == 'dialog') {
            await tester.tap(find.text('Grant'));
          } else {
            settings.complete(true);
          }
          await tester.pumpAndSettle();
          expect(await ensure, isFalse);
          final resume = controller.handleAppResumed();
          await tester.pump(const Duration(milliseconds: 450));
          await resume;
          expect(opens, phase == 'dialog' ? 0 : 1);
          expect(callbacks, 0);
        },
      );
    }
  }
  for (final action in ['dispose', 'clear', 'replace']) {
    for (final resumed in [false, true]) {
      testWidgets(
        '$action invalidates a pending ${resumed ? "resume" : "initial"} check',
        (tester) async {
          final controller = PermissionActionController();
          addTearDown(controller.dispose);
          final pending = Completer<bool>();
          var checks = 0;
          var callbacks = 0;
          var replacementCallbacks = 0;
          late BuildContext context;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (value) {
                  context = value;
                  return const Scaffold();
                },
              ),
            ),
          );
          final initial = controller.ensureGrantedAndRun(
            context: context,
            title: 'Permission',
            message: 'Grant permission',
            confirmLabel: 'Grant',
            isGranted: () {
              checks++;
              return resumed && checks == 1
                  ? Future.value(false)
                  : pending.future;
            },
            openSettings: () async => true,
            onGranted: () async => callbacks++,
          );
          Future<void>? resume;
          if (resumed) {
            await tester.pumpAndSettle();
            await tester.tap(find.text('Grant'));
            await tester.pumpAndSettle();
            await initial;
            resume = controller.handleAppResumed();
            await tester.pump(const Duration(milliseconds: 450));
            expect(checks, 2);
            // Another resume event must not start a concurrent permission check.
            await controller.handleAppResumed();
            expect(checks, 2);
          }
          switch (action) {
            case 'dispose':
              controller.dispose();
              await tester.pumpWidget(
                const MaterialApp(home: SizedBox.shrink()),
              );
            case 'clear':
              controller.clear();
            case 'replace':
              expect(
                await controller.ensureGrantedAndRun(
                  context: context,
                  title: 'Replacement',
                  message: 'Replacement',
                  isGranted: () async => true,
                  openSettings: () async => true,
                  onGranted: () async => replacementCallbacks++,
                ),
                isTrue,
              );
          }
          pending.complete(true);
          await tester.pump();
          await initial;
          await resume;
          expect(callbacks, 0);
          expect(replacementCallbacks, action == 'replace' ? 1 : 0);
        },
      );
    }
  }

  testWidgets(
    'a valid settings return runs once and disposal during delay cancels it',
    (tester) async {
      for (final disposeDuringDelay in [false, true]) {
        final controller = PermissionActionController();
        var checks = 0;
        var callbacks = 0;
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (value) {
                context = value;
                return const Scaffold();
              },
            ),
          ),
        );
        final initial = controller.ensureGrantedAndRun(
          context: context,
          title: 'Permission',
          message: 'Grant permission',
          confirmLabel: 'Grant',
          isGranted: () async => ++checks > 1,
          openSettings: () async => true,
          onGranted: () async => callbacks++,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Grant'));
        await tester.pumpAndSettle();
        await initial;
        final resume = controller.handleAppResumed();
        if (disposeDuringDelay) controller.dispose();
        await tester.pump(const Duration(milliseconds: 450));
        await resume;
        await controller.handleAppResumed();
        expect(callbacks, disposeDuringDelay ? 0 : 1);
        expect(checks, disposeDuringDelay ? 1 : 2);
        controller.dispose();
      }
    },
  );
}
