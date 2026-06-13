import 'dart:io';

void main(List<String> args) {
  final tag =
      _argumentValue(args, '--tag') ?? Platform.environment['GITHUB_REF_NAME'];
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final readme = File('README.md').readAsStringSync();
  final workflow = File('.github/workflows/flutter.yml').readAsStringSync();

  final versionMatch = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (versionMatch == null) {
    _fail('pubspec.yaml must declare version as x.y.z+build.');
  }

  final versionName = versionMatch.group(1)!;
  final buildNumber = versionMatch.group(2)!;
  final expectedTag = 'v$versionName';
  final expectedVersion = '$versionName+$buildNumber';

  if (!readme.contains('`$expectedVersion`')) {
    _fail('README.md does not contain current version `$expectedVersion`.');
  }
  if (!readme.contains('/releases/tag/$expectedTag')) {
    _fail('README.md does not link to release tag $expectedTag.');
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
