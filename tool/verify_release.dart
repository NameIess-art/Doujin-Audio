import 'dart:io';

void main(List<String> args) {
  final explicitTag = _argumentValue(args, '--tag');
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

  if (!readme.contains('`$expectedVersion`')) {
    _fail('README.md does not contain current version `$expectedVersion`.');
  }
  if (!readme.contains('/releases/tag/$expectedTag')) {
    _fail('README.md release link must match tag $expectedTag.');
  }
  if (tag != null && tag.isNotEmpty && tag != expectedTag) {
    _fail('Git tag $tag does not match pubspec version $expectedTag.');
  }

  const androidVariants = <String>['universal', 'arm64', 'armv7', 'x64'];
  final documentedAssets = <String>[
    for (final variant in androidVariants)
      'NamelessAudio-android-$variant-$expectedTag.apk',
    'NamelessAudio-windows-x64-$expectedTag.zip',
  ];
  for (final asset in documentedAssets) {
    if (!readme.contains(asset)) {
      _fail('README.md is missing release asset: $asset');
    }
    if (!readme.contains('$asset.sha256')) {
      _fail('README.md is missing checksum asset: $asset.sha256');
    }
  }

  final workflowAssets = <String>[
    for (final variant in androidVariants)
      'NamelessAudio-android-$variant-\${{ github.ref_name }}.apk',
    'NamelessAudio-windows-x64-\${{ github.ref_name }}.zip',
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
  ]) {
    if (!workflow.contains(required)) {
      _fail(
        'Release workflow is missing required atomic publish step: $required',
      );
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
      _fail('${document.key} is missing the 0.13.0 reinstall/backup warning.');
    }
    if (document.value.contains('\uFFFD')) {
      _fail('${document.key} contains invalid replacement characters.');
    }
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
