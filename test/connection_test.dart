import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/sasl.dart';

import 'support/fake_transport.dart';

const _streamHeader = "<stream:stream xmlns='jabber:client' "
    "xmlns:stream='http://etherx.jabber.org/streams' id='s1'>";

String _features(String inner) =>
    '$_streamHeader<stream:features>$inner</stream:features>';

const _plainMechs = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
    '<mechanism>PLAIN</mechanism></mechanisms>';

const _bindResult = "<iq type='result' id='bind'>"
    "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
    '<jid>alice@ex/res</jid></bind></iq>';

void main() {
  test('full happy path: features -> PLAIN -> restart -> bind -> online',
      () async {
    final t = FakeTransport();
    final conn = XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
    );
    final states = <XmppState>[];
    conn.states.listen(states.add);

    final fut = conn.connect();
    await pump();

    // Client opened the stream.
    expect(t.writes.first, contains('<stream:stream'));
    expect(t.writes.first, contains("to='ex'"));

    // Offer features; client authenticates with PLAIN.
    t.deliver(_features(_plainMechs));
    await pump();
    final auth = t.writes.firstWhere((w) => w.contains('<auth'));
    expect(auth, contains('mechanism="PLAIN"'));
    // base64('\0alice\0secret')
    expect(auth, contains('AGFsaWNlAHNlY3JldA=='));

    // Auth succeeds; client restarts the stream.
    t.deliver('<success/>');
    await pump();

    // New stream, no more SASL -> client binds a resource.
    t.deliver(_features(''));
    await pump();
    expect(t.writes.any((w) => w.contains('<bind')), isTrue);

    // Server assigns the full JID.
    t.deliver(_bindResult);
    final jid = await fut;
    await pump();

    expect(jid.toString(), 'alice@ex/res');
    expect(conn.state, XmppState.online);
    expect(
        states,
        containsAllInOrder([
          XmppState.connecting,
          XmppState.open,
          XmppState.authenticating,
          XmppState.bound,
          XmppState.online,
        ]));
  });

  test('STARTTLS: upgrades then continues to auth', () async {
    final t = FakeTransport();
    final conn = XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'secret',
    );
    final fut = conn.connect();
    await pump();

    t.deliver(_features(
        "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls>"));
    await pump();
    expect(t.writes.any((w) => w.contains('<starttls')), isTrue);

    t.deliver("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
    await pump();
    expect(t.tlsUpgraded, isTrue);

    // Post-TLS stream restart -> features with PLAIN -> auth -> bind.
    t.deliver(_features(_plainMechs));
    await pump();
    t.deliver('<success/>');
    await pump();
    t.deliver(_features(''));
    await pump();
    t.deliver(_bindResult);

    final jid = await fut;
    expect(jid.toString(), 'alice@ex/res');
  });

  test('SASL failure throws SaslException', () async {
    final t = FakeTransport();
    final conn = XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'bad',
      tls: TlsMode.none,
    );
    final fut = conn.connect();
    await pump();
    t.deliver(_features(_plainMechs));
    await pump();
    t.deliver("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
        '<not-authorized/></failure>');

    await expectLater(fut, throwsA(isA<SaslException>()));
  });

  test('stream error during negotiation throws StreamErrorException', () async {
    final t = FakeTransport();
    final conn = XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
    );
    final fut = conn.connect();
    await pump();
    t.deliver('$_streamHeader<stream:error><host-unknown/></stream:error>');

    await expectLater(fut, throwsA(isA<StreamErrorException>()));
  });

  test('routes stanzas after online', () async {
    final t = FakeTransport();
    final conn = XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
    );
    final stanzas = <String>[];
    conn.stanzas.listen((e) => stanzas.add(e.name.local));

    final fut = conn.connect();
    await pump();
    t.deliver(_features(_plainMechs));
    await pump();
    t.deliver('<success/>');
    await pump();
    t.deliver(_features(''));
    await pump();
    t.deliver(_bindResult);
    await fut;

    t.deliver("<message from='bob@ex'><body>hi</body></message>");
    await pump();
    expect(stanzas, contains('message'));

  });
}
