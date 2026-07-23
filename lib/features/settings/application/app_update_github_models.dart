part of 'app_update_service.dart';

class _GitHubRelease {
  _GitHubRelease({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.publishedAt,
    required this.isDraft,
    required this.isPrerelease,
    required List<_GitHubAsset> assets,
  }) : assets = immutableList(assets);

  final String tagName;
  final String? name;
  final Uri htmlUrl;
  final DateTime? publishedAt;
  final bool isDraft;
  final bool isPrerelease;
  final List<_GitHubAsset> assets;

  static _GitHubRelease? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    if (!json.containsKey('tag_name') ||
        !json.containsKey('name') ||
        !json.containsKey('html_url') ||
        !json.containsKey('published_at') ||
        !json.containsKey('draft') ||
        !json.containsKey('prerelease') ||
        !json.containsKey('assets')) {
      return null;
    }

    final tagName = json['tag_name'];
    final name = json['name'];
    final htmlUrl = _parseGitHubWebUri(json['html_url']);
    final publishedAtValue = json['published_at'];
    final draft = json['draft'];
    final prerelease = json['prerelease'];
    final assetsValue = json['assets'];
    if (tagName is! String ||
        tagName.trim().isEmpty ||
        (name != null && name is! String) ||
        htmlUrl == null ||
        (publishedAtValue != null && publishedAtValue is! String) ||
        draft is! bool ||
        prerelease is! bool ||
        assetsValue is! List) {
      return null;
    }
    final publishedAt = publishedAtValue == null
        ? null
        : DateTime.tryParse(publishedAtValue as String);
    if (publishedAtValue != null && publishedAt == null) return null;

    return _GitHubRelease(
      tagName: tagName.trim(),
      name: name as String?,
      htmlUrl: htmlUrl,
      publishedAt: publishedAt,
      isDraft: draft,
      isPrerelease: prerelease,
      assets: assetsValue
          .map(_GitHubAsset.fromJson)
          .whereType<_GitHubAsset>()
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tag_name': tagName,
    'name': name,
    'html_url': htmlUrl.toString(),
    'published_at': publishedAt?.toIso8601String(),
    'draft': isDraft,
    'prerelease': isPrerelease,
    'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
  };
}

class _GitHubAsset {
  const _GitHubAsset({required this.name, required this.browserDownloadUrl});

  final String name;
  final Uri browserDownloadUrl;

  static _GitHubAsset? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    if (!json.containsKey('name') ||
        !json.containsKey('browser_download_url')) {
      return null;
    }
    final name = json['name'];
    final browserDownloadUrl = _parseGitHubWebUri(json['browser_download_url']);
    if (name is! String || name.trim().isEmpty || browserDownloadUrl == null) {
      return null;
    }
    return _GitHubAsset(
      name: name.trim(),
      browserDownloadUrl: browserDownloadUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'browser_download_url': browserDownloadUrl.toString(),
  };
}

Uri? _parseGitHubWebUri(Object? value) {
  if (value is! String || value.isEmpty || value.trim() != value) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  return uri;
}
