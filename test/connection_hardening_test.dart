import 'package:test/test.dart';
import 'package:xmpp_dart/src/connection.dart';
import 'package:xmpp_dart/src/errors.dart';

import 'support/fake_transport.dart';

const _header = "<stream:stream xmlns='jabber:client' "
    "xmlns:stream='http://etherx.jabber.org/streams' id='s1'>";

String _features(String inner) =>
    '$_header<stream:features>$inner</stream:features>';

const _plain = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
    '<mechanism>PLAIN</mechanism></mechanisms>';

const _tlsFeature = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>";
const _success = "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>";
const _bindResult = "<iq type='result' id='bind'>"
    "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
    '<jid>alice@ex/r</jid></bind></iq>';

XmppConnection _conn(FakeTransport t, TlsMode tls) => XmppConnection(
      transport: t,
      domain: 'ex',
      username: 'alice',
      password: 'secret',
      tls: tls,
      ackInterval: null,
    );

void main() {
  group('STARTTLS semantics', () {
    test('required but not offered -> TlsException, transport closed',
        () async {
      final t = FakeTransport();
      // Attach the matcher before driving so the negotiation error is handled.
      final result = expectLater(
          _conn(t, TlsMode.starttls).connect(), throwsA(isA<TlsException>()));
      await pump();
      t.deliver(_features(_plain)); // no <starttls>
      await result;
      expect(t.closed, isTrue); // deterministic teardown
    });

    test('opportunistic continues in plaintext when not offered', () async {
      final t = FakeTransport();
      final fut = _conn(t, TlsMode.opportunistic).connect();
      await pump();
      t.deliver(_features(_plain));
      await pump();
      expect(t.writes.any((w) => w.contains('<auth')), isTrue);

      t.deliver(_success);
      await pump();
      t.deliver(_features(''));
      await pump();
      t.deliver(_bindResult);
      expect((await fut).toString(), 'alice@ex/r');
    });

    test('handshake failure -> TlsException', () async {
      final t = FakeTransport()..tlsError = Exception('bad cert');
      final result = expectLater(
          _conn(t, TlsMode.starttls).connect(), throwsA(isA<TlsException>()));
      await pump();
      t.deliver(_features(_tlsFeature));
      await pump();
      t.deliver("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
      await result;
    });
  });

  group('namespace validation', () {
    test('SASL element in wrong namespace -> NegotiationException', () async {
      final t = FakeTransport();
      final result = expectLater(
          _conn(t, TlsMode.none).connect(),
          throwsA(isA<NegotiationException>()));
      await pump();
      t.deliver(_features(_plain));
      await pump();
      t.deliver('<success/>'); // missing SASL namespace
      await result;
    });

    test('mechanisms in wrong namespace -> SaslException', () async {
      final t = FakeTransport();
      final result = expectLater(
          _conn(t, TlsMode.none).connect(), throwsA(isA<SaslException>()));
      await pump();
      t.deliver(_features(
          '<mechanisms xmlns="wrong"><mechanism>PLAIN</mechanism></mechanisms>'));
      await result;
    });
  });

  group('error surfacing + cleanup', () {
    test('incoming stream error during negotiation -> XmlParseException',
        () async {
      final t = FakeTransport();
      final result = expectLater(
          _conn(t, TlsMode.none).connect(),
          throwsA(isA<XmlParseException>()));
      await pump();
      t.deliverError(const FormatException('bad utf8'));
      await result;
      expect(t.closed, isTrue);
    });

    test('stream error surfaces on errors stream when online', () async {
      final t = FakeTransport();
      final conn = _conn(t, TlsMode.none);
      final errors = <Object>[];
      conn.errors.listen(errors.add);
      final fut = conn.connect();
      await pump();
      t.deliver(_features(_plain));
      await pump();
      t.deliver(_success);
      await pump();
      t.deliver(_features(''));
      await pump();
      t.deliver(_bindResult);
      await fut;

      // Online: parser depth is 1, so the error is a top-level element (no
      // fresh stream header).
      t.deliver('<stream:error><host-unknown/></stream:error>');
      await pump();
      expect(errors.single, isA<StreamErrorException>());
      expect((errors.single as StreamErrorException).condition, 'host-unknown');
    });
  });
}
