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
    this.cacheCapacity = 256,
    DateTime Function()? now,
  }) : assert(cacheCapacity > 0),
       _now = now ?? DateTime.now;

  final InternetAddress server;
  final int port;
  final Duration timeout;
  final int cacheCapacity;
  final _random = Random.secure();
  final DateTime Function() _now;
  final _cache =
      <(String, int), ({List<InternetAddress> addresses, DateTime expires})>{};
  final _pending = <(String, int), Future<List<InternetAddress>>>{};
  final _cancelQueries = <void Function()>{};
  bool _closed = false;

  Future<List<InternetAddress>> lookup(String hostname) =>
      lookupAddresses(hostname).toList();

  /// Publish either family immediately, while keeping the other available if
  /// connecting to the first address fails. Cancellation detaches immediately;
  /// shared queries finish within their bounded timeout (or [close]). An async*
  /// wrapper would make cancel wait for the unanswered family's next event.
  Stream<InternetAddress> lookupAddresses(String hostname) {
    StreamSubscription<List<InternetAddress>>? subscription;
    late StreamController<InternetAddress> output;
    output = StreamController<InternetAddress>(
      onListen: () {
        if (_closed) {
          output.addError(const SocketException('DNS resolver is closed'));
          unawaited(output.close());
          return;
        }
        final literal = InternetAddress.tryParse(hostname);
        if (literal != null) {
          output.add(literal);
          unawaited(output.close());
          return;
        }
        final name = hostname.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
        final seen = <String>{};
        subscription =
            Stream.fromFutures([
              for (final type in [1, 28])
                _lookupType(
                  name,
                  type,
                ).onError((Object _, StackTrace _) => <InternetAddress>[]),
            ]).listen(
              (addresses) {
                for (final address in addresses) {
                  if (seen.add(address.address)) output.add(address);
                }
              },
              onDone: () {
                if (seen.isEmpty) {
                  output.addError(
                    SocketException(
                      'Custom DNS could not resolve host',
                      address: server,
                    ),
                  );
                }
                unawaited(output.close());
              },
            );
      },
      onCancel: () => subscription?.cancel(),
    );
    return output.stream;
  }

  Future<List<InternetAddress>> _lookupType(String name, int type) {
    final key = (name, type);
    final cached = _cache.remove(key);
    if (cached != null && cached.expires.isAfter(_now())) {
      _cache[key] = cached;
      return Future.value(cached.addresses);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final answer = await _query(name, type, 0);
        if (!_closed && answer.addresses.isNotEmpty && answer.ttl > 0) {
          if (_cache.length >= cacheCapacity) _cache.remove(_cache.keys.first);
          _cache[key] = (
            addresses: answer.addresses,
            expires: _now().add(Duration(seconds: min(answer.ttl, 300))),
          );
        }
        return answer.addresses;
      } finally {
        unawaited(_pending.remove(key));
      }
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    for (final cancel in _cancelQueries.toList()) {
      cancel();
    }
  }

  Future<({List<InternetAddress> addresses, int ttl})> _query(
    String host,
    int type,
    int depth,
  ) async {
    if (_closed) throw const SocketException('DNS resolver is closed');
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
    if (rcode == 3) return (addresses: <InternetAddress>[], ttl: 0);
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
    final addresses = <({String owner, InternetAddress address, int ttl})>[];
    final aliases = <String, ({String target, int ttl})>{};
    for (var i = 0; i < _short(response, 6); i++) {
      final owner = _name(response, offset);
      offset = owner.next;
      _check(response, offset, 10);
      final recordType = _short(response, offset);
      final recordClass = _short(response, offset + 2);
      final ttl =
          _short(response, offset + 4) * 65536 + _short(response, offset + 6);
      final length = _short(response, offset + 8);
      offset += 10;
      _check(response, offset, length);
      if (recordClass == 1) {
        if ((recordType == 1 && type == 1 && length == 4) ||
            (recordType == 28 && type == 28 && length == 16)) {
          addresses.add((
            owner: owner.name.toLowerCase(),
            ttl: ttl,
            address: InternetAddress.fromRawAddress(
              Uint8List.sublistView(response, offset, offset + length),
            ),
          ));
        } else if (recordType == 5) {
          aliases[owner.name.toLowerCase()] = (
            target: _name(response, offset).name.toLowerCase(),
            ttl: ttl,
          );
        }
      }
      offset += length;
    }
    var canonical = name;
    var ttl = 300;
    final seen = <String>{};
    while (aliases.containsKey(canonical)) {
      if (!seen.add(canonical) || seen.length + depth >= 8) {
        throw const FormatException('DNS CNAME loop');
      }
      final alias = aliases[canonical]!;
      ttl = min(ttl, alias.ttl);
      canonical = alias.target;
    }
    final matched = addresses
        .where((entry) => entry.owner == canonical)
        .toList(growable: false);
    if (matched.isNotEmpty || canonical == name) {
      for (final entry in matched) {
        ttl = min(ttl, entry.ttl);
      }
      return (
        addresses: matched
            .map((entry) => entry.address)
            .toList(growable: false),
        ttl: ttl,
      );
    }
    final answer = await _query(canonical, type, depth + 1);
    return (addresses: answer.addresses, ttl: min(ttl, answer.ttl));
  }

  Future<Uint8List> _udp(Uint8List query, int id) async {
    final socket = await RawDatagramSocket.bind(
      server.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    final reply = Completer<Uint8List>();
    void cancel() {
      if (!reply.isCompleted) {
        reply.completeError(const SocketException('DNS resolver is closed'));
      }
      socket.close();
    }

    if (_closed) {
      socket.close();
      throw const SocketException('DNS resolver is closed');
    }
    _cancelQueries.add(cancel);
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
      _cancelQueries.remove(cancel);
      socket.close();
      await subscription.cancel();
    }
  }

  Future<Uint8List> _tcp(Uint8List query) async {
    final task = await Socket.startConnect(server, port);
    if (_closed) {
      task.cancel();
      // Cancellation completes task.socket with an error; always consume it.
      await task.socket.then<void>(
        (socket) => socket.destroy(),
        onError: (Object _) {},
      );
      throw const SocketException('DNS resolver is closed');
    }
    _cancelQueries.add(task.cancel);
    late Socket socket;
    try {
      socket = await task.socket.timeout(
        timeout,
        onTimeout: () {
          task.cancel();
          throw TimeoutException('DNS TCP connection timed out', timeout);
        },
      );
    } finally {
      _cancelQueries.remove(task.cancel);
    }
    final connection = NetworkSocket(socket);
    if (_closed) {
      connection.destroy();
      throw const SocketException('DNS resolver is closed');
    }
    _cancelQueries.add(connection.destroy);
    try {
      connection.socket.add([query.length >> 8, query.length & 255, ...query]);
      return await (() async {
        final prefix = await connection.readBytes(2);
        final length = prefix[0] * 256 + prefix[1];
        if (length < 12) throw const FormatException('Invalid DNS TCP frame');
        return Uint8List.fromList(await connection.readBytes(length));
      })().timeout(timeout);
    } finally {
      _cancelQueries.remove(connection.destroy);
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
