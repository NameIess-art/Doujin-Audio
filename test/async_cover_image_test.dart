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

final class _ControlledFileImage extends FileImage {
  const _ControlledFileImage(super.file, this.controller);

  final _ControlledImageProvider controller;

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      controller.loadImage(controller, decode);
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

Future<ui.Image> _createTestImage([int size = 2]) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const Color(0xFF336699), ui.BlendMode.src);
  return recorder.endRecording().toImage(size, size);
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

  testWidgets('pending cached decode cannot repaint a transitioning page', (
    tester,
  ) async {
    final owner = await _createTestImage();
    final provider = _ControlledImageProvider();
    final cache = PaintingBinding.instance.imageCache;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((image, _) => image.dispose());
    stream.addListener(listener);
    addTearDown(() {
      stream.removeListener(listener);
      cache.clear();
      cache.clearLiveImages();
      owner.dispose();
    });
    expect(cache.statusForKey(provider).pending, isTrue);
    final interaction = UiInteractionCoordinator.instance;
    final navigation = Object();
    interaction.beginNavigation(navigation);
    await tester.pumpWidget(
      MaterialApp(
        home: RetryingImage(
          retryKey: provider,
          imageProviderBuilder: () => provider,
          loadingBuilder: (_) => const Text('Waiting for navigation'),
          fallbackBuilder: (_) => const SizedBox.shrink(),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    provider.complete(owner.clone());
    await tester.pump();
    expect(find.text('Waiting for navigation'), findsOneWidget);
    interaction.endNavigation(navigation);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(provider.loadCount, 1);
    await tester.pump(interaction.idleDelay);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    for (final (scrolling, cached) in const [
      (false, false),
      (false, true),
      (true, false),
      (true, true),
    ]) {
      final action = cached ? 'reuses cached file' : 'decodes cold file';
      final timing = cached || scrolling ? 'during' : 'after';
      testWidgets(
        '${cover.key} $action $timing ${scrolling ? 'scroll' : 'transition'}',
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
          Widget page({bool showCover = true}) => ProviderScope(
            overrides: [
              coverImageResolutionProvider.overrideWithValue(
                CoverImageResolution.balanced,
              ),
            ],
            child: MaterialApp(
              home: ScrollActivityGate(
                child: SizedBox(
                  key: const ValueKey('cover-slot'),
                  width: 120,
                  height: 90,
                  child: showCover ? cover.value(file.path) : null,
                ),
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
          void notifyScroll() {
            final context = tester.element(
              find.byKey(const ValueKey('cover-slot')),
            );
            final metrics = FixedScrollMetrics(
              minScrollExtent: 0,
              maxScrollExtent: 100,
              pixels: 0,
              viewportDimension: 100,
              axisDirection: AxisDirection.down,
              devicePixelRatio: 1,
            );
            ScrollStartNotification(
              metrics: metrics,
              context: context,
            ).dispatch(context);
          }

          if (scrolling) {
            await tester.pumpWidget(page(showCover: false));
            notifyScroll();
            await tester.pump();
          } else {
            UiInteractionCoordinator.instance.beginNavigation(
              interactionSource,
            );
          }
          await tester.pumpWidget(page());
          await tester.pump();
          if (cached) {
            expect(coverImages, findsOneWidget);
            expect(tester.widget<RawImage>(coverFrames).image, isNotNull);
            expect(find.byType(CoverLoadingArtwork), findsNothing);
          } else {
            if (!scrolling) {
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
            }
            await tester.pump();
            expect(coverImages, findsOneWidget);
            await finishFileDecode();
            await tester.pumpAndSettle();
            expect(tester.widget<RawImage>(coverFrames).image, isNotNull);
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

  test('thumbnail decode sizes follow display pixels in stable buckets', () {
    for (final (logicalWidth, ratio, expected) in const [
      (1.0, 1.0, 64),
      (64.0, 1.0, 64),
      (64.1, 1.0, 128),
      (120.0, 1.0, 128),
      (120.0, 1.25, 192),
      (120.0, 2.0, 256),
      (120.0, 3.0, 384),
      (52.0, 3.0, 192),
    ]) {
      expect(
        coverThumbnailCacheWidth(
          logicalWidth: logicalWidth,
          devicePixelRatio: ratio,
          resolution: CoverImageResolution.balanced,
        ),
        expected,
        reason: '$logicalWidth logical pixels at $ratio DPR',
      );
    }
  });

  test(
    'thumbnail quality caps keep full-size and original artwork separate',
    () {
      for (final (resolution, expected) in const [
        (CoverImageResolution.memorySaver, 300),
        (CoverImageResolution.balanced, 600),
        (CoverImageResolution.high, 900),
        (CoverImageResolution.ultraHigh, 1200),
        (CoverImageResolution.original, 1600),
      ]) {
        expect(
          coverThumbnailCacheWidth(
            logicalWidth: 800,
            devicePixelRatio: 2,
            resolution: resolution,
          ),
          expected,
        );
      }
      expect(
        coverThumbnailCacheWidth(
          logicalWidth: 120,
          devicePixelRatio: 2,
          resolution: CoverImageResolution.original,
        ),
        256,
      );
      expect(
        coverCacheWidth(resolution: CoverImageResolution.original),
        isNull,
      );
    },
  );

  test('the same file and thumbnail bucket share an image cache key', () async {
    ImageProvider<Object> thumbnail(double width) => resizeFileImageIfNeeded(
      path: 'shared-cover.png',
      cacheWidth: coverThumbnailCacheWidth(
        logicalWidth: width,
        devicePixelRatio: 2,
        resolution: CoverImageResolution.balanced,
      ),
      useDefaultCacheWidth: false,
    );
    final key = await thumbnail(120).obtainKey(ImageConfiguration.empty);
    expect(await thumbnail(125).obtainKey(ImageConfiguration.empty), key);
    expect(
      await thumbnail(129).obtainKey(ImageConfiguration.empty),
      isNot(key),
    );
    expect(
      await resizeFileImageIfNeeded(
        path: 'shared-cover.png',
      ).obtainKey(ImageConfiguration.empty),
      isNot(key),
    );
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

  testWidgets('detail reuses thumbnail pixels until its one quality upgrade', (
    tester,
  ) async {
    final thumbnail = _ControlledImageProvider();
    final detail = _ControlledImageProvider();
    final smaller = _ControlledImageProvider();
    final unrelated = _ControlledImageProvider();
    ImageProvider<Object> provider(
      _ControlledImageProvider controller,
      int width, {
      String path = 'shared-cover.png',
    }) =>
        ResizeImage(_ControlledFileImage(File(path), controller), width: width);
    final thumbnailProvider = provider(thumbnail, 2);
    final detailProvider = provider(detail, 8);
    final interaction = Object();
    final coordinator = UiInteractionCoordinator.instance;
    addTearDown(() {
      coordinator.cancelNavigation(interaction);
      releaseRetainedCoverImages();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
    Widget page(ImageProvider<Object> image) => MaterialApp(
      home: SizedBox.square(
        dimension: 80,
        child: RetryingImage(
          retryKey: image,
          imageProviderBuilder: () => image,
          retainInImageCache: true,
          fallbackBuilder: (_) => const Text('loading cover'),
        ),
      ),
    );

    await tester.pumpWidget(page(thumbnailProvider));
    thumbnail.complete(await _createTestImage());
    await tester.pumpAndSettle();
    final thumbnailPixels = tester
        .widget<RawImage>(find.byType(RawImage))
        .image!
        .clone();
    addTearDown(thumbnailPixels.dispose);
    coordinator.beginNavigation(interaction);
    await tester.pumpWidget(page(detailProvider));
    expect(detail.loadCount, 0);
    expect(find.byType(CoverLoadingArtwork), findsNothing);
    expect(
      tester
          .widget<RawImage>(find.byType(RawImage))
          .image!
          .isCloneOf(thumbnailPixels),
      isTrue,
    );

    coordinator.cancelNavigation(interaction);
    await tester.pump();
    await tester.pump();
    expect(detail.loadCount, 1);
    expect(find.byType(CoverLoadingArtwork), findsNothing);
    expect(
      tester
          .widget<RawImage>(find.byType(RawImage))
          .image!
          .isCloneOf(thumbnailPixels),
      isTrue,
    );
    detail.complete(await _createTestImage(8));
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 8);
    expect(detail.loadCount, 1);
    final detailPixels = tester
        .widget<RawImage>(find.byType(RawImage))
        .image!
        .clone();
    addTearDown(detailPixels.dispose);

    await tester.pumpWidget(const SizedBox.shrink());
    coordinator.beginNavigation(interaction);
    await tester.pumpWidget(page(detailProvider));
    expect(detail.loadCount, 1);
    expect(
      tester
          .widget<RawImage>(find.byType(RawImage))
          .image!
          .isCloneOf(detailPixels),
      isTrue,
    );
    await tester.pumpWidget(page(provider(smaller, 4)));
    expect(smaller.loadCount, 0);
    expect(
      tester
          .widget<RawImage>(find.byType(RawImage))
          .image!
          .isCloneOf(detailPixels),
      isTrue,
    );
    coordinator.cancelNavigation(interaction);
    await tester.pumpAndSettle();
    expect(smaller.loadCount, 0);

    coordinator.beginNavigation(interaction);
    await tester.pumpWidget(
      page(provider(unrelated, 8, path: 'another-cover.png')),
    );
    expect(find.byType(RawImage), findsNothing);
    expect(find.byType(CoverLoadingArtwork), findsOneWidget);
    expect(unrelated.loadCount, 0);
    coordinator.cancelNavigation(interaction);
    await tester.pump();
    await tester.pump();
    unrelated.complete(await _createTestImage(8));
    await tester.pumpAndSettle();
    expect(unrelated.loadCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed quality upgrade keeps its preview through retry', (
    tester,
  ) async {
    final thumbnail = _ControlledImageProvider();
    final failedDetail = _ControlledImageProvider();
    final repairedDetail = _ControlledImageProvider();
    final file = File('retry-shared-cover.png');
    final thumbnailProvider = ResizeImage(
      _ControlledFileImage(file, thumbnail),
      width: 2,
    );
    ImageProvider<Object> detailProvider = ResizeImage(
      _ControlledFileImage(file, failedDetail),
      width: 8,
    );
    addTearDown(() {
      releaseRetainedCoverImages();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
    Widget page({required bool isDetail}) => MaterialApp(
      home: SizedBox.square(
        dimension: 80,
        child: RetryingImage(
          retryKey: isDetail ? 'detail' : 'thumbnail',
          imageProviderBuilder: () =>
              isDetail ? detailProvider : thumbnailProvider,
          retainInImageCache: true,
          maxRetryAttempts: 1,
          retryDelay: const Duration(milliseconds: 100),
          fallbackBuilder: (_) => const Text('loading cover'),
        ),
      ),
    );
    await tester.pumpWidget(page(isDetail: false));
    thumbnail.complete(await _createTestImage());
    await tester.pumpAndSettle();
    final pixels = tester
        .widget<RawImage>(find.byType(RawImage))
        .image!
        .clone();
    addTearDown(pixels.dispose);
    await tester.pumpWidget(page(isDetail: true));
    await tester.pump();
    await tester.pump();
    expect(failedDetail.loadCount, 1);
    failedDetail._imageInfo.completeError(StateError('failed detail decode'));
    await tester.pump();
    await tester.pump();
    expect(find.text('loading cover'), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(pixels),
      isTrue,
    );
    detailProvider = ResizeImage(
      _ControlledFileImage(file, repairedDetail),
      width: 8,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump();
    expect(repairedDetail.loadCount, 1);
    expect(find.byType(CoverLoadingArtwork), findsNothing);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(pixels),
      isTrue,
    );
    repairedDetail.complete(await _createTestImage(8));
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 8);
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

  testWidgets('retained covers match equivalent paths at the same scale', (
    tester,
  ) async {
    addTearDown(() {
      releaseRetainedCoverImages();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
    for (final paths in [
      (r'C:\媒体\封面\..\shared-cover.png', 'c:/媒体/shared-cover.png'),
      ('covers/sub/../shared-cover.png', 'covers/shared-cover.png'),
    ]) {
      final controller = _ControlledImageProvider()
        ..complete(await _createTestImage());
      final retained = _ControlledFileImage(File(paths.$1), controller);
      retainCoverImage(retained, ImageConfiguration.empty);
      await tester.pump();

      final requested = ResizeImage(FileImage(File(paths.$2)), width: 1);
      expect(retainedCoverImageFor(requested), (
        provider: retained,
        isAdequate: true,
      ));
      expect(
        retainedCoverImageFor(
          ResizeImage(FileImage(File(paths.$2), scale: 2), width: 1),
        ),
        isNull,
      );
      releaseRetainedCoverImage(retained);
      expect(retainedCoverImageFor(requested), isNull);
    }
  });

  testWidgets('retained path matching follows LRU budget eviction', (
    tester,
  ) async {
    addTearDown(() {
      releaseRetainedCoverImages();
      configureRetainedCoverBudget(
        maximumSize: 200,
        maximumSizeBytes: 50 * 1024 * 1024,
      );
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
    configureRetainedCoverBudget(maximumSize: 2, maximumSizeBytes: 48);
    final providers = <FileImage>[];
    for (final name in ['first', 'second', 'third']) {
      final controller = _ControlledImageProvider()
        ..complete(await _createTestImage());
      final provider = _ControlledFileImage(
        File('covers/$name.png'),
        controller,
      );
      if (providers.length == 2) {
        retainCoverImage(providers.first, ImageConfiguration.empty);
      }
      providers.add(provider);
      retainCoverImage(provider, ImageConfiguration.empty);
      await tester.pump();
    }
    ImageProvider<Object> request(String name) =>
        ResizeImage(FileImage(File('covers/sub/../$name.png')), width: 1);

    expect(retainedCoverImageFor(request('first'))?.provider, providers.first);
    expect(retainedCoverImageFor(request('second')), isNull);
    expect(retainedCoverImageFor(request('third'))?.provider, providers.last);
    releaseRetainedCoverImages();
    expect(retainedCoverImageFor(request('first')), isNull);
    expect(retainedCoverImageFor(request('third')), isNull);
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

  testWidgets(
    'completed cover lookup is visible on the first frame during navigation',
    (tester) async {
      final navigation = Object();
      UiInteractionCoordinator.instance.beginNavigation(navigation);
      Widget page(String path) => MaterialApp(
        home: AsyncCoverImage(
          future: SynchronousFuture(path),
          requestKey: path,
          imageBuilder: (_, path) => Text(path),
          fallbackBuilder: (_) => const Text('fallback'),
          loadingBuilder: (_) => const Text('loading'),
        ),
      );

      await tester.pumpWidget(page('first.image'));
      expect(find.text('first.image'), findsOneWidget);
      expect(find.text('loading'), findsNothing);
      await tester.pumpWidget(page('second.image'));
      expect(find.text('second.image'), findsOneWidget);
      expect(find.text('first.image'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(page('first.image'));
      expect(find.text('first.image'), findsOneWidget);
      expect(find.text('loading'), findsNothing);
      expect(UiInteractionCoordinator.instance.pendingCommitCount, 0);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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
        if (scrolling) await gesture!.up();
        expect(find.text('decoding'), findsNothing);
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
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

  testWidgets(
    'new scroll covers start at most one cold load per frame',
    (tester) async {
      final providers = List.generate(4, (_) => _ControlledImageProvider());
      final interaction = UiInteractionCoordinator.instance;
      final scrolling = Object();
      addTearDown(() async {
        for (final provider in providers) {
          await provider.evict();
        }
      });
      Widget page(List<_ControlledImageProvider> visible) => MaterialApp(
        home: Column(
          children: [
            for (var index = 0; index < visible.length; index++)
              SizedBox(
                height: 90,
                child: RetryingImage(
                  key: ValueKey(index),
                  retryKey: visible[index],
                  imageProviderBuilder: () => visible[index],
                  fallbackBuilder: (_) => const SizedBox(),
                ),
              ),
          ],
        ),
      );
      interaction.beginInteraction(scrolling);
      await tester.pumpWidget(page(providers.take(3).toList()));
      int loads() =>
          providers.fold(0, (sum, provider) => sum + provider.loadCount);
      expect(loads(), 0);
      await tester.pump();
      expect(loads(), 1);
      // Reusing a visible row for another cover must also join the frame queue.
      await tester.pumpWidget(page([providers[3], providers[1], providers[2]]));
      expect(loads(), 2);
      await tester.pump();
      expect(loads(), 3);
      await tester.pump();
      expect(loads(), 4);
      expect(interaction.isInteracting, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(interaction.pendingCommitCount, 0);
      interaction.cancelInteraction(scrolling);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final foregroundProtection in [false, true]) {
    testWidgets(
      'cold covers resume one per frame and discard replaced ${foregroundProtection ? 'foreground' : 'navigation'} requests',
      (tester) async {
        final providers = List.generate(4, (_) => _ControlledImageProvider());
        final interaction = UiInteractionCoordinator.instance;
        addTearDown(() async {
          for (final provider in providers) {
            await provider.evict();
          }
        });
        Widget page(List<_ControlledImageProvider> visible) => MaterialApp(
          home: ScrollActivityGate(
            child: Column(
              key: const ValueKey('cover-slots'),
              children: [
                for (var index = 0; index < visible.length; index++)
                  SizedBox(
                    height: 90,
                    child: RetryingImage(
                      key: ValueKey(index),
                      retryKey: visible[index],
                      imageProviderBuilder: () => visible[index],
                      loadingBuilder: (_) => const Text('waiting'),
                      fallbackBuilder: (_) => const Text('decoding'),
                    ),
                  ),
              ],
            ),
          ),
        );
        int loadCount() =>
            providers.fold(0, (count, provider) => count + provider.loadCount);

        final protection = Object();
        void beginProtection() {
          if (foregroundProtection) {
            interaction.beginInteraction(protection, deferVisualUpdates: true);
          } else {
            interaction.beginNavigation(protection);
          }
        }

        void cancelProtection() {
          if (foregroundProtection) {
            interaction.cancelInteraction(protection);
          } else {
            interaction.cancelNavigation(protection);
          }
        }

        beginProtection();
        await tester.pumpWidget(page([]));
        await tester.pump();
        await tester.pumpWidget(page(providers.take(3).toList()));
        expect(loadCount(), 0);
        await tester.pumpWidget(
          page([providers[3], providers[1], providers[2]]),
        );
        expect(loadCount(), 0);
        cancelProtection();
        // Renewed protection before scheduled loads run keeps them deferred.
        beginProtection();
        await tester.pump();
        expect(loadCount(), 0);
        await tester.pump(const Duration(seconds: 1));
        expect(loadCount(), 0);
        final scrolling = Object();
        if (foregroundProtection) {
          interaction.beginInteraction(scrolling);
          interaction.endInteraction(protection);
          await tester.pump(interaction.idleDelay);
          expect(interaction.isInteracting, isTrue);
          expect(interaction.isVisualUpdateDeferred, isFalse);
        } else {
          cancelProtection();
          await tester.pump();
        }
        // Protection releases cold covers through structural commits.
        expect(loadCount(), lessThanOrEqualTo(1));
        while (loadCount() < 3) {
          final previous = loadCount();
          await tester.pump();
          expect(loadCount(), previous + 1);
        }
        expect(providers.first.loadCount, 0);
        for (final provider in providers.skip(1)) {
          provider.complete(await _createTestImage());
        }
        await tester.pumpAndSettle();
        final displayed = tester.widgetList<RawImage>(find.byType(RawImage));
        expect(displayed.where((image) => image.image != null), hasLength(3));
        interaction.cancelInteraction(scrolling);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(interaction.pendingCommitCount, 0);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('RetryingImage retries an image error during interaction', (
    tester,
  ) async {
    final provider = _ControlledImageProvider();
    addTearDown(provider.evict);
    UiInteractionCoordinator.instance.beginInteraction(Object());

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 90,
          child: RetryingImage(
            retryKey: 'broken-cover',
            imageProviderBuilder: () => provider,
            retryDelay: const Duration(milliseconds: 10),
            maxRetryAttempts: 1,
            fallbackBuilder: (_) => const Text('fallback'),
          ),
        ),
      ),
    );

    await tester.pump();
    provider._imageInfo.completeError(StateError('broken cover'));
    await tester.pump();
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    expect(provider.loadCount, 1);

    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(provider.loadCount, 2);
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

  for (final foregroundProtection in [false, true]) {
    testWidgets(
      'RetryingImage shows cached cover immediately during ${foregroundProtection ? 'foreground' : 'navigation'} protection after card recreation',
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
        if (foregroundProtection) {
          UiInteractionCoordinator.instance.beginInteraction(
            interactionSource,
            deferVisualUpdates: true,
          );
        } else {
          UiInteractionCoordinator.instance.beginNavigation(interactionSource);
        }
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
  }

  testWidgets('RetryingImage crossfades the placeholder over 300ms', (
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
      const Duration(milliseconds: 300),
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
    expect(midwayOpacity, closeTo(1 - kAppFadeCurve.transform(0.5), 0.001));
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
