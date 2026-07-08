import 'dart:async';

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xmpp_dart/src/iq.dart';
import 'package:xmpp_dart/src/xml.dart';

void main() {
  late StreamController<XmlElement> incoming;
  late List<XmlElement> sent;
  late IqCaller caller;

  setUp(() {
    incoming = StreamController<XmlElement>.broadcast();
    sent = [];
    caller = IqCaller(incoming.stream, sent.add, timeout: const Duration(milliseconds: 200));
  });

  tearDown(() async {
    await incoming.close();
  });

  test('assigns id and resolves on matching response', () async {
    final fut = caller.request(xml('iq', attrs: {'type': 'get'}));
    final id = sent.single.getAttribute('id');
    expect(id, isNotNull);

    incoming.add(xml('iq', attrs: {'type': 'result', 'id': id!}));
    final res = await fut;
    expect(res.getAttribute('type'), 'result');
  });

  test('ignores responses with a different id', () async {
    final fut = caller.request(xml('iq', attrs: {'type': 'get'}));
    final id = sent.single.getAttribute('id')!;

    incoming.add(xml('iq', attrs: {'type': 'result', 'id': 'other'}));
    incoming.add(xml('iq', attrs: {'type': 'result', 'id': id}));
    await expectLater(fut, completes);
  });

  test('error response completes with IqException', () async {
    final fut = caller.request(xml('iq', attrs: {'type': 'set'}));
    final id = sent.single.getAttribute('id')!;
    incoming.add(xml('iq', attrs: {'type': 'error', 'id': id}));
    await expectLater(fut, throwsA(isA<IqException>()));
  });

  test('times out without a response', () async {
    final fut = caller.request(xml('iq', attrs: {'type': 'get'}));
    await expectLater(fut, throwsA(isA<TimeoutException>()));
  });
}
