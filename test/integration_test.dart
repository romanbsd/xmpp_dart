@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:xmpp_dart/xmpp_dart.dart';

/// Real-server smoke test. Gated behind env vars so it's skipped by default:
///
///   XMPP_HOST=example.com XMPP_DOMAIN=example.com \
///   XMPP_USER=alice XMPP_PASS=secret \
///   dart test --tags integration
void main() {
  final env = Platform.environment;
  final host = env['XMPP_HOST'];
  final skip = host == null ? 'set XMPP_HOST/USER/PASS to run' : false;

  test('connects, authenticates and binds against a real server', () async {
    final client = XmppClient(
      host: host!,
      domain: env['XMPP_DOMAIN'] ?? host,
      username: env['XMPP_USER']!,
      password: env['XMPP_PASS']!,
    );
    await client.connect();
    expect(client.jid, isNotNull);
    await client.close();
  }, skip: skip);
}
