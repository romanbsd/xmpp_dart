import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/errors.dart';
import 'package:xmpp_dart/src/jid.dart';
import 'package:xmpp_dart/src/stream_management.dart';
import 'package:xmpp_dart/src/xml.dart';

import 'support/fake_transport.dart';

const _tls = 'urn:ietf:params:xml:ns:xmpp-tls';
const _sasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
const _bind = 'urn:ietf:params:xml:ns:xmpp-bind';
const _sm = StreamManagement.ns;
const _stream = 'http://etherx.jabber.org/streams';

String _header(String declarations) =>
    "<stream:stream xmlns='jabber:client' xmlns:stream='$_stream' $declarations id='s'>";
String _features(String declarations, String body) =>
    '${_header(declarations)}<stream:features>$body</stream:features>';

/// Each encoding has the same expanded names, including when declarations live
/// on the never-closed stream rather than on the stanza being negotiated.
class _Encoding {
  final String name;
  const _Encoding(this.name);
  String get declarations =>
      name == 'inherited' ? "xmlns:t='$_tls' xmlns:s='$_sasl' xmlns:b='$_bind' xmlns:m='$_sm'" : '';
  String element(String prefix, String namespace, String local, {String attrs = '', String content = ''}) {
    final tag = name == 'default' ? local : '$prefix:$local';
    final declaration = switch (name) {
      'default' => " xmlns='$namespace'",
      'prefixed' => " xmlns:$prefix='$namespace'",
      _ => '',
    };
    return '<$tag$declaration $attrs>$content</$tag>';
  }

  String mechanisms() => element('s', _sasl, 'mechanisms', content: element('s', _sasl, 'mechanism', content: 'PLAIN'));
  String bindResult() =>
      "<iq type='result' id='bind'>${element('b', _bind, 'bind', content: element('b', _bind, 'jid', content: 'alice@ex/res'))}</iq>";
}

XmppConnection _connection(FakeTransport t, {StreamManagement? sm, TlsMode tls = TlsMode.starttls}) => XmppConnection(
  transport: t,
  domain: 'ex',
  username: 'alice',
  password: 'secret',
  tls: tls,
  sm: sm,
  ackInterval: null,
);

Future<void> _authenticate(FakeTransport t, _Encoding encoding) async {
  t.deliver(_features(encoding.declarations, encoding.mechanisms()));
  await pump();
  t.deliver(encoding.element('s', _sasl, 'success'));
  await pump();
}

