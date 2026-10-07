import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/cover_image_cache_policy.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/ui/visual_settings_providers.dart';
import 'package:doujin_audio/core/widgets/app_brand_icon.dart';
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

final class _CountingCodec implements ui.Codec {
  _CountingCodec(this.codec);

  final ui.Codec codec;
  int decodedFrames = 0;
  bool disposed = false;

  @override
  int get frameCount => codec.frameCount;
  @override
  int get repetitionCount => codec.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    decodedFrames += 1;
    return codec.getNextFrame();
  }

  @override
  void dispose() {
    disposed = true;
    codec.dispose();
  }
}

final class _AnimatedImageProvider
    extends ImageProvider<_AnimatedImageProvider> {
  _AnimatedImageProvider(this.codec);

  final _CountingCodec codec;
  int loadCount = 0;

  @override
  Future<_AnimatedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _AnimatedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    loadCount += 1;
    return MultiFrameImageStreamCompleter(codec: Future.value(codec), scale: 1);
  }
}

Future<ui.Image> _createTestImage() {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const Color(0xFF336699), ui.BlendMode.src);
  return recorder.endRecording().toImage(2, 2);
}

Future<void> _flushImageCacheDisposals(WidgetTester tester) async {
  // ImageCache releases completer handles after the frame to allow reinsertion.
  // Clearing the cache does not itself schedule that frame.
  tester.binding.scheduleFrame();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    UiInteractionCoordinator.instance.resetForTest();
  });

  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets('fallback cover uses the theme-colored brand at every size', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      for (final size in const [Size.square(52), Size(120, 90)]) {
        final scheme = ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: brightness,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(colorScheme: scheme),
            home: Center(
              child: SizedBox.fromSize(
                size: size,
                child: const CoverFallbackArtwork(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final brand = tester.widget<AppBrandIcon>(find.byType(AppBrandIcon));
        final image = tester.widget<Image>(find.byType(Image));
        expect(brand.size, size.shortestSide);
        expect(image.color, scheme.primary);
        expect(image.colorBlendMode, BlendMode.srcIn);
        expect((image.image as AssetImage).assetName, appBrandIconAsset);
        expect(find.byType(Icon), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  });

  for (final brightness in Brightness.values) {
    for (final size in const [Size(360, 240), Size(360, 120), Size(960, 240)]) {
      testWidgets('fallback artwork stays inside $size in $brightness', (
        tester,
      ) async {
        const margin = 80.0;
        final boundaryKey = GlobalKey();
        final surfaceSize = Size(
          size.width + margin * 2,
          size.height + margin * 2,
        );
        await tester.binding.setSurfaceSize(surfaceSize);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Theme(
              data: ThemeData(brightness: brightness),
              child: RepaintBoundary(
                key: boundaryKey,
                child: Center(
                  child: SizedBox.fromSize(
                    size: size,
                    child: const CoverFallbackArtwork(),
                  ),
                ),
              ),
            ),
          ),
        );

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        final pixels = await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            return await image.toByteData();
          } finally {
            image.dispose();
          }
        });
        final bytes = pixels!.buffer.asUint8List();
        final width = surfaceSize.width.toInt();
        final coverRect = const Offset(margin, margin) & size;
        var paintedInside = false;
        for (var y = 0; y < surfaceSize.height; y++) {
          for (var x = 0; x < width; x++) {
            final alpha = bytes[(y * width + x) * 4 + 3];
            if (coverRect.contains(Offset(x.toDouble(), y.toDouble()))) {
              paintedInside |= alpha > 0;
            } else if (alpha > 0) {
              fail('Fallback artwork painted outside its bounds at ($x, $y)');
            }
          }
        }
        expect(paintedInside, isTrue);
      });
    }
  }

  final deferredFileCovers = <String, Widget Function(String)>{
    'RetryingFileImage': (path) => RetryingFileImage(
      path: path,
      cacheWidth: 8,
      deferLoadDuringInteraction: true,
      fallbackBuilder: (_) => const Text('fallback'),
    ),
    'LocalCoverImage': (path) => LocalCoverImage(
      path: path,
      cacheWidth: 8,
      deferLoadDuringInteraction: true,
    ),
    'AsyncLocalCoverImage': (path) => AsyncLocalCoverImage(
      future: Completer<String?>().future,
      initialPath: path,
      cacheWidth: 8,
      deferLoadDuringInteraction: true,
    ),
    'AsyncRemoteCoverImage': (path) => AsyncRemoteCoverImage(
      url: 'https://example.com/cover.png',
      future: Completer<String?>().future,
      initialPath: path,
      cacheWidth: 8,
      deferLoadDuringInteraction: true,
      fallbackBuilder: (_) => const Text('fallback'),
    ),
  };

  for (final cover in deferredFileCovers.entries) {
    for (final cached in [false, true]) {
      testWidgets(
        '${cover.key} ${cached ? 'reuses cached file during transition' : 'decodes cold file after transition'}',
        (tester) async {
          final directory = await tester.runAsync(
            () => Directory.systemTemp.createTemp('deferred-cover-'),
          );
          final file = File('${directory!.path}/cover.png');
          await tester.runAsync(
            () => file.writeAsBytes(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
          );
          final provider = resizeFileImageIfNeeded(
            path: file.path,
            cacheWidth: 8,
            useDefaultCacheWidth: false,
          );
          final cacheKey = await provider.obtainKey(ImageConfiguration.empty);
          addTearDown(() async {
            releaseRetainedCoverImages();
            await provider.evict();
            await tester.runAsync(() => directory.delete(recursive: true));
          });
          Widget page() => ProviderScope(
            overrides: [
              coverImageResolutionProvider.overrideWithValue(
                CoverImageResolution.balanced,
              ),
            ],
            child: MaterialApp(
              home: SizedBox(
                width: 120,
                height: 90,
                child: cover.value(file.path),
              ),
            ),
          );
          final coverImages = find.byWidgetPredicate(
            (widget) => widget is Image && widget.image is! AssetImage,
          );
          final coverFrames = find.byElementPredicate((element) {
            if (element.widget is! RawImage) return false;
            var isBrandIcon = false;
            element.visitAncestorElements((ancestor) {
              isBrandIcon = ancestor.widget is AppBrandIcon;
              return !isBrandIcon;
            });
            return !isBrandIcon;
          });
          Future<void> finishFileDecode() async {
            for (var attempt = 0; attempt < 50; attempt++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump();
              final images = tester.widgetList<RawImage>(coverFrames);
              if (images.any((image) => image.image != null)) return;
            }
            fail('File cover did not decode');
          }

          if (cached) {
            await tester.pumpWidget(page());
            await finishFileDecode();
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox.shrink());
          }

          final interactionSource = Object();
          UiInteractionCoordinator.instance.beginNavigation(interactionSource);
          await tester.pumpWidget(page());
          await tester.pump();
          if (cached) {
            expect(coverImages, findsOneWidget);
            expect(
              tester.widget<RawImage>(coverFrames).image,
              isNotNull,
            );
            expect(find.byType(CoverLoadingArtwork), findsNothing);
          } else {
            expect(coverImages, findsNothing);
            expect(
              PaintingBinding.instance.imageCache
                  .statusForKey(cacheKey)
                  .tracked,
              isFalse,
            );
            UiInteractionCoordinator.instance.cancelNavigation(
              interactionSource,
            );
            await tester.pump();
            expect(coverImages, findsOneWidget);
            await finishFileDecode();
            await tester.pumpAndSettle();
            expect(
              tester.widget<RawImage>(coverFrames).image,
              isNotNull,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
          child: LocalCoverImage(path: ''),
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

  testWidgets(
    'AsyncLocalCoverImage shows the brand placeholder while loading',
    (tester) async {
      final completer = Completer<String?>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 120,
            height: 90,
            child: AsyncLocalCoverImage(future: completer.future),
          ),
        ),
      );

      expect(find.byType(CoverLoadingArtwork), findsOneWidget);
      expect(find.byType(CoverFallbackArtwork), findsOneWidget);
      expect(find.byType(AppBrandIcon), findsOneWidget);
      expect(find.byType(AnimatedOpacity), findsNothing);
    },
  );

  testWidgets('AsyncLocalCoverImage shows fallback after a null result', (
    tester,
  ) async {
    final completer = Completer<String?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: AsyncLocalCoverImage(future: completer.future),
        ),
      ),
    );

    completer.complete(null);
    await tester.pump();

    expect(find.byType(CoverLoadingArtwork), findsNothing);
    expect(find.byType(CoverFallbackArtwork), findsOneWidget);
    expect(find.byType(AppBrandIcon), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsNothing);
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
            fallbackBuilder: (_) => const CoverFallbackArtwork(),
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
    expect(find.byType(AnimatedSwitcher), findsNothing);

    path.complete('cover.png');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('cover_placeholder')), findsOneWidget);

    final image = await _createTestImage();
    provider.complete(image);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(find.byKey(const ValueKey('cover_placeholder')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cover_placeholder')), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('a displayed cover remains decoded after its page is rebuilt', (
    tester,
  ) async {
    final provider = _ControlledImageProvider();
    final image = await _createTestImage();
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(releaseRetainedCoverImages);

    Widget page() => MaterialApp(
      home: SizedBox(
        width: 120,
        height: 90,
        child: RetryingImage(
          retryKey: 'retained-cover',
          imageProviderBuilder: () => provider,
          retainInImageCache: true,
          fallbackBuilder: (_) => const Text('loading cover'),
        ),
      ),
    );

    await tester.pumpWidget(page());
    provider.complete(image);
    await tester.pumpAndSettle();
    expect(provider.loadCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    cache.clear();
    await tester.pumpWidget(page());
    expect(provider.loadCount, 1);
    expect(find.text('loading cover'), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retained decoded covers obey count and byte budgets', (
    tester,
  ) async {
    final first = _ControlledImageProvider();
    final second = _ControlledImageProvider();
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() {
      releaseRetainedCoverImages();
      configureRetainedCoverBudget(
        maximumSize: 200,
        maximumSizeBytes: 50 * 1024 * 1024,
      );
    });
    configureRetainedCoverBudget(maximumSize: 1, maximumSizeBytes: 16);
    first.complete(await _createTestImage());
    second.complete(await _createTestImage());
    retainCoverImage(first, ImageConfiguration.empty);
    await tester.pump();
    retainCoverImage(second, ImageConfiguration.empty);
    await tester.pump();
    cache.clear();
    expect(cache.statusForKey(first).live, isFalse);
    expect(cache.statusForKey(second).live, isFalse);
    restoreRetainedCoverImage(second);
    expect(cache.statusForKey(second).keepAlive, isTrue);
    configureRetainedCoverBudget(maximumSize: 1, maximumSizeBytes: 15);
    cache.clear();
    expect(cache.statusForKey(second).live, isFalse);
    restoreRetainedCoverImage(second);
    expect(cache.statusForKey(second).tracked, isFalse);
  });

  for (final synchronous in [false, true]) {
    testWidgets(
      'retention releases ${synchronous ? 'synchronous' : 'asynchronous'} callback image handles',
      (tester) async {
        final owner = await _createTestImage();
        final provider = _ControlledImageProvider();
        final cache = PaintingBinding.instance.imageCache;
        addTearDown(() {
          releaseRetainedCoverImages();
          cache.clear();
          cache.clearLiveImages();
          owner.dispose();
        });
        provider.complete(owner.clone());
        if (synchronous) {
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener((info, _) => info.dispose());
          stream.addListener(listener);
          await tester.pump();
          stream.removeListener(listener);
        }
        retainCoverImage(provider, ImageConfiguration.empty);
        await tester.pump();
        // Owner and completer retain pixels; the temporary listener's clone
        // must already be disposed, independently of garbage collection.
        expect(owner.debugGetOpenHandleStackTraces(), hasLength(2));
        retainCoverImage(provider, ImageConfiguration.empty);
        expect(owner.debugGetOpenHandleStackTraces(), hasLength(2));
        if (synchronous) {
          releaseRetainedCoverImages();
        } else {
          trimCoverImageCacheOnMemoryPressure();
        }
        cache.clear();
        cache.clearLiveImages();
        await _flushImageCacheDisposals(tester);
        expect(owner.debugGetOpenHandleStackTraces(), hasLength(1));
      },
    );
  }

  testWidgets('retained image budget eviction releases pixels', (tester) async {
    final first = await _createTestImage();
    final second = await _createTestImage();
    final firstProvider = _ControlledImageProvider()..complete(first.clone());
    final secondProvider = _ControlledImageProvider()..complete(second.clone());
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() {
      releaseRetainedCoverImages();
      configureRetainedCoverBudget(
        maximumSize: 200,
        maximumSizeBytes: 50 * 1024 * 1024,
      );
      cache.clear();
      cache.clearLiveImages();
      first.dispose();
      second.dispose();
    });
    configureRetainedCoverBudget(maximumSize: 1, maximumSizeBytes: 16);
    retainCoverImage(firstProvider, ImageConfiguration.empty);
    await tester.pump();
    retainCoverImage(secondProvider, ImageConfiguration.empty);
    await tester.pump();
    cache.clear();
    cache.clearLiveImages();
    await _flushImageCacheDisposals(tester);
    expect(first.debugGetOpenHandleStackTraces(), hasLength(1));
    expect(second.debugGetOpenHandleStackTraces(), hasLength(2));
    configureRetainedCoverBudget(maximumSize: 1, maximumSizeBytes: 15);
    expect(second.debugGetOpenHandleStackTraces(), hasLength(1));
  });

  testWidgets('releasing pending retention ignores its later image', (
    tester,
  ) async {
    final owner = await _createTestImage();
    final provider = _ControlledImageProvider();
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() {
      releaseRetainedCoverImages();
      cache.clear();
      cache.clearLiveImages();
      owner.dispose();
    });
    retainCoverImage(provider, ImageConfiguration.empty);
    releaseRetainedCoverImages();
    provider.complete(owner.clone());
    await tester.pump();
    cache.clear();
    cache.clearLiveImages();
    await _flushImageCacheDisposals(tester);
    expect(owner.debugGetOpenHandleStackTraces(), hasLength(1));
    restoreRetainedCoverImage(provider);
    expect(cache.statusForKey(provider).tracked, isFalse);
  });

  testWidgets(
    'retained GIF stops decoding without visible consumers and resumes',
    (tester) async {
      final nativeCodec = await tester.runAsync(
        () => ui.instantiateImageCodec(
          base64Decode(
            'R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
          ),
        ),
      );
      final codec = _CountingCodec(nativeCodec!);
      expect(codec.frameCount, 2);
      expect(codec.repetitionCount, -1);
      final provider = _AnimatedImageProvider(codec);
      final cache = PaintingBinding.instance.imageCache;
      addTearDown(() {
        releaseRetainedCoverImages();
        cache.clear();
        cache.clearLiveImages();
      });
      Widget page({bool tickerEnabled = true, bool reduceMotion = false}) =>
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: TickerMode(
                enabled: tickerEnabled,
                child: RetryingImage(
                  retryKey: 'real-gif',
                  imageProviderBuilder: () => provider,
                  retainInImageCache: true,
                  fallbackBuilder: (_) => const Text('loading'),
                ),
              ),
            ),
          );
      Future<void> advanceFrames(int count) async {
        for (var index = 0; index < count; index++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 110));
        }
      }

      await tester.pumpWidget(page());
      await advanceFrames(8);
      expect(codec.decodedFrames, greaterThan(2));
      for (final reduceMotion in [false, true]) {
        await tester.pumpWidget(
          page(tickerEnabled: reduceMotion, reduceMotion: reduceMotion),
        );
        await advanceFrames(2);
        final pausedFrames = codec.decodedFrames;
        await advanceFrames(5);
        expect(codec.decodedFrames, pausedFrames);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(page());
        await advanceFrames(3);
        expect(codec.decodedFrames, greaterThan(pausedFrames));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await advanceFrames(
        2,
      ); // Drain the frame already being decoded on removal.
      final pausedFrames = codec.decodedFrames;
      expect(tester.binding.transientCallbackCount, 0);
      cache.clear();
      cache.clearLiveImages();
      await advanceFrames(8);
      expect(codec.decodedFrames, pausedFrames);
      expect(codec.disposed, isFalse);
      await tester.pumpWidget(page());
      await advanceFrames(3);
      expect(provider.loadCount, 1);
      expect(codec.decodedFrames, greaterThan(pausedFrames));
      await tester.pumpWidget(const SizedBox.shrink());
      await advanceFrames(2);
      releaseRetainedCoverImages();
      cache.clear();
      cache.clearLiveImages();
      await _flushImageCacheDisposals(tester);
      await advanceFrames(2);
      expect(codec.disposed, isTrue);
    },
  );

  testWidgets('AsyncCoverImage retries an empty path during interaction', (
    tester,
  ) async {
    var calls = 0;
    UiInteractionCoordinator.instance.beginInteraction(Object());

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
              duration: const Duration(milliseconds: 180),
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

  testWidgets('AsyncCoverImage defers completed cover during navigation', (
    tester,
  ) async {
    final completer = Completer<String?>();
    final interactionSource = Object();
    final scrollSource = Object();
    UiInteractionCoordinator.instance.beginInteraction(scrollSource);
    UiInteractionCoordinator.instance.beginNavigation(interactionSource);

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

    UiInteractionCoordinator.instance.endNavigation(interactionSource);
    await tester.pump();
    expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
    expect(find.text('loaded:cover.png'), findsOneWidget);
    UiInteractionCoordinator.instance.finishInteractionsForTest();
  });

  for (final scrolling in [false, true]) {
    testWidgets(
      'cold cover resolves and decodes during ${scrolling ? 'a scroll drag' : 'a general interaction'}',
      (tester) async {
        final path = Completer<String?>();
        final provider = _ControlledImageProvider();
        final interactionSource = Object();
        addTearDown(provider.evict);
        await tester.pumpWidget(
          MaterialApp(
            home: ScrollActivityGate(
              idleDelay: const Duration(seconds: 2),
              child: ListView(
                children: [
                  SizedBox(
                    height: 200,
                    child: AsyncCoverImage(
                      future: path.future,
                      imageBuilder: (_, _) => RetryingImage(
                        retryKey: provider,
                        imageProviderBuilder: () => provider,
                        fallbackBuilder: (_) => const Text('decoding'),
                      ),
                      loadingBuilder: (_) => const Text('loading'),
                      fallbackBuilder: (_) => const Text('fallback'),
                    ),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        );
        final TestGesture? gesture;
        if (scrolling) {
          gesture = await tester.startGesture(
            tester.getCenter(find.byType(ListView)),
          );
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump();
        } else {
          gesture = null;
          UiInteractionCoordinator.instance.beginInteraction(interactionSource);
        }
        expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
        expect(provider.loadCount, 0);

        path.complete('cover.png');
        await tester.pump();
        await tester.pump();
        expect(find.text('loading'), findsNothing);
        expect(provider.loadCount, 1);
        provider.complete(await _createTestImage());
        await tester.pumpAndSettle();
        expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
        expect(find.text('decoding'), findsNothing);
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        await gesture?.up();
        await tester.pumpWidget(const SizedBox.shrink());
        UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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

  testWidgets('RetryingImage retries an image error during interaction', (
    tester,
  ) async {
    var providerBuilds = 0;
    UiInteractionCoordinator.instance.beginInteraction(Object());

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
    'RetryingImage waits for navigation before initial load and source changes',
    (tester) async {
      final interactionSource = Object();
      final scrollSource = Object();
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

      UiInteractionCoordinator.instance.beginInteraction(scrollSource);
      UiInteractionCoordinator.instance.beginNavigation(interactionSource);
      await tester.pumpWidget(buildCover('first', firstProvider));

      expect(firstProvider.loadCount, 0);
      expect(find.text('loading:first'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      UiInteractionCoordinator.instance.endNavigation(interactionSource);
      await tester.pump();

      expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
      expect(firstProvider.loadCount, 1);
      expect(find.byType(Image), findsOneWidget);

      UiInteractionCoordinator.instance.beginNavigation(interactionSource);
      await tester.pumpWidget(buildCover('second', secondProvider));

      expect(secondProvider.loadCount, 0);
      expect(find.text('loading:second'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      UiInteractionCoordinator.instance.cancelNavigation(interactionSource);
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
      UiInteractionCoordinator.instance.beginNavigation(interactionSource);
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

  testWidgets('RetryingImage fades the placeholder out over 450ms', (
    tester,
  ) async {
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
    expect(
      kPlaceholderContentTransitionDuration,
      const Duration(milliseconds: 450),
    );
    final fades = find.descendant(
      of: transition,
      matching: find.byType(FadeTransition),
    );
    expect(fades, findsNWidgets(2));
    final placeholderFade = find.ancestor(
      of: find.byKey(const ValueKey<String>('decoding_placeholder')),
      matching: find.byType(FadeTransition),
    );
    expect(
      tester.widget<FadeTransition>(placeholderFade.first).opacity.value,
      1,
    );
    await tester.pump(const Duration(milliseconds: 150));
    final midwayOpacity = tester
        .widget<FadeTransition>(placeholderFade.first)
        .opacity
        .value;
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
    await tester.pump(const Duration(milliseconds: 149));
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
  });

  testWidgets(
    'RetryingImage fills covers by default and preserves explicit image fit',
    (tester) async {
      final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      Widget subject({BoxFit? fit}) {
        return MaterialApp(
          home: SizedBox(
            width: 120,
            height: 90,
            child: fit == null
                ? RetryingImage(
                    retryKey: 'cover',
                    imageProviderBuilder: () => MemoryImage(imageBytes),
                    fallbackBuilder: (_) => const Text('fallback'),
                  )
                : RetryingImage(
                    retryKey: 'viewer',
                    imageProviderBuilder: () => MemoryImage(imageBytes),
                    fallbackBuilder: (_) => const Text('fallback'),
                    fit: fit,
                  ),
          ),
        );
      }

      await tester.pumpWidget(subject());
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
      expect(find.byType(ImageFiltered), findsNothing);

      await tester.pumpWidget(subject(fit: BoxFit.contain));
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'file covers retain the placeholder during decoding',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coverImageResolutionProvider.overrideWithValue(
              CoverImageResolution.balanced,
            ),
          ],
          child: MaterialApp(
            home: RetryingFileImage(
              path: 'missing-cover.png',
              fallbackBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );

      final retryingImage = tester.widget<RetryingImage>(
        find.byType(RetryingImage),
      );
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
      expect(retryingImage.deferLoadDuringInteraction, isFalse);
      expect(retryingImage.retainInImageCache, isTrue);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
