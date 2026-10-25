import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _samplePoints = [
  (70, 60), // Image center.
  (30, 60), // Straight image edge.
  (30, 30), // Rounded image corner.
  (10, 10), // Unaffected surface.
  (28, 60),
  (111, 60),
  (70, 28),
  (70, 93),
  (22, 60), // Outside the compact card's padding.
  (118, 60),
  (70, 22),
  (70, 99),
];

Future<List<Color>> _pixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData())!;
        return _samplePoints.map((point) {
          final offset = (point.$2 * image.width + point.$1) * 4;
          return Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          );
        }).toList();
      } finally {
        image.dispose();
      }
    }))!;

void main() {
  for (final brightness in Brightness.values) {
    for (final radius in [null, 20.0]) {
      testWidgets(
        'cover retains its size and corners with a compact exterior shadow '
        'in $brightness (radius: ${radius ?? 'default'})',
        (tester) async {
          final previousDisableShadows = debugDisableShadows;
          debugDisableShadows = false;
          try {
            await tester.binding.setSurfaceSize(const Size(140, 120));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final boundaryKey = GlobalKey();
            const artworkKey = ValueKey('artwork');
            const artworkColor = Color(0xffee3366);
            final background = brightness == Brightness.light
                ? Colors.white
                : const Color(0xff242424);
            const artwork = SizedBox(
              key: artworkKey,
              width: 80,
              height: 60,
              child: ColoredBox(color: artworkColor),
            );
            var showShadow = true;
            var usePreviousShadow = false;
            late StateSetter updateShadow;
            await tester.pumpWidget(
              Theme(
                data: ThemeData(brightness: brightness),
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: ColoredBox(
                    color: background,
                    child: Center(
                      child: StatefulBuilder(
                        builder: (context, setState) {
                          updateShadow = setState;
                          final frame = radius == null
                              ? CoverArtworkFrame(
                                  showShadow: showShadow,
                                  child: artwork,
                                )
                              : CoverArtworkFrame(
                                  showShadow: showShadow,
                                  borderRadius: BorderRadius.circular(radius),
                                  child: artwork,
                                );
                          return usePreviousShadow
                              ? DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      radius ?? 8,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: brightness == Brightness.dark
                                            ? const Color(0x70000000)
                                            : const Color(0x3D000000),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      radius ?? 8,
                                    ),
                                    child: artwork,
                                  ),
                                )
                              : frame;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );

            expect(
              tester.getSize(find.byType(CoverArtworkFrame)),
              const Size(80, 60),
            );
            expect(tester.getSize(find.byKey(artworkKey)), const Size(80, 60));
            final pixels = await _pixels(tester, boundaryKey);
            expect(pixels[0], artworkColor);
            expect(pixels[1], artworkColor);
            // A rounded corner must expose the surface or shadow, not the image.
            expect(pixels[2].r, closeTo(pixels[2].g, 1 / 255));
            expect(pixels[3], background);
            for (final outside in pixels.skip(4).take(4)) {
              expect(outside.r, lessThan(background.r));
              expect(outside.r, closeTo(outside.g, 1 / 255));
              expect(outside.a, 1);
            }
            for (final outside in pixels.skip(8)) {
              expect(outside.r, closeTo(background.r, 1 / 255));
            }
            updateShadow(() => usePreviousShadow = true);
            await tester.pump();
            final previousPixels = await _pixels(tester, boundaryKey);
            for (var i = 8; i < pixels.length; i++) {
              expect(pixels[i].r, greaterThanOrEqualTo(previousPixels[i].r));
            }
            expect(
              Iterable<int>.generate(pixels.length - 8, (i) => i + 8)
                  .any((i) => pixels[i].r > previousPixels[i].r),
              isTrue,
            );
            updateShadow(() {
              usePreviousShadow = false;
              showShadow = false;
            });
            await tester.pump();
            final withoutShadow = await _pixels(tester, boundaryKey);
            expect(withoutShadow.take(2), everyElement(artworkColor));
            expect(withoutShadow.skip(2), everyElement(background));
          } finally {
            debugDisableShadows = previousDisableShadows;
          }
        },
      );
    }
  }
}
