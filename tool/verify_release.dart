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
  final expectedTag = versionName;
  final expectedVersion = '$versionName+$buildNumber';

  if (!readme.contains('当前版本：`$expectedVersion`')) {
    _fail(
      'README.md does not contain current development version `$expectedVersion`.',
    );
  }
  if (!readme.contains('/releases/tag/$expectedTag')) {
    _fail('README.md release link must match tag $expectedTag.');
  }
  if (tag != null && tag.isNotEmpty && tag != expectedTag) {
    _fail('Git tag $tag does not match pubspec version $expectedTag.');
  }

  for (final assetPattern in <String>[
    'NamelessAudio-android-arm64-\${GITHUB_REF_NAME}.apk',
    'NamelessAudio-windows-x64-\${{ github.ref_name }}.zip',
  ]) {
    if (!workflow.contains(assetPattern)) {
      _fail(
        'Release workflow is missing expected asset pattern: $assetPattern',
      );
    }
  }
  if (!workflow.contains('--latest=false')) {
    _fail(
      'Release workflow must not replace the latest release automatically.',
    );
  }
  if (workflow.contains('--clobber')) {
    _fail('Release workflow must not overwrite existing assets.');
  }

  stdout.writeln(
    'Release metadata verified: version=$expectedVersion tag=$expectedTag',
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
