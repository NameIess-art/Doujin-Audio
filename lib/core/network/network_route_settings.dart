import 'dart:convert';
import 'dart:io';

enum AppProxyMode { system, http, socks5 }

/// A committed application route. Credentials are kept outside preferences.
class NetworkRouteSettings {
  const NetworkRouteSettings({
    this.proxyMode = AppProxyMode.system,
    this.proxyHost = '',
    this.proxyPort = 0,
    this.proxyAuthenticationEnabled = false,
    this.proxyUsername = '',
    this.proxyPasswordConfigured = false,
    this.customDnsServer = '',
  });

  final AppProxyMode proxyMode;
  final String proxyHost;
  final int proxyPort;
  final bool proxyAuthenticationEnabled;
  final String proxyUsername;
  final bool proxyPasswordConfigured;
  final String customDnsServer;

  static String? normalizeHost(String value) {
    final host = value.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    if (host.isEmpty || host.contains(RegExp(r'\s|://|/|[?#@]'))) {
      return null;
    }
    if (host.contains(':') && InternetAddress.tryParse(host) == null) {
      return null;
    }
    return host;
  }

  static String? normalizeDns(String value) {
    final host = value.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    if (host.contains('%')) return null;
    return InternetAddress.tryParse(host)?.address;
  }

  void validate({bool requireCredentials = true}) {
    if (proxyMode != AppProxyMode.system &&
        (normalizeHost(proxyHost) == null ||
            proxyPort < 1 ||
            proxyPort > 65535)) {
      throw const FormatException('Invalid proxy host or port');
    }
    if (requireCredentials &&
        proxyMode != AppProxyMode.system &&
        proxyAuthenticationEnabled &&
        (proxyUsername.trim().isEmpty || !proxyPasswordConfigured)) {
      throw const FormatException('Proxy credentials are required');
    }
    if (proxyMode == AppProxyMode.socks5 &&
        proxyAuthenticationEnabled &&
        utf8.encode(proxyUsername).length > 255) {
      throw const FormatException('SOCKS5 username exceeds 255 UTF-8 bytes');
    }
    if (customDnsServer.isNotEmpty && normalizeDns(customDnsServer) == null) {
      throw const FormatException('DNS must be an IPv4 or IPv6 address');
    }
  }

  NetworkRouteSettings copyWith({
    AppProxyMode? proxyMode,
    String? proxyHost,
    int? proxyPort,
    bool? proxyAuthenticationEnabled,
    String? proxyUsername,
    bool? proxyPasswordConfigured,
    String? customDnsServer,
  }) => NetworkRouteSettings(
    proxyMode: proxyMode ?? this.proxyMode,
    proxyHost: proxyHost ?? this.proxyHost,
    proxyPort: proxyPort ?? this.proxyPort,
    proxyAuthenticationEnabled:
        proxyAuthenticationEnabled ?? this.proxyAuthenticationEnabled,
    proxyUsername: proxyUsername ?? this.proxyUsername,
    proxyPasswordConfigured:
        proxyPasswordConfigured ?? this.proxyPasswordConfigured,
    customDnsServer: customDnsServer ?? this.customDnsServer,
  );

  Map<String, Object?> toJson() => {
    'proxyMode': proxyMode.name,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyAuthenticationEnabled': proxyAuthenticationEnabled,
    'proxyUsername': proxyUsername,
    'proxyPasswordConfigured': proxyPasswordConfigured,
    'customDnsServer': customDnsServer,
  };

  factory NetworkRouteSettings.fromJson(Object? value) {
    if (value is! Map) return const NetworkRouteSettings();
    return NetworkRouteSettings(
      proxyMode:
          AppProxyMode.values
              .where((mode) => mode.name == value['proxyMode'])
              .firstOrNull ??
          AppProxyMode.system,
      proxyHost: value['proxyHost'] as String? ?? '',
      proxyPort: (value['proxyPort'] as num?)?.toInt() ?? 0,
      proxyAuthenticationEnabled:
          value['proxyAuthenticationEnabled'] as bool? ?? false,
      proxyUsername: value['proxyUsername'] as String? ?? '',
      proxyPasswordConfigured:
          value['proxyPasswordConfigured'] as bool? ?? false,
      customDnsServer: value['customDnsServer'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkRouteSettings &&
      proxyMode == other.proxyMode &&
      proxyHost == other.proxyHost &&
      proxyPort == other.proxyPort &&
      proxyAuthenticationEnabled == other.proxyAuthenticationEnabled &&
      proxyUsername == other.proxyUsername &&
      proxyPasswordConfigured == other.proxyPasswordConfigured &&
      customDnsServer == other.customDnsServer;

  @override
  int get hashCode => Object.hash(
    proxyMode,
    proxyHost,
    proxyPort,
    proxyAuthenticationEnabled,
    proxyUsername,
    proxyPasswordConfigured,
    customDnsServer,
  );
}
