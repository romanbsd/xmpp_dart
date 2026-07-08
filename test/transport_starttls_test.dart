import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xmpp_dart/src/transport.dart';

/// Exercises [TcpTransport.upgradeTls] against a minimal STARTTLS-like server.
///
/// Regression for a Dart `dart:io` quirk: [SecureSocket.secure] fails with
/// "Connection terminated during handshake" when the plaintext socket's
/// subscription was canceled before the upgrade call.
void main() {
  late SecurityContext serverContext;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('xmpp_dart_starttls_');
    final cert = File('${tempDir.path}/cert.pem');
    final key = File('${tempDir.path}/key.pem');
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      key.path,
      '-out',
      cert.path,
      '-days',
      '1',
      '-nodes',
      '-subj',
      '/CN=localhost',
    ]);
    expect(result.exitCode, 0, reason: 'openssl must be available to generate test certs');

    serverContext = SecurityContext()
      ..useCertificateChain(cert.path)
      ..usePrivateKey(key.path);
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  test('upgradeTls completes while incoming listener is active', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    final serverHandshake = Completer<void>();
    server.listen((client) async {
      client.write("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
      await client.flush();
      final secure = await SecureSocket.secureServer(client, serverContext);
      serverHandshake.complete();
      await secure.close();
    });

    final transport = await TcpTransport.connect('127.0.0.1', server.port, onBadCertificate: (_) => true);

    final proceedSeen = Completer<void>();
    transport.incoming.transform(utf8.decoder).listen((chunk) {
      if (!proceedSeen.isCompleted && chunk.contains('proceed')) {
        proceedSeen.complete();
      }
    });

    await proceedSeen.future.timeout(const Duration(seconds: 5));
    await transport.upgradeTls('localhost');
    await serverHandshake.future.timeout(const Duration(seconds: 5));

    expect(transport.incoming, isNotNull);
    await transport.close();
  });
}
