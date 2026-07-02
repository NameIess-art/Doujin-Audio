import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nameless_audio/widgets/async_cover_image.dart';

void main() {
  testWidgets('LocalCoverImage shows fallback artwork for an empty path', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: LocalCoverImage(path: '', seed: 'empty-cover'),
        ),
      ),
    );

    expect(find.byType(CoverFallbackArtwork), findsOneWidget);
    expect(find.byType(RetryingImage), findsNothing);
  });

  testWidgets('AsyncLocalCoverImage hides the fallback icon while loading', (
    tester,
  ) async {
    final completer = Completer<String?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncLocalCoverImage(
            future: completer.future,
            seed: 'loading-cover',
            duration: Duration.zero,
          ),
        ),
      ),
    );

    expect(find.byType(CoverLoadingArtwork), findsOneWidget);
    expect(find.byType(CoverFallbackArtwork), findsOneWidget);
    final hiddenIcon = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(hiddenIcon.opacity, 0);
  });

  testWidgets('AsyncLocalCoverImage shows fallback after a null result', (
    tester,
  ) async {
    final completer = Completer<String?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncLocalCoverImage(
            future: completer.future,
            seed: 'missing-cover',
            duration: Duration.zero,
          ),
        ),
      ),
    );

    completer.complete(null);
    await tester.pump();

    expect(find.byType(CoverLoadingArtwork), findsNothing);
    expect(find.byType(CoverFallbackArtwork), findsOneWidget);
    final visibleIcon = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(visibleIcon.opacity, 1);
  });

  testWidgets('AsyncCoverImage shows fallback artwork while loading', (
    tester,
  ) async {
    final completer = Completer<String?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncCoverImage(
            future: completer.future,
            duration: Duration.zero,
            imageBuilder: (_, path) => Text('loaded:$path'),
            fallbackBuilder: (_) =>
                const CoverFallbackArtwork(seed: 'pending-cover'),
          ),
        ),
      ),
    );

    expect(find.byType(CoverFallbackArtwork), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    completer.complete(null);
    await tester.pump();

    expect(find.byType(CoverFallbackArtwork), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('AsyncCoverImage retries when the first path is empty', (
    tester,
  ) async {
    var calls = 0;

    Future<String?> resolveCoverPath() async {
      calls += 1;
      return calls == 1 ? null : 'cover.png';
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncCoverImage(
            future: resolveCoverPath(),
            retryFutureBuilder: resolveCoverPath,
            retryDelay: const Duration(milliseconds: 10),
            maxRetryAttempts: 2,
            duration: Duration.zero,
            imageBuilder: (_, path) => Text('loaded:$path'),
            fallbackBuilder: (_) => const Text('fallback'),
            loadingBuilder: (_) => const Text('loading'),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.pump();

    expect(find.text('loaded:cover.png'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('RetryingImage rebuilds its provider after an image error', (
    tester,
  ) async {
    var providerBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: RetryingImage(
            retryKey: 'broken-cover',
            imageProviderBuilder: () {
              providerBuilds += 1;
              return MemoryImage(Uint8List(0));
            },
            retryDelay: const Duration(milliseconds: 10),
            maxRetryAttempts: 1,
            fallbackBuilder: (_) => const Text('fallback'),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    expect(providerBuilds, 1);

    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(providerBuilds, 2);
  });
}
