import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmpp_dart/src/srv.dart';

/// A minimal loopback DNS server that answers every SRV query with one record
/// (target `srv.ex`, the given [port]), echoing the query id + question.
Future<RawDatagramSocket> _fakeDnsServer({int srvPort = 5222}) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  sock.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = sock.receive();
    if (dg == null) return;
    final query = dg.data; // header(12) + question
    final b = BytesBuilder();
    final resp = Uint8List.fromList(query);
    resp[2] = 0x81; // QR + RD
    resp[3] = 0x80; // RA
    resp[6] = 0x00;
    resp[7] = 0x01; // ancount = 1
    b.add(resp);
    // Answer: name -> question (0xC00C), type SRV, class IN, ttl, rdata.
    b.add([0xc0, 0x0c, 0x00, 33, 0x00, 1, 0x00, 0x00, 0x00, 0x3c]);
    final target = [3, ...'srv'.codeUnits, 2, ...'ex'.codeUnits, 0];
    final rdlen = 6 + target.length;
    b.add([(rdlen >> 8) & 0xff, rdlen & 0xff]);
    b.add([0x00, 0x05]); // priority 5
    b.add([0x00, 0x0a]); // weight 10
    b.add([(srvPort >> 8) & 0xff, srvPort & 0xff]);
    b.add(target);
    sock.send(b.toBytes(), dg.address, dg.port);
  });
  return sock;
}

void main() {
  test('DnsSrvResolver queries a nameserver and returns endpoints', () async {
    final dns = await _fakeDnsServer(srvPort: 5222);
    addTearDown(dns.close);

    final resolver = DnsSrvResolver(
      nameserver: '127.0.0.1',
      port: dns.port,
      timeout: const Duration(seconds: 2),
    );
    final endpoints = await resolver.lookup('example.com');

    // One record per service query (_xmpps-client + _xmpp-client).
    expect(endpoints, hasLength(2));
    expect(endpoints.every((e) => e.host == 'srv.ex'), isTrue);
    expect(endpoints.any((e) => e.directTls), isTrue); // xmpps-client
    expect(endpoints.any((e) => !e.directTls), isTrue); // xmpp-client
    expect(endpoints.first.port, 5222);
  });

  test('DnsSrvResolver returns empty when the nameserver is unreachable',
      () async {
    // Nothing listening on this port -> query times out -> [].
    final resolver = DnsSrvResolver(
      nameserver: '127.0.0.1',
      port: 1, // no DNS server here
      timeout: const Duration(milliseconds: 300),
    );
    expect(await resolver.lookup('example.com'), isEmpty);
  });
}
