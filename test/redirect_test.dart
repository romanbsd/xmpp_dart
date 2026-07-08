import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/transport.dart';
import 'package:xmpp_dart/xmpp_dart.dart' show XmppClient;

import 'support/fake_transport.dart';

const _header = "<stream:stream xmlns='jabber:client' "
    "xmlns:stream='http://etherx.jabber.org/streams' id='s1'>";
String _features(String inner) =>
    '$_header<stream:features>$inner</stream:features>';
const _plain = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
    '<mechanism>PLAIN</mechanism></mechanisms>';
const _success = "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>";
const _bindResult = "<iq type='result' id='bind'>"
    "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
    '<jid>alice@ex/res</jid></bind></iq>';

String _seeOtherHost(String target) =>
    '$_header<stream:error>'
    "<see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
    '$target</see-other-host></stream:error>';

Future<void> _driveLogin(FakeTransport t) async {
  await pump();
  t.deliver(_features(_plain));
  await pump();
  t.deliver(_success);
  await pump();
  t.deliver(_features(''));
  await pump();
  t.deliver(_bindResult);
}

void main() {
  test('negotiation see-other-host redirects to the new host:port', () async {
    final dialed = <(String, int)>[];
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      dialed.add((host, port));
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      host: 'orig.ex',
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
      transportFactory: factory,
    );

    final fut = client.connect();
    await pump();
    // orig.ex tells us to go elsewhere before we get anywhere.
    transports[0].deliver(_seeOtherHost('new.ex:5269'));
    await pump(8);

    expect(dialed, [('orig.ex', 5222), ('new.ex', 5269)]);

    await _driveLogin(transports[1]);
    await fut;
    expect(client.jid.toString(), 'alice@ex/res');
    await client.close();
  });

  test('online see-other-host reconnects to the new (IPv6) host', () async {
    final dialed = <(String, int)>[];
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      dialed.add((host, port));
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      host: 'orig.ex',
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
      autoReconnect: true,
      reconnectBase: const Duration(milliseconds: 1),
      transportFactory: factory,
    );

    final fut = client.connect();
    await pump();
    await _driveLogin(transports[0]);
    await fut;
    await pump();

    // Online: server redirects (IPv6 target with explicit port).
    transports[0].deliver('<stream:error>'
        "<see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
        '[2001:db8::1]:5300</see-other-host></stream:error>');
    await pump(12);

    expect(dialed.length, 2);
    expect(dialed[1], ('2001:db8::1', 5300));

    await _driveLogin(transports[1]);
    await pump();
    await client.close();
  });
}
