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
  final expectedTag = 'v$versionName';
  final expectedVersion = '$versionName+$buildNumber';

  if (!readme.contains('当前开发版本：`$expectedVersion`')) {
    _fail(
      'README.md does not contain current development version `$expectedVersion`.',
    );
  }
  if (!readme.contains('最新已发布版本：`0.12.4+1204`') ||
      !readme.contains('/releases/tag/v0.12.4')) {
    _fail('README.md must keep v0.12.4 as the latest published release.');
  }
  if (tag != null && tag.isNotEmpty && tag != expectedTag) {
    _fail('Git tag $tag does not match pubspec version $expectedTag.');
  }
  if (tag != null && tag.isNotEmpty && !tag.startsWith('v1.')) {
    _fail('1.x release workflow only accepts v1.* tags.');
  }

  for (final assetPattern in <String>[
    'NamelessAudio-v1-android-arm64-\${GITHUB_REF_NAME}.apk',
    'NamelessAudio-v1-windows-x64-\${{ github.ref_name }}.zip',
  ]) {
    if (!workflow.contains(assetPattern)) {
      _fail(
        'Release workflow is missing expected asset pattern: $assetPattern',
      );
    }
  }
  if (!workflow.contains('--latest=false')) {
    _fail('Release workflow must not replace the old latest release.');
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
