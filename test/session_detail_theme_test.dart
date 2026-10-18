import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _probeKey = ValueKey('theme-probe');

ThemeData _base(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.purple,
    brightness: brightness,
  ),
  extensions: [
    brightness == Brightness.dark
        ? AppDesignTokens.dark
        : AppDesignTokens.light,
  ],
  inputDecorationTheme: const InputDecorationTheme(
    focusedBorder: OutlineInputBorder(
      borderSide: BorderSide(color: Colors.purple, width: 1.4),
    ),
    errorBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.red)),
  ),
);

Widget _subject({
  required Future<String?> path,
  String? initialPath,
  Object request = 'track',
  int generation = 0,
  bool asmr = false,
  int? queueColor,
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
  bool highContrast = false,
  ValueListenable<bool>? transition,
}) => MaterialApp(
  theme: _base(brightness),
  themeAnimationDuration: Duration.zero,
  home: MediaQuery(
    data: MediaQueryData(
      platformBrightness: brightness,
      disableAnimations: disableAnimations,
      highContrast: highContrast,
    ),
    child: SessionDetailTheme(
      coverPathFuture: path,
      initialCoverPath: initialPath,
      requestKey: request,
      coverGeneration: generation,
      isAsmr: asmr,
      queueColorValue: queueColor,
      transitionActive: transition,
      child: const SizedBox(key: _probeKey),
    ),
  ),
);

ThemeData _theme(WidgetTester tester) =>
    Theme.of(tester.element(find.byKey(_probeKey)));

ThemeData _target(WidgetTester tester) =>
    tester.widgetList<AnimatedTheme>(find.byType(AnimatedTheme)).last.data;

double _contrast(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

Future<File> _cover(WidgetTester tester, Color color, {File? replace}) async {
  return (await tester.runAsync(() async {
    final file =
        replace ??
        File(
          '${(await Directory.systemTemp.createTemp('detail-palette-')).path}'
          '${Platform.pathSeparator}cover.png',
        );
    if (replace == null) {
      addTearDown(() async {
        if (await file.parent.exists()) {
          await file.parent.delete(recursive: true);
        }
      });
    }
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(16, 16);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    return file;
  }))!;
}

Future<void> _waitForTarget(
  WidgetTester tester,
  bool Function(ThemeData) predicate,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (predicate(_target(tester))) return;
  }
  fail('The cover palette did not arrive within one second.');
}

