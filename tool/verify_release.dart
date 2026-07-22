import 'dart:io';

void main(List<String> args) {
  final explicitTag = _argumentValue(args, '--tag');
  final printTag = args.contains('--print-tag');
  final tag =
      explicitTag ??
      (Platform.environment['GITHUB_REF_TYPE'] == 'tag'
          ? Platform.environment['GITHUB_REF_NAME']
          : null);
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final readme = File('README.md').readAsStringSync();
  final releaseNotes = File('release_notes.md').readAsStringSync();
  final workflow = File('.github/workflows/flutter.yml').readAsStringSync();

  final versionMatch = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\+([0-9]+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (versionMatch == null) {
    _fail('pubspec.yaml must declare version as x.y.z[-prerelease]+build.');
  }

  final versionName = versionMatch.group(1)!;
  final buildNumber = versionMatch.group(2)!;
  final expectedTag = 'v$versionName';
  final expectedVersion = '$versionName+$buildNumber';

  if (!readme.contains('/releases/latest')) {
    _fail('README.md must link to the GitHub Latest release.');
  }
  if (tag != null && tag.isNotEmpty && tag != expectedTag) {
    _fail('Git tag $tag does not match pubspec version $expectedTag.');
  }

  const androidVariants = <String>['universal', 'arm64', 'armv7', 'x64'];
  const documentedTag = '<tag>';
  final documentedAssets = <String>[
    for (final variant in androidVariants)
      'NamelessAudio-android-$variant-$documentedTag.apk',
  ];
  for (final asset in documentedAssets) {
    for (final document in <MapEntry<String, String>>[
      MapEntry<String, String>('README.md', readme),
      MapEntry<String, String>('release_notes.md', releaseNotes),
    ]) {
      if (!document.value.contains(asset)) {
        _fail('${document.key} is missing release asset pattern: $asset');
      }
      if (!document.value.contains('$asset.sha256')) {
        _fail('${document.key} is missing checksum pattern: $asset.sha256');
      }
    }
  }

  final workflowAssets = <String>[
    for (final variant in androidVariants)
      'NamelessAudio-android-$variant-\${{ github.ref_name }}.apk',
  ];
  for (final asset in workflowAssets) {
    if (!workflow.contains(asset) || !workflow.contains('$asset.sha256')) {
      _fail('Release workflow is missing asset/checksum pattern: $asset');
    }
  }

  for (final required in <String>[
    'publish-release:',
    '--notes-file release_notes.md',
    '--draft',
    '--draft=false',
    '--latest',
    'actions/upload-artifact@',
    'actions/download-artifact@',
    'version="\${tag#v}"',
    '--title "Nameless Audio \$version"',
  ]) {
    if (!workflow.contains(required)) {
      _fail(
        'Release workflow is missing required atomic publish step: $required',
      );
    }
  }

  for (final required in <String>[
    'actions: read',
    'fetch-depth: 0',
    'git fetch origin main --no-tags',
    'git merge-base --is-ancestor "\$GITHUB_SHA" origin/main',
    'gh run list',
    '--workflow flutter.yml',
    '--branch main',
    '--commit "\$GITHUB_SHA"',
    '--event push',
    '--status success',
    './gradlew :app:lintDebug',
  ]) {
    if (!workflow.contains(required)) {
      _fail('Release workflow is missing required quality gate: $required');
    }
  }
  if (workflow.contains('--latest=false')) {
    _fail('Stable release workflow must publish the release as Latest.');
  }
  if (workflow.contains('--clobber')) {
    _fail('Release workflow must not overwrite existing public assets.');
  }

  for (final document in <MapEntry<String, String>>[
    MapEntry<String, String>('README.md', readme),
    MapEntry<String, String>('release_notes.md', releaseNotes),
  ]) {
    if (!document.value.contains('必须先卸载旧版本再重新安装') ||
        !document.value.contains('.nalbackup')) {
      _fail('${document.key} is missing the reinstall/backup warning.');
    }
    if (document.value.contains('\uFFFD')) {
      _fail('${document.key} contains invalid replacement characters.');
    }
  }

  final reusableMetadata = <MapEntry<String, String>>[
    MapEntry<String, String>('README.md', readme),
    MapEntry<String, String>('release_notes.md', releaseNotes),
    MapEntry<String, String>('.github/workflows/flutter.yml', workflow),
    MapEntry<String, String>(
      '.github/ISSUE_TEMPLATE/bug_report.yml',
      File('.github/ISSUE_TEMPLATE/bug_report.yml').readAsStringSync(),
    ),
    MapEntry<String, String>(
      'android UpdateMethodHandler.kt',
      File(
        'android/app/src/main/kotlin/com/nameless/audio/update/UpdateMethodHandler.kt',
      ).readAsStringSync(),
    ),
  ];
  for (final metadata in reusableMetadata) {
    if (metadata.value.contains(expectedVersion) ||
        metadata.value.contains(expectedTag)) {
      _fail(
        '${metadata.key} hard-codes the current application version; '
        'derive it from pubspec.yaml, package metadata, or the release tag.',
      );
    }
  }

  if (printTag) {
    stdout.writeln(expectedTag);
    return;
  }

  stdout.writeln(
    'Release metadata verified: version=$expectedVersion tag=$expectedTag '
    'assets=${documentedAssets.length * 2}',
  );
}

String? _argumentValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1) return null;
  if (index + 1 >= args.length) {
    _fail('Missing value for $name.');
  }
  return args[index + 1];
}

Never _fail(String message) {
  stderr.writeln('Release verification failed: $message');
  exit(1);
}
