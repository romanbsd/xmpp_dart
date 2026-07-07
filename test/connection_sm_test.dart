import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/jid.dart';
import 'package:xmpp_dart/src/stream_management.dart';
import 'package:xmpp_dart/src/xml.dart';

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

XmppConnection _conn(FakeTransport t, StreamManagement sm) => XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: TlsMode.none,
      sm: sm,
      ackInterval: null, // no periodic timer in tests
    );

/// Drives a fresh login through to online with SM enabled.
Future<void> _login(FakeTransport t, {bool smFeature = true}) async {
  await pump();
  t.deliver(_features(_plain));
  await pump();
  t.deliver('<success/>');
  await pump();
  t.deliver(_features(smFeature ? "<sm xmlns='$_sm'/>" : ''));
  await pump();
  t.deliver(_bindResult);
  await pump();
  if (smFeature) {
    t.deliver("<enabled xmlns='$_sm' id='sess1' resume='true' max='600'/>");
    await pump();
  }
}

void main() {
  test('enables SM after binding', () async {
    final t = FakeTransport();
    final sm = StreamManagement();
    final fut = _conn(t, sm).connect();
    await _login(t);
    final jid = await fut;
    await pump();

    expect(t.writes.any((w) => w.contains('<enable') && w.contains('resume="true"')),
        isTrue);
    expect(sm.enabled, isTrue);
    expect(sm.id, 'sess1');
    expect(sm.max, 600);
    expect(jid.toString(), 'alice@ex/res');
  });

  test('replies to <r/> with <a h=..>', () async {
    final t = FakeTransport();
    final sm = StreamManagement();
    final fut = _conn(t, sm).connect();
    await _login(t);
    await fut;

    t.deliver("<message from='bob@ex'><body>hi</body></message>");
    await pump();
    expect(sm.inbound, 1);

    t.deliver("<r xmlns='$_sm'/>");
    await pump();
    expect(t.writes.last, contains('<a'));
    expect(t.writes.last, contains('h="1"'));
  });

  test('acks outbound stanzas on <a h=..>', () async {
    final t = FakeTransport();
    final sm = StreamManagement();
    final conn = _conn(t, sm);
    final fut = conn.connect();
    await _login(t);
    await fut;

    final acked = <String?>[];
    sm.acks.listen((e) => acked.add(e.getAttribute('id')));

    await conn.send(xml('message', attrs: {'id': 'm1'}));
    expect(sm.outboundQueue, hasLength(1));
    // Sending a tracked stanza also emits an <r/> to prompt an ack.
    expect(t.writes.any((w) => w.contains('<r')), isTrue);

    t.deliver("<a xmlns='$_sm' h='1'/>");
    await pump();
    expect(acked, ['m1']);
    expect(sm.outbound, 1);
    expect(sm.outboundQueue, isEmpty);
  });

  test('resumes a previous session, skipping bind and resending queue',
      () async {
    // Simulate a prior enabled session with two unacked stanzas.
    final sm = StreamManagement()
      ..onEnabled(xml('enabled',
          attrs: {'xmlns': _sm, 'id': 'sess1', 'resume': 'true'}))
      ..jid = Jid.parse('alice@ex/res')
      ..trackOutbound(xml('message', attrs: {'id': 'a'}))
      ..trackOutbound(xml('message', attrs: {'id': 'b'}))
      ..onDisconnect();

    final t = FakeTransport();
    final fut = _conn(t, sm).connect();

    await pump();
    t.deliver(_features(_plain));
    await pump();
    t.deliver('<success/>');
    await pump();
    t.deliver(_features('')); // resumable -> client sends <resume>
    await pump();
    expect(t.writes.any((w) => w.contains('<resume') && w.contains('previd="sess1"')),
        isTrue);

    // Server received 'a' but not 'b'.
    t.deliver("<resumed xmlns='$_sm' h='1'/>");
    final jid = await fut;
    await pump();

    expect(jid.toString(), 'alice@ex/res'); // reused, not re-bound
    expect(t.writes.any((w) => w.contains('<bind')), isFalse);
    expect(sm.enabled, isTrue);
    expect(sm.outbound, 1);
    // 'b' was resent.
    expect(t.writes.any((w) => w.contains('id="b"')), isTrue);
  });

  test('falls back to bind when resume fails', () async {
    final sm = StreamManagement()
      ..onEnabled(xml('enabled',
          attrs: {'xmlns': _sm, 'id': 'sess1', 'resume': 'true'}))
      ..jid = Jid.parse('alice@ex/old')
      ..trackOutbound(xml('message', attrs: {'id': 'a'}))
      ..onDisconnect();

    final t = FakeTransport();
    final fut = _conn(t, sm).connect();

    await pump();
    t.deliver(_features(_plain));
    await pump();
    t.deliver('<success/>');
    await pump();
    t.deliver(_features(''));
    await pump();
    t.deliver("<failed xmlns='$_sm'/>");
    await pump();

    expect(t.writes.any((w) => w.contains('<bind')), isTrue);
    expect(sm.resumable, isFalse);

    t.deliver(_bindResult);
    final jid = await fut;
    expect(jid.toString(), 'alice@ex/res');
  });
}
