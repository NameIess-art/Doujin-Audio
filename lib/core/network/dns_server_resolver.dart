import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'network_socket.dart';

/// Unicast DNS for an explicitly selected server, never the OS fallback.
class DnsServerResolver {
  DnsServerResolver(
    this.server, {
    this.port = 53,
    this.timeout = const Duration(seconds: 3),
  });

  final InternetAddress server;
  final int port;
  final Duration timeout;
  final _random = Random.secure();

  Future<List<InternetAddress>> lookup(String hostname) async {
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) return [literal];
    final results = await Future.wait([
      _query(
        hostname,
        1,
        0,
      ).then<Object>((value) => value, onError: (Object e) => e),
      _query(
        hostname,
        28,
        0,
      ).then<Object>((value) => value, onError: (Object e) => e),
    ]);
    final addresses = <String, InternetAddress>{};
    for (final result in results) {
      if (result is List<InternetAddress>) {
        for (final address in result) {
          addresses[address.address] = address;
        }
      }
    }
    if (addresses.isNotEmpty) return addresses.values.toList(growable: false);
    throw SocketException('Custom DNS could not resolve host', address: server);
  }

  Future<List<InternetAddress>> _query(String host, int type, int depth) async {
    if (depth >= 8) throw const FormatException('DNS CNAME chain is too long');
    final name = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final labels = name.split('.');
    if (name.length > 253 ||
        labels.any(
          (label) =>
              label.isEmpty ||
              label.length > 63 ||
              !RegExp(r'^[a-z0-9_-]+$').hasMatch(label),
        )) {
      throw const FormatException('Invalid DNS hostname');
    }
    final id = _random.nextInt(65536);
    final query = Uint8List.fromList([
      id >> 8,
      id & 255,
      1,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      for (final label in labels) ...[label.length, ...label.codeUnits],
      0,
      0,
      type,
      0,
      1,
    ]);
    var response = await _udp(query, id);
    _validateHeader(response, id);
    if (_short(response, 2) & 0x0200 != 0) {
      response = await _tcp(query);
      _validateHeader(response, id);
    }
    final rcode = _short(response, 2) & 15;
    if (rcode == 3) return [];
    if (rcode != 0) throw const SocketException('DNS server returned an error');
    if (_short(response, 4) != 1) {
      throw const FormatException('Unexpected DNS question count');
    }
    final question = _name(response, 12);
    if (question.name.toLowerCase() != name ||
        _short(response, question.next) != type ||
        _short(response, question.next + 2) != 1) {
      throw const FormatException('DNS response question mismatch');
    }
    var offset = question.next + 4;
    final addresses = <({String owner, InternetAddress address})>[];
    final aliases = <String, String>{};
    for (var i = 0; i < _short(response, 6); i++) {
      final owner = _name(response, offset);
      offset = owner.next;
      _check(response, offset, 10);
      final recordType = _short(response, offset);
      final recordClass = _short(response, offset + 2);
      final length = _short(response, offset + 8);
      offset += 10;
      _check(response, offset, length);
      if (recordClass == 1) {
        if ((recordType == 1 && type == 1 && length == 4) ||
            (recordType == 28 && type == 28 && length == 16)) {
          addresses.add((
            owner: owner.name.toLowerCase(),
            address: InternetAddress.fromRawAddress(
              Uint8List.sublistView(response, offset, offset + length),
            ),
          ));
        } else if (recordType == 5) {
          aliases[owner.name.toLowerCase()] = _name(
            response,
            offset,
          ).name.toLowerCase();
        }
      }
      offset += length;
    }
    var canonical = name;
    final seen = <String>{};
    while (aliases.containsKey(canonical)) {
      if (!seen.add(canonical) || seen.length + depth >= 8) {
        throw const FormatException('DNS CNAME loop');
      }
      canonical = aliases[canonical]!;
    }
    final matched = addresses
        .where((entry) => entry.owner == canonical)
        .map((entry) => entry.address)
        .toList(growable: false);
    if (matched.isNotEmpty || canonical == name) return matched;
    return _query(canonical, type, depth + 1);
  }

  Future<Uint8List> _udp(Uint8List query, int id) async {
    final socket = await RawDatagramSocket.bind(
      server.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    final reply = Completer<Uint8List>();
    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final packet = datagram!;
          if (packet.address.address == server.address &&
              packet.port == port &&
              packet.data.length >= 12 &&
              _short(packet.data, 0) == id &&
              !reply.isCompleted) {
            reply.complete(packet.data);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!reply.isCompleted) reply.completeError(error, stack);
      },
    );
    try {
      if (socket.send(query, server, port) != query.length) {
        throw const SocketException('DNS query could not be sent');
      }
      return await reply.future.timeout(timeout);
    } finally {
      socket.close();
      await subscription.cancel();
    }
  }

  Future<Uint8List> _tcp(Uint8List query) async {
    final connection = NetworkSocket(
      await Socket.connect(server, port, timeout: timeout),
    );
    try {
      connection.socket.add([query.length >> 8, query.length & 255, ...query]);
      return await (() async {
        final prefix = await connection.readBytes(2);
        final length = prefix[0] * 256 + prefix[1];
        if (length < 12) throw const FormatException('Invalid DNS TCP frame');
        return Uint8List.fromList(await connection.readBytes(length));
      })().timeout(timeout);
    } finally {
      connection.destroy();
    }
  }

  static void _validateHeader(Uint8List data, int id) {
    _check(data, 0, 12);
    if (_short(data, 0) != id ||
        _short(data, 2) & 0x8000 == 0 ||
        _short(data, 2) & 0x7800 != 0) {
      throw const FormatException('Invalid DNS response header');
    }
  }

  static int _short(Uint8List data, int offset) {
    _check(data, offset, 2);
    return data[offset] * 256 + data[offset + 1];
  }

  static void _check(Uint8List data, int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > data.length) {
      throw const FormatException('Truncated DNS response');
    }
  }

  static ({String name, int next}) _name(Uint8List data, int offset) {
    var next = -1;
    var pointers = 0;
    final labels = <String>[];
    while (true) {
      _check(data, offset, 1);
      final length = data[offset];
      if (length == 0) {
        return (name: labels.join('.'), next: next < 0 ? offset + 1 : next);
      }
      if (length & 0xc0 == 0xc0) {
        _check(data, offset, 2);
        if (++pointers > 32) {
          throw const FormatException('DNS compression loop');
        }
        if (next < 0) next = offset + 2;
        offset = (length & 63) * 256 + data[offset + 1];
      } else {
        if (length > 63) throw const FormatException('Invalid DNS label');
        _check(data, offset + 1, length);
        labels.add(
          String.fromCharCodes(data.sublist(offset + 1, offset + 1 + length)),
        );
        offset += length + 1;
      }
    }
  }
}
