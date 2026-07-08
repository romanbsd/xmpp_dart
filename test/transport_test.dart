import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xmpp_dart/src/transport.dart';

void main() {
  test('TcpTransport connects, writes, receives, and closes', () async {
    // Loopback echo server.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((sock) {
      sock.listen(sock.add); // echo bytes back
    });
    addTearDown(server.close);

    final t = await TcpTransport.connect('127.0.0.1', server.port);
    final received = StringBuffer();
    t.incoming.transform(utf8.decoder).listen(received.write);

    t.write('hello');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received.toString(), 'hello');

    await t.close();
    await t.done; // completes without hanging
  });

  test('TcpTransport.done completes when the peer closes', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((sock) => sock.destroy()); // drop immediately
    addTearDown(server.close);

    final t = await TcpTransport.connect('127.0.0.1', server.port);
    t.incoming.listen((_) {}); // drain so the socket isn't paused
    await t.done.timeout(const Duration(seconds: 2));
    await t.close();
  });
}
