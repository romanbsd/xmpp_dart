import 'dart:async';

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xmpp_dart/src/iq_responder.dart';
import 'package:xmpp_dart/src/xml.dart';

import 'support/fake_transport.dart';

void main() {
  late StreamController<XmlElement> incoming;
  late List<XmlElement> sent;
  late IqResponder r;

  setUp(() {
    incoming = StreamController<XmlElement>.broadcast();
    sent = [];
    r = IqResponder(incoming.stream, sent.add);
  });

  XmlElement iqGet(String ns, String name,
          {String from = 'server', String id = 'q1'}) =>
      xml('iq', attrs: {'type': 'get', 'from': from, 'id': id},
          children: [xml(name, attrs: {'xmlns': ns})]);

  test('routed handler returns a result with from/to/id swapped', () async {
    r.get('urn:example', 'query', (iq, child) {
      return xml('data', attrs: {'xmlns': 'urn:example'}, text: 'ok');
    });

    incoming.add(iqGet('urn:example', 'query'));
    await pump();

    final reply = sent.single;
    expect(reply.getAttribute('type'), 'result');
    expect(reply.getAttribute('to'), 'server');
    expect(reply.getAttribute('id'), 'q1');
    expect(reply.getElement('data')!.innerText, 'ok');
  });

  test('empty result when handler returns null', () async {
    r.get('urn:xmpp:ping', 'ping', (_, __) => null);
    incoming.add(iqGet('urn:xmpp:ping', 'ping'));
    await pump();
    expect(sent.single.getAttribute('type'), 'result');
    expect(sent.single.childElements, isEmpty);
  });

  test('unmatched query -> service-unavailable', () async {
    incoming.add(iqGet('urn:nope', 'whatever'));
    await pump();
    final err = sent.single;
    expect(err.getAttribute('type'), 'error');
    expect(err.getElement('error')!.getElement('service-unavailable'),
        isNotNull);
  });

  test('malformed query (no single child) -> bad-request', () async {
    incoming.add(xml('iq', attrs: {'type': 'get', 'from': 's', 'id': '2'}));
    await pump();
    expect(sent.single.getElement('error')!.getElement('bad-request'),
        isNotNull);
  });

  test('handler throwing IqError -> that condition', () async {
    r.get('urn:example', 'query',
        (_, __) => throw IqError('forbidden', type: 'auth'));
    incoming.add(iqGet('urn:example', 'query'));
    await pump();
    final error = sent.single.getElement('error')!;
    expect(error.getAttribute('type'), 'auth');
    expect(error.getElement('forbidden'), isNotNull);
  });

  test('handler throwing anything else -> internal-server-error', () async {
    r.get('urn:example', 'query', (_, __) => throw StateError('boom'));
    incoming.add(iqGet('urn:example', 'query'));
    await pump();
    expect(
        sent.single.getElement('error')!.getElement('internal-server-error'),
        isNotNull);
  });

  test('ignores iq result/error stanzas', () async {
    incoming.add(xml('iq', attrs: {'type': 'result', 'id': 'x'}));
    incoming.add(xml('iq', attrs: {'type': 'error', 'id': 'y'}));
    await pump();
    expect(sent, isEmpty);
  });

  test('set routes separately from get', () async {
    var setHit = false;
    r.set('urn:example', 'cmd', (_, __) {
      setHit = true;
      return null;
    });
    incoming.add(xml('iq', attrs: {'type': 'set', 'from': 's', 'id': '9'},
        children: [xml('cmd', attrs: {'xmlns': 'urn:example'})]));
    await pump();
    expect(setHit, isTrue);
    expect(sent.single.getAttribute('type'), 'result');
  });
}
