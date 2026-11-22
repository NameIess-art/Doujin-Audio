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
              return resumed && checks <= 2
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
            expect(checks, 3);
            // Another resume event must not start a concurrent permission check.
            await controller.handleAppResumed();
            expect(checks, 3);
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
          isGranted: () async => ++checks > 2,
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
        expect(checks, disposeDuringDelay ? 2 : 3);
        controller.dispose();
      }
    },
  );

  testWidgets(
    're-checks permission after dialog confirmation and runs directly if granted',
    (tester) async {
      final controller = PermissionActionController();
      addTearDown(controller.dispose);
      var granted = false;
      var opens = 0;
      var callbacks = 0;
      var cancelled = 0;
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
        isGranted: () async => granted,
        openSettings: () async {
          opens++;
          return true;
        },
        onGranted: () async => callbacks++,
        onCancelled: () => cancelled++,
      );
      await tester.pumpAndSettle();
      // Permission becomes granted before the user confirms the dialog.
      granted = true;
      await tester.tap(find.text('Grant'));
      await tester.pumpAndSettle();

      expect(await ensure, isTrue);
      expect(opens, 0);
      expect(callbacks, 1);
      expect(cancelled, 0);
    },
  );

  testWidgets(
    'invokes onCancelled when dialog is cancelled, settings fail, or resume remains denied',
    (tester) async {
      for (final mode in ['cancel_dialog', 'open_failed', 'resume_denied']) {
        final controller = PermissionActionController();
        var cancelled = 0;
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
          cancelLabel: 'Dismiss',
          confirmLabel: 'Grant',
          isGranted: () async => false,
          openSettings: () async => mode != 'open_failed',
          onGranted: () async => callbacks++,
          onCancelled: () => cancelled++,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(mode == 'cancel_dialog' ? 'Dismiss' : 'Grant'),
        );
        await tester.pumpAndSettle();
        expect(await ensure, isFalse);

        if (mode == 'resume_denied') {
          expect(cancelled, 0);
          final resume = controller.handleAppResumed();
          await tester.pump(const Duration(milliseconds: 450));
          await resume;
        }
        expect(callbacks, 0);
        expect(cancelled, 1);
        controller.dispose();
        expect(cancelled, 1);
      }
    },
  );
}
