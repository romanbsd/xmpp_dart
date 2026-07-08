import 'package:test/test.dart';
import 'package:xmpp_dart/src/srv.dart';
import 'package:xmpp_dart/src/transport.dart';
import 'package:xmpp_dart/xmpp_dart.dart' show SaslException, XmppClient;

import 'support/fake_transport.dart';

const _header =
    "<stream:stream xmlns='jabber:client' "
    "xmlns:stream='http://etherx.jabber.org/streams' id='s1'>";
String _features(String inner) => '$_header<stream:features>$inner</stream:features>';
const _plain =
    "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
    '<mechanism>PLAIN</mechanism></mechanisms>';
const _tlsFeature = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>";
const _success = "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>";
const _bindResult =
    "<iq type='result' id='bind'>"
    "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
    '<jid>alice@ex/res</jid></bind></iq>';

class _FakeResolver implements SrvResolver {
  final List<XmppEndpoint> endpoints;
  _FakeResolver(this.endpoints);
  @override
  Future<List<XmppEndpoint>> lookup(String domain) async => endpoints;
}

class SocketFailure implements Exception {
  const SocketFailure();
}

/// Drives login to online. Set [starttls] for the STARTTLS negotiation dance;
/// direct-TLS endpoints skip it.
Future<void> _driveLogin(FakeTransport t, {bool starttls = false}) async {
  await pump();
  if (starttls) {
    t.deliver(_features(_tlsFeature));
    await pump();
    t.deliver("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
    await pump();
  }
  t.deliver(_features(_plain));
  await pump();
  t.deliver(_success);
  await pump();
  t.deliver(_features(''));
  await pump();
  t.deliver(_bindResult);
}

void main() {
  test('connects to the first resolved SRV endpoint', () async {
    final dialed = <(String, int, bool)>[];
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      dialed.add((host, port, secure));
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      transportFactory: factory,
      resolver: _FakeResolver([
        const XmppEndpoint('a.ex', 5223, directTls: true, priority: 1),
        const XmppEndpoint('b.ex', 5223, directTls: true, priority: 2),
      ]),
    );

    final fut = client.connect();
    await pump(8);
    await _driveLogin(transports[0]);
    await fut;

    // First candidate dialed, with direct TLS (secure: true).
    expect(dialed.first, ('a.ex', 5223, true));
    expect(client.jid.toString(), 'alice@ex/res');
    await client.close();
  });

  test('falls through to the next candidate when one refuses', () async {
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      if (host == 'dead.ex') throw const SocketFailure();
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      transportFactory: factory,
      resolver: _FakeResolver([
        const XmppEndpoint('dead.ex', 5223, directTls: true, priority: 1),
        const XmppEndpoint('live.ex', 5223, directTls: true, priority: 2),
      ]),
    );

    final fut = client.connect();
    await pump(8);
    await _driveLogin(transports.single); // only the live endpoint dialed
    await fut;
    expect(client.jid.toString(), 'alice@ex/res');
    await client.close();
  });

  test('permanent failure on a candidate is not retried on the next', () async {
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      transportFactory: factory,
      resolver: _FakeResolver([
        const XmppEndpoint('a.ex', 5223, directTls: true, priority: 1),
        const XmppEndpoint('b.ex', 5223, directTls: true, priority: 2),
      ]),
    );

    final result = expectLater(client.connect(), throwsA(isA<SaslException>()));
    await pump(8);
    transports[0].deliver(_features(_plain));
    await pump();
    transports[0].deliver(
      "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
      '<not-authorized/></failure>',
    );
    await result;

    // Auth failure is permanent -> the second candidate is never dialed.
    expect(transports.length, 1);
    await client.close();
  });

  test('falls back to domain:5222 STARTTLS when SRV yields nothing', () async {
    final dialed = <(String, int, bool)>[];
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      dialed.add((host, port, secure));
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      transportFactory: factory,
      resolver: _FakeResolver(const []),
    );

    final fut = client.connect();
    await pump(8);
    expect(dialed.single, ('ex', 5222, false)); // plaintext socket for STARTTLS
    await _driveLogin(transports.single, starttls: true);
    await fut;
    expect(client.jid.toString(), 'alice@ex/res');
    await client.close();
  });
}
