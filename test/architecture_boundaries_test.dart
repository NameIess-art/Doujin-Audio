import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
            import.contains('..${Platform.pathSeparator}presentation')) {
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
