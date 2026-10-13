import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';

final class _CountingFileImage extends FileImage {
  const _CountingFileImage(super.file, this.onLoad);

  final VoidCallback onLoad;

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    onLoad();
    return super.loadImage(key, decode);
  }
}

Future<({bool synchronous, int width, int height, int bytes})> _show(
  ImageProvider<Object> provider,
) async {
  restoreRetainedCoverImage(provider);
  final ready =
      Completer<({bool synchronous, int width, int height, int bytes})>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener((info, synchronous) {
    ready.complete((
      synchronous: synchronous,
      width: info.image.width,
      height: info.image.height,
      bytes: info.sizeBytes,
    ));
    retainCoverImage(provider, ImageConfiguration.empty);
    info.dispose();
    stream.removeListener(listener);
  }, onError: ready.completeError);
  stream.addListener(listener);
  return ready.future;
}

void main() {
  testWidgets('100 file covers compare decoded budget and first-screen return', (
    tester,
  ) async {
    const budget = 50 * 1024 * 1024;
    final cache = PaintingBinding.instance.imageCache;
    final previousBytes = cache.maximumSizeBytes;
    final previousCount = cache.maximumSize;
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover-budget-'),
    );
    addTearDown(() async {
      releaseRetainedCoverImages();
      cache.clear();
      cache.clearLiveImages();
      cache.maximumSize = previousCount;
      cache.maximumSizeBytes = previousBytes;
      configureRetainedCoverBudget(maximumSize: 200, maximumSizeBytes: budget);
      await directory!.delete(recursive: true);
    });
    final files = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xFF336699), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(600, 450);
      picture.dispose();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      return Future.wait(
        List.generate(100, (index) {
          return File('${directory!.path}/$index.png').writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
        }),
      );
    });
    final reports = <Map<String, Object>>[];
    final thumbnailWidth = coverThumbnailCacheWidth(
      logicalWidth: 120,
      devicePixelRatio: 2,
      resolution: CoverImageResolution.balanced,
    );
    expect(thumbnailWidth, 256);
    for (final width in [600, thumbnailWidth]) {
      releaseRetainedCoverImages();
      cache.clear();
      cache.clearLiveImages();
      cache.maximumSize = 200;
      cache.maximumSizeBytes = budget;
      configureRetainedCoverBudget(maximumSize: 200, maximumSizeBytes: budget);
      var loads = 0;
      final sources = files!
          .map((file) => _CountingFileImage(file, () => loads++))
          .toList();
      final providers = sources
          .map((file) => ResizeImage(file, width: width))
          .toList();
      var decodedBytes = 0;
      var decodedHeight = 0;
      final coldWatch = Stopwatch()..start();
      for (final provider in providers) {
        final frame = (await tester.runAsync(() => _show(provider)))!;
        expect(frame.width, width);
        decodedBytes += frame.bytes;
        decodedHeight = frame.height;
        tester.binding.scheduleFrame();
        await tester.pump();
      }
      coldWatch.stop();
      final cachedCount = cache.currentSize;
      final cachedBytes = cache.currentSizeBytes;
      final beforeReturn = loads;
      var synchronousReturns = 0;
      final returnWatch = Stopwatch()..start();
      for (final provider in providers.take(10)) {
        final frame = (await tester.runAsync(() => _show(provider)))!;
        if (frame.synchronous) synchronousReturns++;
        tester.binding.scheduleFrame();
        await tester.pump();
      }
      returnWatch.stop();
      final reloads = loads - beforeReturn;
      expect(beforeReturn, 100);
      expect(reloads, width == 600 ? 10 : 0);
      expect(synchronousReturns, width == 600 ? 0 : 10);
      reports.add({
        'width': width,
        'height': decodedHeight,
        'decodedBytesFor100': decodedBytes,
        'cacheCountAfter100': cachedCount,
        'cacheBytesAfter100': cachedBytes,
        'firstScreenReloads': reloads,
        'firstScreenSynchronousReturns': synchronousReturns,
        'testColdUs': coldWatch.elapsedMicroseconds,
        'testReturnUs': returnWatch.elapsedMicroseconds,
      });
    }
    // Timings include test pumping; they are not app display/frame timings.
    debugPrint('COVER_DECODE_BUDGET ${jsonEncode(reports)}');
  });
}
