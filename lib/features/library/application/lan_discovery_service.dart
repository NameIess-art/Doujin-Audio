import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/remote_media_source.dart';

const String _discoveryProbePayload = 'DOUJIN_AUDIO_LAN_DISCOVER_V1';
const String _discoveryReplyMagic = 'DOUJIN_AUDIO_LAN_SERVER_V1';

class LanDiscoveryResponder {
  LanDiscoveryResponder({
    required this.serverInfoBuilder,
    this.discoveryPort = LanServerSettings.defaultDiscoveryPort,
  });

  final Map<String, Object?> Function() serverInfoBuilder;
  final int discoveryPort;
  RawDatagramSocket? _socket;

  bool get isRunning => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
    );
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final text = utf8.decode(datagram.data, allowMalformed: true).trim();
      if (text != _discoveryProbePayload) return;
      final reply = utf8.encode(
        jsonEncode(<String, Object?>{
          'magic': _discoveryReplyMagic,
          ...serverInfoBuilder(),
        }),
      );
      socket.send(reply, datagram.address, datagram.port);
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

abstract final class LanDiscoveryClient {
  static Future<List<LanDiscoveredServer>> discover({
    int discoveryPort = LanServerSettings.defaultDiscoveryPort,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    RawDatagramSocket? socket;
    final found = <String, LanDiscoveredServer>{};
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          final decoded = jsonDecode(
            utf8.decode(datagram.data, allowMalformed: true),
          );
          if (decoded is! Map || decoded['magic'] != _discoveryReplyMagic) {
            return;
          }
          final port = (decoded['port'] as num?)?.toInt() ?? 0;
          if (port < 1 || port > 65535) return;
          final serverId =
              decoded['serverId']?.toString() ??
              '${datagram.address.address}:$port';
          final key = '${datagram.address.address}:$port';
          found[key] = LanDiscoveredServer(
            serverId: serverId,
            name: decoded['name']?.toString().trim().isNotEmpty == true
                ? decoded['name']!.toString().trim()
                : datagram.address.address,
            host: datagram.address.address,
            port: port,
            authRequired: decoded['authRequired'] == true,
            allowSync: decoded['allowSync'] == true,
          );
        } on Object {
          // Ignore malformed third-party UDP packets on LAN.
        }
      });

      final probeBytes = utf8.encode(_discoveryProbePayload);
      final broadcastTargets = await _resolveBroadcastTargets();
      for (final target in broadcastTargets) {
        try {
          socket.send(probeBytes, target, discoveryPort);
        } on Object {
          // Best-effort broadcast per interface.
        }
      }
      await Future<void>.delayed(timeout);
    } on Object {
      // UDP socket bind may fail on restricted networks; caller still supports manual IP.
    } finally {
      socket?.close();
    }
    return found.values.toList(growable: false);
  }

  static bool isUsableLanIpv4Bytes(List<int> raw) {
    if (raw.length != 4) return false;
    final b0 = raw[0];
    final b1 = raw[1];
    // Exclude loopback (127.0.0.0/8), unspecified (0.0.0.0/8), link-local
    // (169.254.0.0/16), and RFC 2544 benchmark / TUN fake-IP (198.18.0.0/15).
    if (b0 == 0 || b0 == 127) return false;
    if (b0 == 169 && b1 == 254) return false;
    if (b0 == 198 && (b1 == 18 || b1 == 19)) return false;
    return true;
  }

  static int _lanIpv4Priority(List<int> raw) {
    if (raw.length != 4) return 99;
    final b0 = raw[0];
    final b1 = raw[1];
    if (b0 == 192 && b1 == 168) return 0;
    if (b0 == 10) return 1;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return 2;
    return 3;
  }

  static Future<List<InternetAddress>> _resolveBroadcastTargets() async {
    final targets = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
    };
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final raw = addr.rawAddress;
          if (!addr.isLoopback &&
              !addr.isLinkLocal &&
              isUsableLanIpv4Bytes(raw)) {
            final subnetBroadcast = '${raw[0]}.${raw[1]}.${raw[2]}.255';
            targets[subnetBroadcast] = InternetAddress(subnetBroadcast);
          }
        }
      }
    } on Object {
      // Fallback to 255.255.255.255.
    }
    return targets.values.toList(growable: false);
  }

  static Future<List<String>> listLocalLanIpv4Addresses() async {
    final candidates = <InternetAddress>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback &&
              !addr.isLinkLocal &&
              isUsableLanIpv4Bytes(addr.rawAddress)) {
            candidates.add(addr);
          }
        }
      }
    } on Object {
      // Return empty list if network enumeration is unavailable.
    }
    candidates.sort((a, b) {
      final p = _lanIpv4Priority(
        a.rawAddress,
      ).compareTo(_lanIpv4Priority(b.rawAddress));
      return p != 0 ? p : a.address.compareTo(b.address);
    });
    final seen = <String>{};
    return <String>[
      for (final addr in candidates)
        if (seen.add(addr.address)) addr.address,
    ];
  }
}
