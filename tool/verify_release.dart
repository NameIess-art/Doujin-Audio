import 'dart:convert';
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
      'DoujinAudio-android-$variant-$documentedTag.apk',
    'DoujinAudio-windows-x64-$documentedTag-setup.exe',
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
      'DoujinAudio-android-$variant-\${{ github.ref_name }}.apk',
    'DoujinAudio-windows-x64-\${tag}-setup.exe',
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
    '--title "Doujin Audio \$version"',
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
    if (!document.value.contains('不能覆盖') ||
        !document.value.contains('不会继承') ||
        !document.value.contains('.dabackup')) {
      _fail('${document.key} is missing the app identity/backup warning.');
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
        'android/app/src/main/kotlin/com/doujin/audio/update/UpdateMethodHandler.kt',
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

  _verifyWindowsThirdPartyMetadata();

  if (printTag) {
    stdout.writeln(expectedTag);
    return;
  }

  stdout.writeln(
    'Release metadata verified: version=$expectedVersion tag=$expectedTag '
    'assets=${documentedAssets.length * 2}',
  );
}

void _verifyWindowsThirdPartyMetadata() {
  final thirdParty = File('tool/windows_third_party.txt').readAsStringSync();
  if (thirdParty.contains('\uFFFD')) {
    _fail('tool/windows_third_party.txt contains invalid replacement characters.');
  }

  final dependenciesRaw = File(
    'tool/windows_dependencies.json',
  ).readAsStringSync();
  final dependencies = jsonDecode(dependenciesRaw) as Map<String, dynamic>;
  final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  Map<String, dynamic> requireSection(String name) {
    final section = dependencies[name];
    if (section is! Map<String, dynamic>) {
      _fail('tool/windows_dependencies.json is missing object section: $name');
    }
    final sha = section['sha256'];
    if (sha is! String || !sha256Pattern.hasMatch(sha)) {
      _fail('tool/windows_dependencies.json has invalid sha256 for $name');
    }
    return section;
  }

  final mpv = requireSection('mpv');
  final ffmpeg = requireSection('ffmpeg');
  requireSection('sqlite');
  requireSection('inno');

  final nativeArchives = dependencies['nativeArchives'];
  if (nativeArchives is! List || nativeArchives.isEmpty) {
    _fail('tool/windows_dependencies.json is missing nativeArchives entries.');
  }
  for (final entry in nativeArchives) {
    if (entry is! Map<String, dynamic>) {
      _fail('tool/windows_dependencies.json contains invalid nativeArchives item.');
    }
    final name = entry['name'];
    final sha = entry['sha256'];
    if (name is! String || name.isEmpty) {
      _fail('tool/windows_dependencies.json nativeArchives entry missing name.');
    }
    if (sha is! String || !sha256Pattern.hasMatch(sha)) {
      _fail('tool/windows_dependencies.json has invalid sha256 for $name');
    }
  }

  final mpvVersion = mpv['version'] as String?;
  final mpvUrl = mpv['url'] as String?;
  final ffmpegVersion = ffmpeg['version'] as String?;
  if (mpvVersion == null ||
      mpvVersion.isEmpty ||
      mpvUrl == null ||
      mpvUrl.isEmpty ||
      ffmpegVersion == null ||
      ffmpegVersion.isEmpty) {
    _fail('tool/windows_dependencies.json is missing mpv or ffmpeg version/url.');
  }

  final mpvArchiveName = Uri.parse(mpvUrl).pathSegments.last;
  for (final expected in <String>[
    'libmpv Windows runtime $mpvVersion:',
    mpvArchiveName,
    'FFmpeg $ffmpegVersion essentials:',
    'ffmpeg-$ffmpegVersion.tar.xz',
  ]) {
    if (!thirdParty.contains(expected)) {
      _fail(
        'tool/windows_third_party.txt does not match tool/windows_dependencies.json '
        '(missing: $expected).',
      );
    }
  }

  final subtitleScript = File(
    'tool/build_subtitle_native.dart',
  ).readAsStringSync();

  String requireScriptConst(String name, String valuePattern) {
    final match = RegExp(
      "const\\s+$name\\s*=\\s*'($valuePattern)'\\s*;",
    ).firstMatch(subtitleScript);
    if (match == null) {
      _fail('tool/build_subtitle_native.dart is missing constant $name.');
    }
    return match.group(1)!;
  }

  final crispAsrTag = requireScriptConst('_sourceTag', r"[^']+");
  final crispAsrCommit = requireScriptConst('_sourceCommit', r'[0-9a-f]{40}');
  final ggmlCommit = requireScriptConst('_ggmlCommit', r'[0-9a-f]{40}');
  final c2paCommit = requireScriptConst('_c2paCommit', r'[0-9a-f]{40}');

  for (final expected in <String>[
    'CrispASR $crispAsrTag (source commit $crispAsrCommit)',
    'ggml (source commit $ggmlCommit)',
    'CrispASR c2pa-audio (source commit $c2paCommit)',
  ]) {
    if (!thirdParty.contains(expected)) {
      _fail(
        'tool/windows_third_party.txt does not match tool/build_subtitle_native.dart '
        '(missing: $expected).',
      );
    }
  }
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
