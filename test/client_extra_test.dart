import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/transport.dart';
import 'package:xmpp_dart/src/xml.dart';
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

void main() {
  test('send/iq before connect error with StateError', () async {
    final client = XmppClient(
      host: 'ex',
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
    );
    await expectLater(
        client.send(xml('presence')), throwsA(isA<StateError>()));
    await expectLater(
        client.iq(xml('iq', attrs: {'type': 'get'})),
        throwsA(isA<StateError>()));
  });

  test('handler registered after connect answers inbound IQ', () async {
    final transports = <FakeTransport>[];
    Future<Transport> factory(String host, int port, {bool secure = false}) async {
      final t = FakeTransport();
      transports.add(t);
      return t;
    }

    final client = XmppClient(
      host: 'ex',
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
      transportFactory: factory,
    );

    final fut = client.connect();
    await pump();
    final t = transports[0];
    t.deliver(_features(_plain));
    await pump();
    t.deliver(_success);
    await pump();
    t.deliver(_features(''));
    await pump();
    t.deliver(_bindResult);
    await fut;

    // Register against the already-live responder.
    client.onIqGet('urn:example', 'q', (iq, child) =>
        xml('q', attrs: {'xmlns': 'urn:example'}, text: 'pong'));

    t.deliver("<iq type='get' from='srv' id='e1'>"
        "<q xmlns='urn:example'/></iq>");
    await pump();
    expect(
        t.writes.any((w) => w.contains('type="result"') && w.contains('id="e1"')),
        isTrue);

    await client.close();
  });
}
