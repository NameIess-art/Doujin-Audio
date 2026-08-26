import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  final libDirectory = Directory('lib');

  test('removed compatibility runtime APIs cannot return', () {
    final violations = <String>[];
    final forbiddenText = <String>[
      'Audio'
          'Provider',
      'createAudio'
          'ProviderOverrides',
      'audio_'
          'provider_',
      'package:'
          'provider',
      'Multi'
          'Provider',
    ];
    final contextAccess = RegExp(r'context\.(?:read|watch|select)\s*[<(]');
    for (final root in <Directory>[
      libDirectory,
      Directory('test'),
      Directory('integration_test'),
    ]) {
      for (final file in _dartFiles(root)) {
        final source = file.readAsStringSync();
        final matchesText = forbiddenText.any(source.contains);
        if (matchesText || contextAccess.hasMatch(source)) {
          violations.add(_normalizedPath(file));
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('feature domain code remains framework and layer independent', () {
    final violations = <String>[];
    for (final file in _dartFiles(libDirectory)) {
      final path = _normalizedPath(file);
      if (!path.contains('/domain/')) {
        continue;
      }
      final content = file.readAsStringSync();
      for (final import in _imports(content)) {
        if (import.startsWith('package:flutter') ||
            import.startsWith('package:just_audio') ||
            import.contains('/application/') ||
            import.contains('/presentation/') ||
            import.contains('..${Platform.pathSeparator}application') ||
            import.contains('..${Platform.pathSeparator}presentation') ||
            import.contains('/core/persistence/') ||
            import.contains('/infrastructure/') ||
            import.contains('core/persistence') ||
            import.contains('infrastructure')) {
          violations.add('$path imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test(
    'platform channels are created only by gateways and playback bridge',
    () {
      final violations = <String>[];
      final channelCreation = RegExp(r'\b(?:MethodChannel|EventChannel)\s*\(');
      for (final file in _dartFiles(libDirectory)) {
        final path = _normalizedPath(file);
        if (!channelCreation.hasMatch(file.readAsStringSync())) {
          continue;
        }
        final isPlatformGateway = path.startsWith('lib/core/platform/');
        final isPlaybackBridge =
            path ==
            'lib/features/player/application/native_playback_bridge.dart';
        if (!isPlatformGateway && !isPlaybackBridge) {
          violations.add(path);
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('presentation does not access the database or create channels', () {
    final violations = <String>[];
    final forbidden = RegExp(
      r"app_database\.dart|\b(?:MethodChannel|EventChannel)\s*\(",
    );
    for (final file in _dartFiles(libDirectory)) {
      final path = _normalizedPath(file);
      if (!path.contains('/presentation/')) {
        continue;
      }
      if (forbidden.hasMatch(file.readAsStringSync())) {
        violations.add(path);
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('feature application code does not depend on UI interaction state', () {
    final violations = <String>[];
    for (final file in _dartFiles(libDirectory)) {
      final path = _normalizedPath(file);
      if (!path.contains('/features/') || !path.contains('/application/')) {
        continue;
      }
      final source = file.readAsStringSync();
      if (source.contains('ui_interaction_coordinator.dart') ||
          source.contains('UiInteractionCoordinator.instance')) {
        violations.add(path);
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('feature application code does not import infrastructure', () {
    final violations = <String>[];
    for (final file in _dartFiles(libDirectory)) {
      final path = _normalizedPath(file);
      if (!path.contains('/features/') || !path.contains('/application/')) {
        continue;
      }
      for (final import in _imports(file.readAsStringSync())) {
        if (import.contains('infrastructure/')) {
          violations.add('$path imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('feature application code does not depend on app assembly', () {
    final violations = <String>[];
    for (final file in _dartFiles(libDirectory)) {
      final filePath = _normalizedPath(file);
      if (!filePath.contains('/features/') ||
          !filePath.contains('/application/')) {
        continue;
      }
      for (final import in _imports(file.readAsStringSync())) {
        final resolved = _resolvedProjectImport(file, import);
        if (resolved != null && resolved.startsWith('lib/app/')) {
          violations.add('$filePath imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('app state does not depend on presentation', () {
    final violations = <String>[];
    for (final file in _dartFiles(Directory('lib/app/state'))) {
      final filePath = _normalizedPath(file);
      for (final import in _imports(file.readAsStringSync())) {
        final resolved = _resolvedProjectImport(file, import);
        if (resolved != null && resolved.contains('/presentation/')) {
          violations.add('$filePath imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('presentation does not import platform service implementations', () {
    final violations = <String>[];
    for (final file in _dartFiles(libDirectory)) {
      final filePath = _normalizedPath(file);
      if (!filePath.contains('/presentation/')) continue;
      for (final import in _imports(file.readAsStringSync())) {
        final resolved = _resolvedProjectImport(file, import);
        if (resolved != null &&
            resolved.startsWith('lib/core/platform/') &&
            resolved.endsWith('_service.dart')) {
          violations.add('$filePath imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('presentation does not import platform permission plugins', () {
    final violations = <String>[];
    for (final file in _dartFiles(libDirectory)) {
      final filePath = _normalizedPath(file);
      if (!filePath.contains('/presentation/')) continue;
      for (final import in _imports(file.readAsStringSync())) {
        if (import == 'package:permission_handler/permission_handler.dart') {
          violations.add('$filePath imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('production code does not silently swallow exceptions', () {
    final violations = <String>[];
    final emptyCatch = RegExp(r'catch\s*\([^)]*\)\s*\{\s*\}', multiLine: true);
    final emptyCatchError = RegExp(
      r'catchError\s*\(\s*\([^)]*\)\s*\{\s*\}\s*\)',
      multiLine: true,
    );
    for (final file in _dartFiles(libDirectory)) {
      final source = file.readAsStringSync();
      if (emptyCatch.hasMatch(source) || emptyCatchError.hasMatch(source)) {
        violations.add(_normalizedPath(file));
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('production code does not pierce facade service boundaries', () {
    final violations = <String>[];
    final serviceAccess = RegExp(r'\.(?:service|stateService)\b');
    for (final file in _dartFiles(libDirectory)) {
      if (serviceAccess.hasMatch(file.readAsStringSync())) {
        violations.add(_normalizedPath(file));
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('core does not depend on feature code', () {
    final violations = <String>[];
    for (final file in _dartFiles(Directory('lib/core'))) {
      final path = _normalizedPath(file);
      for (final import in _imports(file.readAsStringSync())) {
        if (import.contains('/features/') || import.contains('../features/')) {
          violations.add('$path imports $import');
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('ASMR task state is owned by a composable task store', () {
    final manager = File(
      'lib/features/asmr/application/asmr_download_manager.dart',
    ).readAsStringSync();
    final store = File(
      'lib/features/asmr/application/asmr_download_task_store.dart',
    ).readAsStringSync();

    expect(store, contains('final class AsmrDownloadTaskStore'));
    expect(store, isNot(contains('part of')));
    expect(
      RegExp(r'extension\s+\w+\s+on\s+AsmrDownloadManager').hasMatch(store),
      isFalse,
    );
    expect(manager, contains('_store = AsmrDownloadTaskStore('));
    expect(manager, isNot(contains("part 'asmr_download_task_store.dart'")));
    expect(
      manager,
      isNot(contains('Map<int, AsmrDownloadTaskSnapshot> _tasks')),
    );
  });
}

Iterable<File> _dartFiles(Directory root) sync* {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

String _normalizedPath(File file) => file.path.replaceAll('\\', '/');

Iterable<String> _imports(String content) sync* {
  final pattern = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''', multiLine: true);
  for (final match in pattern.allMatches(content)) {
    yield match.group(1)!;
  }
}

String? _resolvedProjectImport(File source, String import) {
  if (import.startsWith('dart:') ||
      (import.startsWith('package:') &&
          !import.startsWith('package:doujin_audio/'))) {
    return null;
  }
  if (import.startsWith('package:doujin_audio/')) {
    return 'lib/${import.substring('package:doujin_audio/'.length)}';
  }
  return path
      .normalize(path.join(path.dirname(source.path), import))
      .replaceAll('\\', '/');
}
