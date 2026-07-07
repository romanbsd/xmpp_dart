import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A candidate XMPP endpoint discovered via DNS SRV (or a fallback).
class XmppEndpoint {
  final String host;
  final int port;

  /// True for `_xmpps-client` records (XEP-0368 direct TLS); false for
  /// `_xmpp-client` (plaintext + STARTTLS).
  final bool directTls;
  final int priority;
  final int weight;

  const XmppEndpoint(
    this.host,
    this.port, {
    required this.directTls,
    this.priority = 0,
    this.weight = 0,
  });

  @override
  String toString() =>
      '${directTls ? 'xmpps' : 'xmpp'}://$host:$port (p$priority w$weight)';
}

/// Resolves an XMPP domain to an ordered list of connection candidates.
/// Injectable so tests (and alternate strategies like DNS-over-HTTPS) can
/// replace the default UDP resolver.
abstract class SrvResolver {
  /// Ordered candidates for [domain]. Empty means the caller should fall back
  /// to the domain itself on the default port.
  Future<List<XmppEndpoint>> lookup(String domain);
}

/// One parsed SRV resource record.
class SrvRecord {
  final int priority;
  final int weight;
  final int port;
  final String target;
  const SrvRecord(this.priority, this.weight, this.port, this.target);
}

const _typeSrv = 33;
const _classIn = 1;

/// Encodes a DNS query for [name] of [qtype]. Exposed for testing.
Uint8List buildDnsQuery(int id, String name, {int qtype = _typeSrv}) {
  final b = BytesBuilder();
  void u16(int v) => b.add([(v >> 8) & 0xff, v & 0xff]);
  u16(id);
  u16(0x0100); // recursion desired
  u16(1); // qdcount
  u16(0); // ancount
  u16(0); // nscount
  u16(0); // arcount
  for (final label in name.split('.').where((l) => l.isNotEmpty)) {
    final bytes = label.codeUnits;
    if (bytes.length > 63) throw FormatException('DNS label too long: $label');
    b.addByte(bytes.length);
    b.add(bytes);
  }
  b.addByte(0); // root
  u16(qtype);
  u16(_classIn);
  return b.toBytes();
}

/// Parses the SRV records from a DNS response message. Exposed for testing.
/// Ignores non-SRV answers and `.` (root) targets, which signal "no service".
List<SrvRecord> parseSrvResponse(Uint8List msg) {
  if (msg.length < 12) throw const FormatException('DNS response too short');
  int u16(int o) => (msg[o] << 8) | msg[o + 1];

  final qd = u16(4);
  final an = u16(6);

  var pos = 12;
  for (var i = 0; i < qd; i++) {
    pos = _skipName(msg, pos);
    pos += 4; // qtype + qclass
  }

  final records = <SrvRecord>[];
  for (var i = 0; i < an; i++) {
    pos = _skipName(msg, pos);
    final type = u16(pos);
    final rdlength = u16(pos + 8);
    final rdata = pos + 10;
    if (type == _typeSrv && rdlength >= 6) {
      final priority = u16(rdata);
      final weight = u16(rdata + 2);
      final port = u16(rdata + 4);
      final (target, _) = _readName(msg, rdata + 6);
      if (target.isNotEmpty) {
        records.add(SrvRecord(priority, weight, port, target));
      }
    }
    pos = rdata + rdlength;
  }
  return records;
}

/// SRV ordering: lowest priority first, then highest weight first.
int compareSrv(SrvRecord a, SrvRecord b) {
  if (a.priority != b.priority) return a.priority - b.priority;
  return b.weight - a.weight;
}

/// Reads a (possibly compressed) DNS name at [offset]; returns the decoded name
/// and the offset immediately after it in the sequential stream.
(String, int) _readName(Uint8List b, int offset) {
  final labels = <String>[];
  int? afterPointer;
  var pos = offset;
  var safety = 0;
  while (true) {
    if (safety++ > 255) throw const FormatException('DNS name loop');
    final len = b[pos];
    if (len == 0) {
      pos++;
      break;
    }
    if ((len & 0xc0) == 0xc0) {
      final ptr = ((len & 0x3f) << 8) | b[pos + 1];
      afterPointer ??= pos + 2;
      pos = ptr;
      continue;
    }
    pos++;
    labels.add(String.fromCharCodes(b.sublist(pos, pos + len)));
    pos += len;
  }
  return (labels.join('.'), afterPointer ?? pos);
}

int _skipName(Uint8List b, int offset) => _readName(b, offset).$2;

/// Default resolver: sends UDP SRV queries to a system nameserver.
///
/// Queries `_xmpps-client._tcp.<domain>` (direct TLS) and
/// `_xmpp-client._tcp.<domain>` (STARTTLS), then orders by SRV priority/weight.
class DnsSrvResolver implements SrvResolver {
  final String nameserver;
  final Duration timeout;

  DnsSrvResolver({String? nameserver, this.timeout = const Duration(seconds: 5)})
      : nameserver = nameserver ?? _systemNameserver();

  @override
  Future<List<XmppEndpoint>> lookup(String domain) async {
    final services = <(String, bool)>[
      ('xmpps-client', true),
      ('xmpp-client', false),
    ];

    final endpoints = <(SrvRecord, bool)>[];
    for (final (service, directTls) in services) {
      final records = await _querySrv('_$service._tcp.$domain');
      for (final r in records) {
        endpoints.add((r, directTls));
      }
    }

    endpoints.sort((a, b) => compareSrv(a.$1, b.$1));
    return [
      for (final (r, directTls) in endpoints)
        XmppEndpoint(r.target, r.port,
            directTls: directTls, priority: r.priority, weight: r.weight),
    ];
  }

  Future<List<SrvRecord>> _querySrv(String qname) async {
    final id = Random().nextInt(0xffff);
    final query = buildDnsQuery(id, qname);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final resolver = InternetAddress(nameserver);
      socket.send(query, resolver, 53);

      final completer = Completer<Uint8List>();
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket!.receive();
          if (dg != null && !completer.isCompleted) completer.complete(dg.data);
        }
      });
      try {
        final data = await completer.future.timeout(timeout);
        return parseSrvResponse(data);
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      // DNS failure / timeout / NXDOMAIN: treat as "no records" so the caller
      // can fall back to the origin domain.
      return const [];
    } finally {
      socket?.close();
    }
  }

  static String _systemNameserver() {
    try {
      final resolv = File('/etc/resolv.conf');
      if (resolv.existsSync()) {
        for (final line in resolv.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.startsWith('nameserver')) {
            final parts = trimmed.split(RegExp(r'\s+'));
            if (parts.length >= 2) return parts[1];
          }
        }
      }
    } catch (_) {}
    return '8.8.8.8'; // last-resort public resolver
  }
}