void main() {
  for (final encoding in [const _Encoding('default'), const _Encoding('prefixed'), const _Encoding('inherited')]) {
    test('${encoding.name}: TLS feature/proceed, SASL and binding use expanded names', () async {
      final t = FakeTransport();
      final conn = _connection(t);
      addTearDown(conn.close);
      final connected = conn.connect();
      await pump();
      t.deliver(_features(encoding.declarations, encoding.element('t', _tls, 'starttls')));
      await pump();
      expect(t.writes.last, contains('<starttls'));
      t.deliver(encoding.element('t', _tls, 'proceed'));
      await pump();
      expect(t.tlsUpgraded, isTrue);
      await _authenticate(t, encoding);
      t.deliver(_features(encoding.declarations, ''));
      await pump();
      t.deliver(encoding.bindResult());
      expect((await connected).toString(), 'alice@ex/res');
    });

    test('${encoding.name}: SM enable, request and ack use expanded names', () async {
      final t = FakeTransport();
      final sm = StreamManagement();
      final conn = _connection(t, sm: sm, tls: TlsMode.none);
      addTearDown(() async {
        await conn.close();
        await sm.dispose();
      });
      final connected = conn.connect();
      await pump();
      await _authenticate(t, encoding);
      t.deliver(_features(encoding.declarations, encoding.element('m', _sm, 'sm')));
      await pump();
      t.deliver(encoding.bindResult());
      await pump();
      t.deliver(encoding.element('m', _sm, 'enabled', attrs: "id='session' resume='true'"));
      await connected;
      expect(sm.enabled, isTrue);
      await conn.send(xml('message', attrs: {'id': 'outbound'}));
      t.deliver(encoding.element('m', _sm, 'a', attrs: "h='1'"));
      await pump();
      expect(sm.outboundQueue, isEmpty);
      t.deliver(encoding.element('m', _sm, 'r'));
      await pump();
      expect(t.writes.last, contains('<a'));
      expect(t.writes.last, contains('h="0"'));
    });

    test('${encoding.name}: SM resumed preserves session', () async {
      final t = FakeTransport();
      final sm = StreamManagement()
        ..onEnabled(xml('enabled', attrs: {'id': 'session', 'resume': 'true'}))
        ..jid = Jid.parse('alice@ex/res')
        ..onDisconnect();
      final conn = _connection(t, sm: sm, tls: TlsMode.none);
      addTearDown(() async {
        await conn.close();
        await sm.dispose();
      });
      final connected = conn.connect();
      await pump();
      await _authenticate(t, encoding);
      t.deliver(_features(encoding.declarations, ''));
      await pump();
      expect(t.writes.last, contains('<resume'));
      t.deliver(encoding.element('m', _sm, 'resumed', attrs: "h='0' previd='session'"));
      expect((await connected).toString(), 'alice@ex/res');
      expect(t.writes.any((w) => w.contains('<bind')), isFalse);
    });
  }

  test('wrong TLS feature namespace is rejected without sending auth', () async {
    final t = FakeTransport();
    final conn = _connection(t);
    addTearDown(conn.close);
    final connected = conn.connect();
    final rejected = expectLater(connected, throwsA(isA<TlsException>()));
    await pump();
    t.deliver(_features('', "<t:starttls xmlns:t='urn:wrong'/>"));
    await rejected;
    expect(t.tlsUpgraded, isFalse);
    expect(t.writes.any((w) => w.contains('<auth')), isFalse);
  });

  test('wrong proceed namespace is rejected before TLS upgrade', () async {
    final t = FakeTransport();
    final conn = _connection(t);
    addTearDown(conn.close);
    final connected = conn.connect();
    final rejected = expectLater(connected, throwsA(isA<NegotiationException>()));
    await pump();
    t.deliver(_features('', "<starttls xmlns='$_tls'/>"));
    await pump();
    t.deliver("<t:proceed xmlns:t='urn:wrong'/>");
    await rejected;
    expect(t.tlsUpgraded, isFalse);
  });

  test('wrong SASL success namespace is rejected', () async {
    final t = FakeTransport();
    final conn = _connection(t, tls: TlsMode.none);
    addTearDown(conn.close);
    final connected = conn.connect();
    final rejected = expectLater(connected, throwsA(isA<NegotiationException>()));
    await pump();
    t.deliver(_features('', const _Encoding('default').mechanisms()));
    await pump();
    t.deliver("<s:success xmlns:s='urn:wrong'/>");
    await rejected;
  });

  test('wrong binding namespace is rejected', () async {
    final t = FakeTransport();
    final conn = _connection(t, tls: TlsMode.none);
    addTearDown(conn.close);
    final connected = conn.connect();
    final rejected = expectLater(connected, throwsA(isA<NegotiationException>()));
    await pump();
    await _authenticate(t, const _Encoding('default'));
    t.deliver(_features('', ''));
    await pump();
    t.deliver("<iq type='result' id='bind'><bind xmlns='urn:wrong'><jid>alice@ex/res</jid></bind></iq>");
    await rejected;
  });

  test('stream error prefix is arbitrary but namespace must match', () async {
    final t = FakeTransport();
    final conn = _connection(t, tls: TlsMode.none);
    addTearDown(conn.close);
    final connected = conn.connect();
    final rejected = expectLater(connected, throwsA(isA<StreamErrorException>()));
    await pump();
    t.deliver("${_header('')}<other:error xmlns:other='$_stream'><host-unknown/></other:error>");
    await rejected;
  });
  test('wrong SM namespace cannot acknowledge queued stanzas', () async {
    final t = FakeTransport();
    final sm = StreamManagement();
    final conn = _connection(t, sm: sm, tls: TlsMode.none);
    addTearDown(() async {
      await conn.close();
      await sm.dispose();
    });
    final connected = conn.connect();
    await pump();
    await _authenticate(t, const _Encoding('default'));
    t.deliver(_features('', "<sm xmlns='$_sm'/>"));
    await pump();
    t.deliver(const _Encoding('default').bindResult());
    await pump();
    t.deliver("<enabled xmlns='$_sm' id='s' resume='true'/>");
    await connected;
    await conn.send(xml('message', attrs: {'id': 'queued'}));
    t.deliver("<a xmlns='urn:wrong' h='1'/>");
    await pump();
    expect(sm.outboundQueue, hasLength(1));
    expect(sm.outbound, 0);
  });

  test('wrong stream-error namespace is routed as an extension after login', () async {
    final t = FakeTransport();
    final conn = _connection(t, tls: TlsMode.none);
    addTearDown(conn.close);
    final connected = conn.connect();
    await pump();
    await _authenticate(t, const _Encoding('default'));
    t.deliver(_features('', ''));
    await pump();
    t.deliver(const _Encoding('default').bindResult());
    await connected;
    final received = <String>[];
    final subscription = conn.stanzas.listen((el) => received.add(el.name.local));
    addTearDown(subscription.cancel);
    t.deliver("<stream:error xmlns:stream='urn:wrong'><whatever/></stream:error>");
    await pump();
    expect(conn.state, XmppState.online);
    expect(received, ['error']);
  });
}
