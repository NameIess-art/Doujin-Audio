import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _ControlledImageProvider
    extends ImageProvider<_ControlledImageProvider> {
  final Completer<ImageInfo> _imageInfo = Completer<ImageInfo>();

  void complete(ui.Image image) {
    _imageInfo.complete(ImageInfo(image: image));
  }

  @override
  ImageStreamCompleter loadImage(
    _ControlledImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_imageInfo.future);
  }

  @override
  Future<_ControlledImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_ControlledImageProvider>(this);
  }
}

Future<ui.Image> _createTestImage() {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const Color(0xFF336699), ui.BlendMode.src);
  return recorder.endRecording().toImage(2, 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    UiInteractionCoordinator.instance.resetForTest();
  });

  tearDown(UiInteractionCoordinator.instance.resetForTest);

  test('logical thumbnail width respects DPR and resolution limit', () {
    expect(
      coverCacheWidthForLogicalSize(
        logicalWidth: 112,
        devicePixelRatio: 3,
        resolution: CoverImageResolution.balanced,
      ),
      336,
    );
    expect(
      coverCacheWidthForLogicalSize(
        logicalWidth: 400,
        devicePixelRatio: 3,
        resolution: CoverImageResolution.memorySaver,
      ),
      300,
    );
  });

  test('standalone audio without stored cover hides playlist artwork', () {
    final track = MusicTrack(
      path: 'C:/media/voice.mp3',
      displayName: 'voice.mp3',
      groupKey: 'voice',
      groupTitle: 'voice',
      groupSubtitle: '',
      isSingle: true,
    );

    expect(hasDisplayableCoverArtwork(track, null), isFalse);
    expect(shouldShowPlaylistCoverArtwork(track, null), isFalse);
  });

  test('standalone audio with stored cover shows playlist artwork', () {
    final track = MusicTrack(
      path: 'C:/media/voice.mp3',
      displayName: 'voice.mp3',
      groupKey: 'voice',
      groupTitle: 'voice',
      groupSubtitle: '',
      isSingle: true,
      coverCachePath: 'C:/cache/voice.cover',
    );

    expect(hasDisplayableCoverArtwork(track, null), isTrue);
    expect(shouldShowPlaylistCoverArtwork(track, null), isTrue);
  });

  test('video keeps playlist artwork even without resolved cover', () {
    final track = MusicTrack(
      path: 'C:/media/movie.mp4',
      displayName: 'movie.mp4',
      groupKey: 'movie',
      groupTitle: 'movie',
      groupSubtitle: '',
      isSingle: true,
      isVideo: true,
    );

    expect(hasDisplayableCoverArtwork(track, null), isTrue);
    expect(shouldShowPlaylistCoverArtwork(track, null), isTrue);
  });

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

  test('cover cache width falls back to balanced resolution', () {
    expect(coverCacheWidth(), 600);
  });

  test('cover cache width follows explicit resolution', () {
    expect(coverCacheWidth(resolution: CoverImageResolution.high), 900);
    expect(coverCacheWidth(resolution: CoverImageResolution.ultraHigh), 1200);
    expect(coverCacheWidth(resolution: CoverImageResolution.original), isNull);
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
    final hiddenIcon = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(hiddenIcon.opacity, 0);
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

  testWidgets('AsyncCoverImage keeps image for a refreshed matching request', (
    tester,
  ) async {
    final first = Completer<String?>();
    final refreshed = Completer<String?>();

    Widget buildCover(Future<String?> future) {
      return MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncCoverImage(
            future: future,
            requestKey: 'https://example.com/cover.jpg',
            duration: Duration.zero,
            imageBuilder: (_, path) => Text('loaded:$path'),
            fallbackBuilder: (_) => const Text('fallback'),
            loadingBuilder: (_) => const Text('loading'),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildCover(first.future));
    first.complete('cover.image');
    await tester.pump();
    expect(find.text('loaded:cover.image'), findsOneWidget);

    await tester.pumpWidget(buildCover(refreshed.future));

    expect(find.text('loaded:cover.image'), findsOneWidget);
    expect(find.text('loading'), findsNothing);

    refreshed.complete('cover.image');
    await tester.pump();
    expect(find.text('loaded:cover.image'), findsOneWidget);
  });

  testWidgets('AsyncCoverImage defers completed cover during interaction', (
    tester,
  ) async {
    final completer = Completer<String?>();
    final interactionSource = Object();
    UiInteractionCoordinator.instance.beginInteraction(interactionSource);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncCoverImage(
            future: completer.future,
            deferCommitDuringInteraction: true,
            duration: Duration.zero,
            imageBuilder: (_, path) => Text('loaded:$path'),
            fallbackBuilder: (_) => const Text('fallback'),
            loadingBuilder: (_) => const Text('loading'),
          ),
        ),
      ),
    );

    completer.complete('cover.png');
    await tester.pump();
    expect(find.text('loading'), findsOneWidget);

    UiInteractionCoordinator.instance.finishInteractionsForTest();
    await tester.pump();
    expect(find.text('loaded:cover.png'), findsOneWidget);
  });

  testWidgets('AsyncCoverImage clears image when request key changes', (
    tester,
  ) async {
    final first = Completer<String?>();
    final replacement = Completer<String?>();

    Widget buildCover(Future<String?> future, String requestKey) {
      return MaterialApp(
        home: AsyncCoverImage(
          future: future,
          requestKey: requestKey,
          duration: Duration.zero,
          imageBuilder: (_, path) => Text('loaded:$path'),
          fallbackBuilder: (_) => const Text('fallback'),
          loadingBuilder: (_) => const Text('loading'),
        ),
      );
    }

    await tester.pumpWidget(buildCover(first.future, 'first'));
    first.complete('first.image');
    await tester.pump();

    await tester.pumpWidget(buildCover(replacement.future, 'replacement'));

    expect(find.text('loaded:first.image'), findsNothing);
    expect(find.text('loading'), findsOneWidget);
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

  testWidgets(
    'RetryingImage keeps placeholder until first frame then fades for 750ms',
    (tester) async {
      final provider = _ControlledImageProvider();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 120,
            height: 90,
            child: RetryingImage(
              retryKey: 'controlled-cover',
              imageProviderBuilder: () => provider,
              fallbackBuilder: (_) => const ColoredBox(
                key: ValueKey<String>('decoding_placeholder'),
                color: Colors.pink,
              ),
            ),
          ),
        ),
      );

      expect(
        tester
            .widget<PlaceholderContentTransition>(
              find.byType(PlaceholderContentTransition),
            )
            .showPlaceholder,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsOneWidget,
      );

      final image = await _createTestImage();
      addTearDown(image.dispose);
      provider.complete(image);
      await tester.pump();
      await tester.pump();

      expect(
        tester
            .widget<PlaceholderContentTransition>(
              find.byType(PlaceholderContentTransition),
            )
            .showPlaceholder,
        isFalse,
      );
      expect(
        find.descendant(
          of: find.byType(PlaceholderContentTransition),
          matching: find.byType(FadeTransition),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsOneWidget,
      );

      await tester.pump(
        kCoverImageFadeDuration - const Duration(milliseconds: 1),
      );
      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsNothing,
      );
    },
  );

  testWidgets('RetryingImage renders every cover display mode', (tester) async {
    final imageBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    Widget subject(CoverImageDisplayMode mode) {
      return MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: RetryingImage(
            retryKey: mode,
            imageProviderBuilder: () => MemoryImage(imageBytes),
            fallbackBuilder: (_) => const Text('fallback'),
            fit: BoxFit.cover,
            displayMode: mode,
          ),
        ),
      );
    }

    await tester.pumpWidget(subject(CoverImageDisplayMode.fill));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);

    await tester.pumpWidget(subject(CoverImageDisplayMode.stretch));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.fill);

    await tester.pumpWidget(subject(CoverImageDisplayMode.tile));
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(2));
    expect(
      images.map((image) => image.fit),
      containsAll(<BoxFit>[BoxFit.cover, BoxFit.contain]),
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('RetryingFileImage can override the global display mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverImageResolutionProvider.overrideWithValue(
            CoverImageResolution.balanced,
          ),
          coverImageDisplayModeProvider.overrideWithValue(
            CoverImageDisplayMode.tile,
          ),
        ],
        child: MaterialApp(
          home: RetryingFileImage(
            path: 'missing-cover.png',
            fit: BoxFit.cover,
            displayMode: CoverImageDisplayMode.fill,
            fallbackBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(
      tester.widget<RetryingImage>(find.byType(RetryingImage)).displayMode,
      CoverImageDisplayMode.fill,
    );
  });
}
