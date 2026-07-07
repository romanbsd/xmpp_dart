import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/stream_management.dart';
import 'package:xmpp_dart/src/transport.dart';
import 'package:xmpp_dart/src/xml.dart';
import 'package:xmpp_dart/xmpp_dart.dart' show XmppClient;

import 'support/fake_transport.dart';

const _sm = StreamManagement.ns;
const _header = "<stream:stream xmlns='jabber:client' "
    "xmlns:stream='http://etherx.jabber.org/streams' id='s1'>";

String _features(String inner) =>
    '$_header<stream:features>$inner</stream:features>';

const _plain = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
    '<mechanism>PLAIN</mechanism></mechanisms>';

const _bindResult = "<iq type='result' id='bind'>"
    "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
    '<jid>alice@ex/res</jid></bind></iq>';

void main() {
  test('auto-reconnect resumes the SM session and replays queued stanzas',
      () async {
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
      streamManagement: true,
      autoReconnect: true,
      transportFactory: factory,
    );

    // --- initial login + SM enable ---
    final fut = client.connect();
    await pump();
    final t1 = transports[0];
    t1.deliver(_features(_plain));
    await pump();
    t1.deliver('<success/>');
    await pump();
    t1.deliver(_features("<sm xmlns='$_sm'/>"));
    await pump();
    t1.deliver(_bindResult);
    await pump();
    t1.deliver("<enabled xmlns='$_sm' id='sess1' resume='true'/>");
    await fut;
    await pump();

    // Send a stanza; it goes on the unacked queue.
    await client.send(xml('message', attrs: {'id': 'm1'}));
    await pump();

    // --- connection drops ---
    t1.drop();
    await pump();

    // A second transport is created for the reconnect.
    expect(transports.length, 2);
    final t2 = transports[1];

    // Re-auth, then resume instead of bind.
    t2.deliver(_features(_plain));
    await pump();
    t2.deliver('<success/>');
    await pump();
    t2.deliver(_features(''));
    await pump();
    expect(t2.writes.any((w) => w.contains('<resume') && w.contains('sess1')),
        isTrue);

    // Server had received 0 of our stanzas -> we resend m1.
    t2.deliver("<resumed xmlns='$_sm' h='0'/>");
    await pump();

    expect(client.jid.toString(), 'alice@ex/res');
    expect(t2.writes.any((w) => w.contains('<bind')), isFalse);
    expect(t2.writes.any((w) => w.contains('id="m1"')), isTrue);

    await client.close();
  });

  test('does not reconnect after an explicit close', () async {
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
      streamManagement: true,
      autoReconnect: true,
      transportFactory: factory,
    );

    final fut = client.connect();
    await pump();
    final t1 = transports[0];
    t1.deliver(_features(_plain));
    await pump();
    t1.deliver('<success/>');
    await pump();
    t1.deliver(_features("<sm xmlns='$_sm'/>"));
    await pump();
    t1.deliver(_bindResult);
    await pump();
    t1.deliver("<enabled xmlns='$_sm' id='sess1' resume='true'/>");
    await fut;
    await pump();

    await client.close();
    await pump();

    expect(transports.length, 1); // no reconnect attempted
  });
}
