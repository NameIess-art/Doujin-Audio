import 'dart:async';
import 'dart:ui' as ui;

import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowImage extends ImageProvider<_SlowImage> {
  final ready = Completer<ImageInfo>();
  int loads = 0;

  @override
  Future<_SlowImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_SlowImage key, ImageDecoderCallback decode) {
    loads++;
    return OneFrameImageStreamCompleter(ready.future);
  }

  Future<void> complete(WidgetTester tester) async {
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xFF336699), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 4);
      picture.dispose();
      return image;
    });
    ready.complete(ImageInfo(image: image!));
  }
}

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(() {
    releaseRetainedCoverImages();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    interaction.resetForTest();
  });

  testWidgets(
    '1000 full cards bound cold decodes during fast reverse scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(450, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final reports = <Map<String, Object>>[];
      for (final budgeted in [false, true]) {
        final providers = List.generate(1000, (_) => _SlowImage());
        var mounts = 0;
        var layouts = 0;
        var maxMounted = 0;
        final stopwatch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: ScrollActivityGate(
              child: ListView.builder(
                itemCount: providers.length,
                itemExtent: LibraryLikeCardMetrics.rootTileHeight,
                cacheExtent: 320,
                itemBuilder: (context, index) {
                  mounts++;
                  return _LayoutCounter(
                    onLayout: () => layouts++,
                    child: SwipeRevealCard(
                      shape: LibraryLikeCardMetrics.cardShape,
                      onRemove: () {},
                      actionLabel: 'Remove',
                      removeTooltip: 'Remove',
                      child: LibraryLikeWorkCardContent(
                        title: 'Work $index with a descriptive title',
                        lines: const [
                          LibraryLikeInfoLineData(
                            'Tags',
                            'ASMR',
                            icon: Icons.label,
                          ),
                          LibraryLikeInfoLineData(
                            'Circle',
                            'Studio',
                            icon: Icons.storefront,
                          ),
                        ],
                        coverBuilder: (width) => SizedBox(
                          width: width,
                          height: 90,
                          child: RetryingImage(
                            retryKey: providers[index],
                            browseThumbnail: budgeted,
                            imageProviderBuilder: () => providers[index],
                            fallbackBuilder: (_) => const SizedBox(),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(ListView)),
        );
        for (final direction in [-1, 1]) {
          for (var frame = 0; frame < 30; frame++) {
            await gesture.moveBy(Offset(0, direction * 45));
            await tester.pump(const Duration(milliseconds: 16));
            final mounted = find.byType(SwipeRevealCard).evaluate().length;
            if (mounted > maxMounted) maxMounted = mounted;
            expect(mounted, lessThan(30));
          }
        }
        stopwatch.stop();
        final started = providers
            .where((provider) => provider.loads > 0)
            .toList();
        reports.add({
          'policy': budgeted ? 'browse' : 'previous',
          'mounts': mounts,
          'layouts': layouts,
          'peakMounted': maxMounted,
          'coldDecodesInFlight': started.length,
          'testElapsedUs': stopwatch.elapsedMicroseconds,
        });
        if (budgeted) {
          expect(started.length, lessThanOrEqualTo(1));
        } else {
          expect(started.length, greaterThan(1));
        }
        await gesture.cancel();
        await tester.pumpWidget(const SizedBox());
        for (final provider in started) {
          await provider.complete(tester);
        }
        await tester.pumpAndSettle();
        interaction.resetForTest();
        releaseRetainedCoverImages();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        await tester.pump();
      }
      debugPrint('BROWSE_SCROLL_BUDGET $reports');
      expect(reports.last['mounts'], reports.first['mounts']);
      expect(
        reports.last['layouts'] as int,
        lessThanOrEqualTo(reports.first['layouts'] as int),
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'browse decodes wait for the first frame, skip retired requests and deduplicate',
    (tester) async {
      final first = _SlowImage();
      final retired = _SlowImage();
      final visible = _SlowImage();
      var retiredActive = true;
      final firstLoad = warmBrowseThumbnail(
        first,
        ImageConfiguration.empty,
        isActive: () => true,
      );
      final obsolete = warmBrowseThumbnail(
        retired,
        ImageConfiguration.empty,
        isActive: () => retiredActive,
      );
      final visibleLoad = warmBrowseThumbnail(
        visible,
        ImageConfiguration.empty,
        isActive: () => true,
        priority: 0,
      );
      final duplicate = warmBrowseThumbnail(
        visible,
        ImageConfiguration.empty,
        isActive: () => true,
        priority: 0,
      );
      expect(identical(visibleLoad, duplicate), isTrue);
      await tester.pump();
      expect(first.loads, 1);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(visible.loads, 0);
      }
      retiredActive = false;
      await first.complete(tester);
      await tester.pump();
      await firstLoad;
      await tester.pump();
      expect(visible.loads, 1);
      expect(retired.loads, 0);
      await visible.complete(tester);
      await tester.pump();
      await visibleLoad;
      await obsolete;
      expect(visible.loads, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('decode failure releases the next thumbnail slot', (
    tester,
  ) async {
    final failed = _SlowImage();
    final next = _SlowImage();
    final failure = warmBrowseThumbnail(
      failed,
      ImageConfiguration.empty,
      isActive: () => true,
    );
    final failureExpectation = expectLater(failure, throwsStateError);
    final following = warmBrowseThumbnail(
      next,
      ImageConfiguration.empty,
      isActive: () => true,
    );
    await tester.pump();
    failed.ready.completeError(StateError('broken artwork'));
    await tester.pump();
    await failureExpectation;
    await tester.pump();
    expect(next.loads, 1);
    await next.complete(tester);
    await tester.pump();
    await following;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'retiring a request before admission cannot hold the global decode slot',
    (tester) async {
      final retired = _SlowImage();
      final next = _SlowImage();
      var active = true;
      final obsolete = warmBrowseThumbnail(
        retired,
        ImageConfiguration.empty,
        isActive: () => active,
      );
      active = false;
      interaction.resetForTest();
      final following = warmBrowseThumbnail(
        next,
        ImageConfiguration.empty,
        isActive: () => true,
      );
      await tester.pump();
      await tester.pump();
      expect(retired.loads, 0);
      expect(next.loads, 1);
      await next.complete(tester);
      await tester.pump();
      await Future.wait([obsolete, following]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fast scrolling defers cold covers but keeps cached pixels and resumes visible covers',
    (tester) async {
      final warm = _SlowImage();
      final cold = _SlowImage();
      final seed = warmBrowseThumbnail(
        warm,
        ImageConfiguration.empty,
        isActive: () => true,
      );
      await tester.pump();
      await warm.complete(tester);
      await tester.pump();
      await seed;
      late BuildContext scope;
      var contentBuilds = 0;
      var showCovers = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: ScrollActivityGate(
            child: Builder(
              builder: (context) {
                scope = context;
                return StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    contentBuilds++;
                    return Column(
                      children: [
                        if (showCovers)
                          for (final provider in [warm, cold])
                            SizedBox.square(
                              dimension: 40,
                              child: RetryingImage(
                                retryKey: provider,
                                browseThumbnail: true,
                                retainInImageCache: true,
                                imageProviderBuilder: () => provider,
                                fallbackBuilder: (_) => const SizedBox(),
                              ),
                            ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      );
      FixedScrollMetrics metrics(double pixels) => FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 10000,
        pixels: pixels,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      ScrollStartNotification(
        metrics: metrics(0),
        context: scope,
      ).dispatch(scope);
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 20));
      ScrollUpdateNotification(
        metrics: metrics(100),
        context: scope,
        scrollDelta: 100,
      ).dispatch(scope);
      expect(
        ScrollActivityGate.isFastScrollingWithoutDependencyOf(scope),
        isTrue,
      );
      expect(
        contentBuilds,
        1,
        reason: 'Speed observers must not rebuild the list',
      );
      update(() => showCovers = true);
      await tester.pump();
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(warm.loads, 1);
      expect(cold.loads, 0);
      expect(find.byType(Image), findsOneWidget);
      ScrollEndNotification(
        metrics: metrics(100),
        context: scope,
      ).dispatch(scope);
      await tester.pump(const Duration(milliseconds: 160));
      for (var frame = 0; frame < 4 && cold.loads == 0; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(cold.loads, 1);
      await cold.complete(tester);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      expect(warm.loads, 1);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

class _LayoutCounter extends SingleChildRenderObjectWidget {
  const _LayoutCounter({required this.onLayout, required super.child});
  final VoidCallback onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _LayoutCounterBox(onLayout);
}

class _LayoutCounterBox extends RenderProxyBox {
  _LayoutCounterBox(this.onLayout);
  final VoidCallback onLayout;
  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}
