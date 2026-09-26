import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/visual_settings_providers.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _ControlledImageProvider
    extends ImageProvider<_ControlledImageProvider> {
  final Completer<ImageInfo> _imageInfo = Completer<ImageInfo>();
  int loadCount = 0;

  void complete(ui.Image image) {
    _imageInfo.complete(ImageInfo(image: image));
  }

  @override
  ImageStreamCompleter loadImage(
    _ControlledImageProvider key,
    ImageDecoderCallback decode,
  ) {
    loadCount += 1;
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

  test('thumbnail decode width follows displayed pixels', () {
    expect(
      coverThumbnailCacheWidth(
        logicalWidth: 82,
        devicePixelRatio: 3,
        resolution: CoverImageResolution.balanced,
      ),
      246,
    );
    expect(
      coverThumbnailCacheWidth(
        logicalWidth: 500,
        devicePixelRatio: 3,
        resolution: CoverImageResolution.memorySaver,
      ),
      300,
    );
    expect(
      coverThumbnailCacheWidth(
        logicalWidth: 82,
        devicePixelRatio: 2,
        resolution: CoverImageResolution.original,
      ),
      164,
    );
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

  testWidgets('cover stays on its placeholder until the image frame is ready', (
    tester,
  ) async {
    final path = Completer<String?>();
    final provider = _ControlledImageProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncCoverImage(
            future: path.future,
            fallbackBuilder: (_) => const ColoredBox(
              key: ValueKey('cover_placeholder'),
              color: Colors.pink,
            ),
            imageBuilder: (_, _) => RetryingImage(
              retryKey: 'cover',
              imageProviderBuilder: () => provider,
              fallbackBuilder: (_) => const ColoredBox(
                key: ValueKey('cover_placeholder'),
                color: Colors.pink,
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
      Duration.zero,
    );

    path.complete('cover.png');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('cover_placeholder')), findsOneWidget);

    final image = await _createTestImage();
    addTearDown(image.dispose);
    provider.complete(image);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 599));
    expect(find.byKey(const ValueKey('cover_placeholder')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cover_placeholder')), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
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

  testWidgets('stale initial path does not replace resolved cover on rebuild', (
    tester,
  ) async {
    final first = Completer<String?>();
    final refreshed = Completer<String?>();
    Widget buildCover(Future<String?> future) => MaterialApp(
      home: AsyncCoverImage(
        future: future,
        requestKey: 'same-work',
        initialPath: 'old.image',
        imageBuilder: (_, path) => Text('loaded:$path'),
        fallbackBuilder: (_) => const Text('fallback'),
      ),
    );

    await tester.pumpWidget(buildCover(first.future));
    first.complete('new.image');
    await tester.pump();
    expect(find.text('loaded:new.image'), findsOneWidget);

    await tester.pumpWidget(buildCover(refreshed.future));
    expect(find.text('loaded:new.image'), findsOneWidget);
    expect(find.text('loaded:old.image'), findsNothing);
  });

  testWidgets(
    'AsyncCoverImage does not rebuild for an unchanged resolved path',
    (tester) async {
      final refreshed = Completer<String?>();
      var imageBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AsyncCoverImage(
            future: refreshed.future,
            initialPath: 'cover.image',
            imageBuilder: (_, path) {
              imageBuilds++;
              return Text(path);
            },
            fallbackBuilder: (_) => const Text('fallback'),
          ),
        ),
      );
      final buildsBeforeRefresh = imageBuilds;

      refreshed.complete('cover.image');
      await tester.pump();

      expect(imageBuilds, buildsBeforeRefresh);
      expect(find.text('cover.image'), findsOneWidget);
    },
  );

  testWidgets('AsyncCoverImage reuses known cover when the page rebuilds', (
    tester,
  ) async {
    final pending = Completer<String?>();
    Widget buildCover(Future<String?> future, String path) => MaterialApp(
      home: AsyncCoverImage(
        future: future,
        initialPath: path,
        imageBuilder: (_, path) => Text('loaded:$path'),
        fallbackBuilder: (_) => const Text('fallback'),
        loadingBuilder: (_) => const Text('loading'),
      ),
    );

    await tester.pumpWidget(
      buildCover(Future.value('cover.image'), 'cover.image'),
    );
    await tester.pumpWidget(buildCover(pending.future, 'cover.image'));
    expect(find.text('loaded:cover.image'), findsOneWidget);
    expect(find.text('loading'), findsNothing);

    await tester.pumpWidget(
      buildCover(Completer<String?>().future, 'new.image'),
    );
    expect(find.text('loaded:new.image'), findsOneWidget);
    expect(find.text('loaded:cover.image'), findsNothing);
    expect(find.text('loading'), findsNothing);
  });

  testWidgets('saved cover is visible immediately after page recreation', (
    tester,
  ) async {
    final pending = Completer<String?>();
    Widget page() => MaterialApp(
      home: AsyncCoverImage(
        future: pending.future,
        initialPath: 'saved.image',
        imageBuilder: (_, path) => Text('loaded:$path'),
        fallbackBuilder: (_) => const Text('fallback'),
        loadingBuilder: (_) => const Text('loading'),
      ),
    );

    await tester.pumpWidget(page());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page());

    expect(find.text('loaded:saved.image'), findsOneWidget);
    expect(find.text('loading'), findsNothing);
  });

  testWidgets('resolved cover survives refresh failure and retry exhaustion', (
    tester,
  ) async {
    final refresh = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: AsyncCoverImage(
          future: refresh.future,
          requestKey: 'cover',
          initialPath: 'saved.image',
          retryFutureBuilder: () async => null,
          retryDelay: const Duration(milliseconds: 10),
          maxRetryAttempts: 1,
          imageBuilder: (_, path) => Text(path),
          fallbackBuilder: (_) => const Text('fallback'),
        ),
      ),
    );
    refresh.completeError(StateError('temporarily unavailable'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.text('saved.image'), findsOneWidget);
    expect(find.text('fallback'), findsNothing);
  });

  testWidgets('scroll changes retain the mounted cover element', (
    tester,
  ) async {
    final future = Completer<String?>().future;
    late BuildContext coverContext;
    Widget buildCover() => MaterialApp(
      home: ScrollActivityGate(
        child: Builder(
          builder: (context) {
            coverContext = context;
            return AsyncCoverImage(
              future: future,
              initialPath: 'saved.image',
              imageBuilder: (_, path) => Text(path),
              fallbackBuilder: (_) => const Text('fallback'),
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(buildCover());
    final element = tester.element(find.text('saved.image'));
    ScrollStartNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 100,
        pixels: 0,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: coverContext,
    ).dispatch(coverContext);
    await tester.pumpWidget(buildCover());
    expect(tester.element(find.text('saved.image')), same(element));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(buildCover());
    expect(tester.element(find.text('saved.image')), same(element));
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
    'RetryingImage waits for idle before initial load and source changes',
    (tester) async {
      final interactionSource = Object();
      final firstProvider = _ControlledImageProvider();
      final secondProvider = _ControlledImageProvider();

      Widget buildCover(String retryKey, _ControlledImageProvider provider) {
        return MaterialApp(
          home: SizedBox(
            width: 120,
            height: 90,
            child: RetryingImage(
              retryKey: retryKey,
              imageProviderBuilder: () => provider,
              fallbackBuilder: (_) => const Text('fallback'),
              loadingBuilder: (_) => Text('loading:$retryKey'),
            ),
          ),
        );
      }

      UiInteractionCoordinator.instance.beginInteraction(interactionSource);
      await tester.pumpWidget(buildCover('first', firstProvider));

      expect(firstProvider.loadCount, 0);
      expect(find.text('loading:first'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
      await tester.pump();

      expect(firstProvider.loadCount, 1);
      expect(find.byType(Image), findsOneWidget);

      UiInteractionCoordinator.instance.beginInteraction(interactionSource);
      await tester.pumpWidget(buildCover('second', secondProvider));

      expect(secondProvider.loadCount, 0);
      expect(find.text('loading:second'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
      await tester.pump();

      expect(secondProvider.loadCount, 1);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'RetryingImage shows cached cover immediately after card recreation',
    (tester) async {
      final interactionSource = Object();
      final provider = _ControlledImageProvider();

      Widget buildCover() {
        return MaterialApp(
          home: SizedBox(
            width: 120,
            height: 90,
            child: RetryingImage(
              retryKey: 'cached-cover',
              imageProviderBuilder: () => provider,
              fallbackBuilder: (_) => const Text('fallback'),
              loadingBuilder: (_) => const Text('loading'),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildCover());
      expect(provider.loadCount, 1);

      final image = await _createTestImage();
      addTearDown(provider.evict);
      provider.complete(image);
      await tester.pump();
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      UiInteractionCoordinator.instance.beginInteraction(interactionSource);
      await tester.pumpWidget(buildCover());
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('loading'), findsNothing);
      expect(provider.loadCount, 1);
      expect(find.text('fallback'), findsNothing);
      expect(find.byType(PlaceholderContentTransition), findsNothing);

      await tester.pumpWidget(buildCover());
      expect(provider.loadCount, 1);
      expect(find.text('fallback'), findsNothing);
      expect(find.byType(PlaceholderContentTransition), findsNothing);
    },
  );

  testWidgets(
    'RetryingImage fades the placeholder out over 750ms',
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
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsOneWidget,
      );

      final image = await _createTestImage();
      addTearDown(image.dispose);
      provider.complete(image);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsOneWidget,
      );
      final transition = find.byType(PlaceholderContentTransition);
      expect(
        tester.widget<PlaceholderContentTransition>(transition).duration,
        kPlaceholderContentTransitionDuration,
      );
      expect(kPlaceholderContentTransitionDuration, const Duration(milliseconds: 750));
      final fades = find.descendant(
        of: transition,
        matching: find.byType(FadeTransition),
      );
      expect(fades, findsNWidgets(2));
      final placeholderFade = find.ancestor(
        of: find.byKey(const ValueKey<String>('decoding_placeholder')),
        matching: find.byType(FadeTransition),
      );
      expect(tester.widget<FadeTransition>(placeholderFade.first).opacity.value, 1);
      await tester.pump(const Duration(milliseconds: 375));
      final midwayOpacity = tester.widget<FadeTransition>(placeholderFade.first).opacity.value;
      expect(midwayOpacity, greaterThan(0));
      expect(midwayOpacity, lessThan(1));
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
        tester.widget<FadeTransition>(placeholderFade.first).opacity.value,
        closeTo(midwayOpacity, 0.001),
      );
      await tester.pump(const Duration(milliseconds: 374));
      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('decoding_placeholder')),
        findsNothing,
      );
      expect(find.byType(RawImage), findsOneWidget);
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

  testWidgets('file covers retain the placeholder during decoding', (
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

    final retryingImage = tester.widget<RetryingImage>(
      find.byType(RetryingImage),
    );
    expect(retryingImage.displayMode, CoverImageDisplayMode.fill);
    expect(retryingImage.deferLoadDuringInteraction, isFalse);
  }, variant: const TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  }));
}
