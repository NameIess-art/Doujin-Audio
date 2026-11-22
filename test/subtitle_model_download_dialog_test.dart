import 'dart:async';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/features/player/application/subtitle_model_store.dart';
import 'package:doujin_audio/features/player/presentation/playlist/subtitle_model_download_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DownloadStore extends SubtitleModelStore {
  Completer<String> done = Completer<String>();
  int received = 0;
  bool active = false;
  Object? error;
  int cancelCalls = 0;

  @override
  SubtitleModelDownloadSnapshot snapshot(SubtitleModelSpec spec) =>
      SubtitleModelDownloadSnapshot(
        received: received,
        total: spec.bytes,
        active: active,
        error: error,
      );

  @override
  Future<String> ensure(
    SubtitleModelSpec spec, {
    void Function(double fraction, int received, int total)? onProgress,
    bool Function()? isCancelled,
  }) {
    active = true;
    error = null;
    notifyListeners();
    return done.future;
  }

  @override
  void cancelDownload(SubtitleModelSpec spec) {
    cancelCalls++;
    active = false;
    if (!done.isCompleted) {
      done.completeError(const SubtitleModelDownloadCancelled());
    }
    notifyListeners();
  }

  void fail(Object err) {
    active = false;
    error = err;
    if (!done.isCompleted) {
      done.completeError(err);
    }
    notifyListeners();
  }

  void advance(int bytes) {
    received = bytes;
    notifyListeners();
  }

  void finish(SubtitleModelSpec spec) {
    received = spec.bytes;
    active = false;
    notifyListeners();
    done.complete('model.gguf');
  }
}

void main() {
  testWidgets('dialog shows live progress and download survives dismissal', (
    tester,
  ) async {
    final language = AppLanguageProvider();
    final store = _DownloadStore();
    final results = <bool?>[];
    const spec = SubtitleModelSpec(
      'model.gguf',
      'https://example.com',
      2 * 1048576,
      'checksum',
    );
    const status = SubtitleModelStatus(
      ready: false,
      bytes: 2 * 1048576,
      availableBytes: 4 * 1048576,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appLanguageProviderInstanceProvider.overrideWithValue(language),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await showDialog<bool>(
                    context: context,
                    builder: (_) => SubtitleModelDownloadDialog(
                      store: store,
                      spec: spec,
                      status: status,
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(language.tr('confirm')));
    await tester.pump();
    store.advance(1048576);
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    expect(
      find.text(
        language.tr('subtitle_model_download_progress', {
          'received': '1.0',
          'total': '2.0',
        }),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(language.tr('subtitle_download_in_background')));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleModelDownloadDialog), findsNothing);
    expect(store.snapshot(spec).active, isTrue);
    expect(results, [true]);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    store.finish(spec);
    await tester.pumpAndSettle();
    expect(find.byType(SubtitleModelDownloadDialog), findsNothing);
    expect(results, [true, true]);
  });

  testWidgets(
    'P1-14: dialog cancels active download and displays error details on failure',
    (tester) async {
      final language = AppLanguageProvider();
      final store = _DownloadStore();
      final results = <bool?>[];
      const spec = SubtitleModelSpec(
        'model.gguf',
        'https://example.com',
        2 * 1048576,
        'checksum',
      );
      const status = SubtitleModelStatus(
        ready: false,
        bytes: 2 * 1048576,
        availableBytes: 4 * 1048576,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appLanguageProviderInstanceProvider.overrideWithValue(language),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => results.add(
                    await showDialog<bool>(
                      context: context,
                      builder: (_) => SubtitleModelDownloadDialog(
                        store: store,
                        spec: spec,
                        status: status,
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      // Start download and cancel it.
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(language.tr('confirm')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('subtitle_model_cancel_download')),
      );
      await tester.pumpAndSettle();
      expect(store.cancelCalls, 1);
      expect(results, [false]);

      // Start again and fail -> error details are displayed.
      store.done = Completer<String>();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(language.tr('confirm')));
      await tester.pump();
      store.fail('HTTP 503 Service Unavailable');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle_model_download_error_detail')),
        findsOneWidget,
      );
      expect(find.textContaining('HTTP 503'), findsOneWidget);
      expect(find.text(language.tr('retry')), findsOneWidget);
    },
  );
}