void main() {
  setUp(() => UiInteractionCoordinator.instance.resetForTest());
  tearDown(() => UiInteractionCoordinator.instance.resetForTest());

  testWidgets('fallback precedence is queue, ASMR, then application theme', (
    tester,
  ) async {
    for (final (asmr, queue, expected) in [
      (false, null, _base(Brightness.light).colorScheme.primary),
      (true, null, AppDesignTokens.light.asmrAccent),
      (true, Colors.orange.toARGB32(), Color(Colors.orange.toARGB32())),
    ]) {
      await tester.pumpWidget(
        _subject(path: Future<String?>.value(), asmr: asmr, queueColor: queue),
      );
      await tester.pumpAndSettle();
      expect(_theme(tester).colorScheme.primary, expected);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'real red and blue covers produce readable ${brightness.name} themes',
      (tester) async {
        final red = await _cover(tester, Colors.red);
        final blue = await _cover(tester, Colors.blue);
        final fallback = _base(brightness).colorScheme.primary;
        Color? redPrimary;
        for (final file in [red, blue]) {
          await tester.pumpWidget(
            _subject(
              path: Future.value(file.path),
              request: file.path,
              brightness: brightness,
            ),
          );
          await _waitForTarget(
            tester,
            (theme) => theme.colorScheme.primary != (redPrimary ?? fallback),
          );
          await tester.pumpAndSettle();
          final theme = _theme(tester);
          final scheme = theme.colorScheme;
          expect(scheme.brightness, brightness);
          expect(
            _contrast(scheme.primary, scheme.onPrimary),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(scheme.surface, scheme.onSurface),
            greaterThanOrEqualTo(4.5),
          );
          expect(theme.scaffoldBackgroundColor, scheme.surface);
          expect(theme.sliderTheme.activeTrackColor, scheme.primary);
          final border = theme.inputDecorationTheme.focusedBorder!;
          expect(border.borderSide.color, scheme.primary);
          expect(border.borderSide.width, 1.4);
          expect(
            theme.inputDecorationTheme.errorBorder!.borderSide.color,
            Colors.red,
          );
          expect(
            theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
            scheme.primary,
          );
          expect(
            theme.filledButtonTheme.style!.backgroundColor!.resolve({
              WidgetState.disabled,
            }),
            scheme.onSurface.withValues(alpha: 0.12),
          );
          expect(scheme.error, _base(brightness).colorScheme.error);
          if (file == red) {
            redPrimary = scheme.primary;
            expect(scheme.primary.r, greaterThan(scheme.primary.b));
          } else {
            expect(scheme.primary.b, greaterThan(scheme.primary.r));
          }
        }
      },
    );
  }

  testWidgets('black, white, and transparent covers remain readable', (
    tester,
  ) async {
    for (final color in [Colors.black, Colors.white, Colors.transparent]) {
      await tester.pumpWidget(const SizedBox());
      final file = await _cover(tester, color);
      await tester.pumpWidget(_subject(path: Future.value(file.path)));
      await _waitForTarget(
        tester,
        (theme) =>
            theme.colorScheme.primary !=
            _base(Brightness.light).colorScheme.primary,
      );
      await tester.pumpAndSettle();
      final scheme = _theme(tester).colorScheme;
      expect(
        _contrast(scheme.primary, scheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.surface, scheme.onSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('late cover colors fade for 300 ms without replacing the child', (
    tester,
  ) async {
    final file = await _cover(tester, Colors.red);
    final pending = Completer<String?>();
    await tester.pumpWidget(_subject(path: pending.future));
    final originalElement = tester.element(find.byKey(_probeKey));
    final original = _theme(tester).colorScheme.primary;
    await tester.pump(const Duration(milliseconds: 500));
    expect(_theme(tester).colorScheme.primary, original);
    pending.complete(file.path);
    await _waitForTarget(
      tester,
      (theme) => theme.colorScheme.primary != original,
    );
    final destination = _target(tester).colorScheme.primary;
    expect(_theme(tester).colorScheme.primary, original);
    await tester.pump(const Duration(milliseconds: 150));
    final halfway = _theme(tester).colorScheme.primary;
    expect(halfway, isNot(original));
    expect(halfway, isNot(destination));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_theme(tester).colorScheme.primary, destination);
    expect(tester.element(find.byKey(_probeKey)), same(originalElement));
  });

  testWidgets('transition defers extraction until navigation finishes', (
    tester,
  ) async {
    final file = await _cover(tester, Colors.green);
    final transition = ValueNotifier(true);
    addTearDown(transition.dispose);
    await tester.pumpWidget(
      _subject(
        path: Future.value(file.path),
        initialPath: file.path,
        transition: transition,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final fallback = _base(Brightness.light).colorScheme.primary;
    expect(_target(tester).colorScheme.primary, fallback);
    transition.value = false;
    await _waitForTarget(
      tester,
      (theme) => theme.colorScheme.primary != fallback,
    );
    await tester.pumpAndSettle();
    expect(_theme(tester).colorScheme.primary, isNot(fallback));
  });

  testWidgets(
    'switch keeps current colors and ignores the previous late cover',
    (tester) async {
      final red = await _cover(tester, Colors.red);
      final blue = await _cover(tester, Colors.blue);
      final first = Completer<String?>();
      await tester.pumpWidget(_subject(path: first.future, request: 'old'));
      final current = Completer<String?>();
      await tester.pumpWidget(
        _subject(path: current.future, request: 'current'),
      );
      current.complete(blue.path);
      final fallback = _base(Brightness.light).colorScheme.primary;
      await _waitForTarget(
        tester,
        (theme) => theme.colorScheme.primary != fallback,
      );
      await tester.pumpAndSettle();
      final bluePrimary = _theme(tester).colorScheme.primary;
      final next = Completer<String?>();
      await tester.pumpWidget(_subject(path: next.future, request: 'next'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_theme(tester).colorScheme.primary, bluePrimary);
      first.complete(red.path);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(_theme(tester).colorScheme.primary, bluePrimary);
      next.complete(null);
      await tester.pumpAndSettle();
      expect(_theme(tester).colorScheme.primary, fallback);
    },
  );

  testWidgets(
    'missing and corrupt covers fall back and later valid covers recover',
    (tester) async {
      final file = await _cover(tester, Colors.green);
      await tester.runAsync(() => file.writeAsBytes([1, 2, 3], flush: true));
      for (final path in ['${file.path}.missing', file.path]) {
        await tester.pumpWidget(
          _subject(path: Future.value(path), request: path, asmr: true),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
        expect(
          _theme(tester).colorScheme.primary,
          AppDesignTokens.light.asmrAccent,
        );
        expect(tester.takeException(), isNull);
      }
      await _cover(tester, Colors.green, replace: file);
      await tester.pumpWidget(
        _subject(
          path: Future.value(file.path),
          request: 'recovered',
          asmr: true,
        ),
      );
      await _waitForTarget(
        tester,
        (theme) =>
            theme.colorScheme.primary != AppDesignTokens.light.asmrAccent,
      );
      await tester.pumpAndSettle();
      expect(
        _theme(tester).colorScheme.primary.g,
        greaterThan(_theme(tester).colorScheme.primary.r),
      );
    },
  );

  testWidgets(
    'cached palette applies immediately and generation invalidates it',
    (tester) async {
      final file = await _cover(tester, Colors.red);
      await tester.pumpWidget(
        _subject(path: Future.value(file.path), initialPath: file.path),
      );
      await _waitForTarget(
        tester,
        (theme) =>
            theme.colorScheme.primary !=
            _base(Brightness.light).colorScheme.primary,
      );
      await tester.pumpAndSettle();
      final red = _theme(tester).colorScheme.primary;
      await tester.pumpWidget(const SizedBox());
      await _cover(tester, Colors.blue, replace: file);
      await tester.pumpWidget(
        _subject(path: Future.value(file.path), initialPath: file.path),
      );
      expect(_theme(tester).colorScheme.primary, red);
      await tester.pumpWidget(
        _subject(
          path: Future.value(file.path),
          initialPath: file.path,
          generation: 1,
        ),
      );
      await _waitForTarget(tester, (theme) => theme.colorScheme.primary != red);
      await tester.pumpAndSettle();
      final blue = _theme(tester).colorScheme.primary;
      expect(blue.b, greaterThan(blue.r));
    },
  );

  testWidgets('brightness and contrast changes regenerate the same cover', (
    tester,
  ) async {
    final file = await _cover(tester, Colors.red);
    final path = Future<String?>.value(file.path);
    await tester.pumpWidget(_subject(path: path, initialPath: file.path));
    await _waitForTarget(
      tester,
      (theme) =>
          theme.colorScheme.primary !=
          _base(Brightness.light).colorScheme.primary,
    );
    await tester.pumpAndSettle();
    final normal = _theme(tester).colorScheme;
    await tester.pumpWidget(
      _subject(path: path, initialPath: file.path, highContrast: true),
    );
    await _waitForTarget(
      tester,
      (theme) =>
          theme.colorScheme.primary != normal.primary &&
          theme.colorScheme.primary !=
              _base(Brightness.light).colorScheme.primary,
    );
    await tester.pumpAndSettle();
    final contrast = _theme(tester).colorScheme;
    expect(
      _contrast(contrast.primary, contrast.onPrimary),
      greaterThan(_contrast(normal.primary, normal.onPrimary)),
    );
    await tester.pumpWidget(
      _subject(path: path, initialPath: file.path, brightness: Brightness.dark),
    );
    await _waitForTarget(
      tester,
      (theme) =>
          theme.colorScheme.brightness == Brightness.dark &&
          theme.colorScheme.primary !=
              _base(Brightness.dark).colorScheme.primary,
    );
    await tester.pumpAndSettle();
    expect(_theme(tester).colorScheme.primary, isNot(normal.primary));
    expect(
      _theme(tester).colorScheme.surface.computeLuminance(),
      lessThan(normal.surface.computeLuminance()),
    );
  });

  testWidgets('a failed path Future restores the queue fallback', (
    tester,
  ) async {
    final file = await _cover(tester, Colors.red);
    await tester.pumpWidget(_subject(path: Future.value(file.path)));
    await _waitForTarget(
      tester,
      (theme) =>
          theme.colorScheme.primary !=
          _base(Brightness.light).colorScheme.primary,
    );
    await tester.pumpAndSettle();
    final failed = Completer<String?>();
    await tester.pumpWidget(
      _subject(
        path: failed.future,
        request: 'failed',
        queueColor: Colors.orange.toARGB32(),
      ),
    );
    await tester.pump();
    failed.completeError(const FileSystemException('Artwork unavailable'));
    await tester.pumpAndSettle();
    expect(
      _theme(tester).colorScheme.primary.toARGB32(),
      Colors.orange.toARGB32(),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled animations apply the loaded palette in one frame', (
    tester,
  ) async {
    final file = await _cover(tester, Colors.red);
    await tester.pumpWidget(
      _subject(path: Future.value(file.path), disableAnimations: true),
    );
    final fallback = _base(Brightness.light).colorScheme.primary;
    await _waitForTarget(
      tester,
      (theme) => theme.colorScheme.primary != fallback,
    );
    expect(
      _theme(tester).colorScheme.primary,
      _target(tester).colorScheme.primary,
    );
  });

  testWidgets('disposed detail ignores a later cover completion', (
    tester,
  ) async {
    final file = await _cover(tester, Colors.red);
    final pending = Completer<String?>();
    await tester.pumpWidget(_subject(path: pending.future));
    await tester.pumpWidget(const SizedBox());
    pending.complete(file.path);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
