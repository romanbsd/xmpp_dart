import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xmpp_dart/src/stream_management.dart';
import 'package:xmpp_dart/src/xml.dart';

void main() {
  XmlElement enabled({String? id, String resume = 'true', String? max}) =>
      xml('enabled', attrs: {'xmlns': StreamManagement.ns, 'resume': resume, 'id': ?id, 'max': ?max});

  test('onEnabled activates and resets counters', () {
    final sm = StreamManagement();
    sm.onEnabled(enabled(id: 'abc', max: '600'));
    expect(sm.enabled, isTrue);
    expect(sm.resumable, isTrue);
    expect(sm.id, 'abc');
    expect(sm.max, 600);
    expect(sm.inbound, 0);
    expect(sm.outbound, 0);
  });

  test('resume=false yields no resumable id', () {
    final sm = StreamManagement();
    sm.onEnabled(enabled(id: 'abc', resume: 'false'));
    expect(sm.enabled, isTrue);
    expect(sm.resumable, isFalse);
    expect(sm.id, isNull);
  });

  test('tracks outbound stanzas only when enabled', () {
    final sm = StreamManagement();
    sm.trackOutbound(xml('message', attrs: {'id': '1'}));
    expect(sm.outboundQueue, isEmpty); // not enabled yet

    sm.onEnabled(enabled(id: 'x'));
    sm.trackOutbound(xml('message', attrs: {'id': '1'}));
    sm.trackOutbound(xml('r', attrs: {'xmlns': StreamManagement.ns})); // nonza
    expect(sm.outboundQueue, hasLength(1));
  });

  test('handleAck drops acked stanzas and emits them', () async {
    final sm = StreamManagement()..onEnabled(enabled(id: 'x'));
    final acked = <String?>[];
    sm.acks.listen((e) => acked.add(e.getAttribute('id')));

    sm.trackOutbound(xml('message', attrs: {'id': 'a'}));
    sm.trackOutbound(xml('message', attrs: {'id': 'b'}));
    sm.trackOutbound(xml('message', attrs: {'id': 'c'}));

    sm.handleAck(2);
    await Future<void>.delayed(Duration.zero);

    expect(sm.outbound, 2);
    expect(sm.outboundQueue, hasLength(1));
    expect(sm.outboundQueue.single.getAttribute('id'), 'c');
    expect(acked, ['a', 'b']);
  });

  test('countInbound increments only for stanzas when enabled', () {
    final sm = StreamManagement()..onEnabled(enabled(id: 'x'));
    sm.countInbound(xml('message'));
    sm.countInbound(xml('presence'));
    sm.countInbound(xml('a', attrs: {'xmlns': StreamManagement.ns})); // nonza
    expect(sm.inbound, 2);
  });

  test('onResumed acks and returns remaining queue to resend', () {
    final sm = StreamManagement()..onEnabled(enabled(id: 'x'));
    sm.trackOutbound(xml('message', attrs: {'id': 'a'}));
    sm.trackOutbound(xml('message', attrs: {'id': 'b'}));
    sm.trackOutbound(xml('message', attrs: {'id': 'c'}));
    sm.onDisconnect();
    expect(sm.enabled, isFalse);

    final resend = sm.onResumed(xml('resumed', attrs: {'xmlns': StreamManagement.ns, 'h': '1'}));

    expect(sm.enabled, isTrue);
    expect(sm.outbound, 1);
    expect(resend.map((e) => e.getAttribute('id')), ['b', 'c']);
  });

  test('onFailedResume clears the session', () {
    final sm = StreamManagement()..onEnabled(enabled(id: 'x'));
    sm.trackOutbound(xml('message', attrs: {'id': 'a'}));
    sm.onFailedResume();
    expect(sm.resumable, isFalse);
    expect(sm.enabled, isFalse);
    expect(sm.outboundQueue, isEmpty);
  });

  test('wire elements', () {
    final sm = StreamManagement(preferredMax: 300)..onEnabled(enabled(id: 'sess1'));
    sm.inbound = 5;
    expect(sm.enableElement().getAttribute('resume'), 'true');
    expect(sm.enableElement().getAttribute('max'), '300');
    expect(sm.ackElement().getAttribute('h'), '5');
    expect(sm.resumeElement().getAttribute('previd'), 'sess1');
    expect(sm.resumeElement().getAttribute('h'), '5');
    expect(sm.requestElement().name.local, 'r');
  });
}
