import 'dart:async';

import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xmpp_dart/src/errors.dart';
import 'package:xmpp_dart/src/iq.dart';
import 'package:xmpp_dart/src/reconnect.dart';
import 'package:xmpp_dart/src/stream_management.dart';
import 'package:xmpp_dart/src/xml.dart';

void main() {
  group('isPermanentError', () {
    test('auth/tls/protocol are permanent', () {
      expect(isPermanentError(SaslException('x')), isTrue);
      expect(isPermanentError(TlsException('x')), isTrue);
      expect(isPermanentError(NegotiationException('x')), isTrue);
      expect(isPermanentError(StreamManagementException('x')), isTrue);
    });

    test('timeouts / socket errors are transient', () {
      expect(isPermanentError(TimeoutException('x')), isFalse);
      expect(isPermanentError(Exception('socket')), isFalse);
    });

    test('stream errors classify by condition', () {
      expect(isPermanentError(StreamErrorException('x', condition: 'host-unknown')),
          isTrue);
      expect(
          isPermanentError(
              StreamErrorException('x', condition: 'system-shutdown')),
          isFalse);
    });
  });

  group('Reconnect policy', () {
    test('does not retry permanent failures', () async {
      var calls = 0;
      final r = Reconnect(
        () async {
          calls++;
          throw SaslException('bad creds');
        },
        sleep: (_) async {},
      );
      await expectLater(r.run(), throwsA(isA<SaslException>()));
      expect(calls, 1);
    });

    test('retries transient failures then succeeds', () async {
      var calls = 0;
      final r = Reconnect(
        () async {
          calls++;
          if (calls < 3) throw TimeoutException('drop');
        },
        sleep: (_) async {},
      );
      await r.run();
      expect(calls, 3);
    });

    test('gives up after maxAttempts', () async {
      var calls = 0;
      final r = Reconnect(
        () async {
          calls++;
          throw TimeoutException('drop');
        },
        maxAttempts: 2,
        sleep: (_) async {},
      );
      await expectLater(r.run(), throwsA(isA<TimeoutException>()));
      expect(calls, 2);
    });
  });

  group('IqCaller lifecycle', () {
    test('dispose fails pending requests', () async {
      final incoming = StreamController<XmlElement>.broadcast();
      final caller = IqCaller(incoming.stream, (_) {});
      final fut = caller.request(xml('iq', attrs: {'type': 'get'}));
      // Attach the matcher before dispose fires the error.
      final expectation = expectLater(fut, throwsA(isA<StateError>()));
      await caller.dispose();
      await expectation;
    });

    test('duplicate in-flight id is rejected', () async {
      final incoming = StreamController<XmlElement>.broadcast();
      final caller = IqCaller(incoming.stream, (_) {});
      caller.request(xml('iq', attrs: {'type': 'get', 'id': 'dup'})).ignore();
      final second = caller.request(xml('iq', attrs: {'type': 'get', 'id': 'dup'}));
      await expectLater(second, throwsA(isA<IqException>()));
      await caller.dispose();
    });

    test('send failure removes the pending entry and errors the future',
        () async {
      final incoming = StreamController<XmlElement>.broadcast();
      final caller = IqCaller(incoming.stream, (_) => throw StateError('down'));
      final fut = caller.request(xml('iq', attrs: {'type': 'get', 'id': 'z'}));
      await expectLater(fut, throwsA(isA<StateError>()));
      // id freed: a retry with the same id is not a duplicate.
      final retry = caller.request(xml('iq', attrs: {'type': 'get', 'id': 'z'}));
      await expectLater(retry, throwsA(isA<StateError>()));
    });
  });

  group('StreamManagement counter validation', () {
    StreamManagement enabled() => StreamManagement()
      ..onEnabled(xml('enabled',
          attrs: {'xmlns': StreamManagement.ns, 'id': 'x', 'resume': 'true'}));

    test('ack regression throws', () {
      final sm = enabled();
      sm.trackOutbound(xml('message', attrs: {'id': 'a'}));
      sm.trackOutbound(xml('message', attrs: {'id': 'b'}));
      sm.handleAck(2);
      expect(() => sm.handleAck(1), throwsA(isA<StreamManagementException>()));
    });

    test('ack overshoot throws', () {
      final sm = enabled();
      sm.trackOutbound(xml('message', attrs: {'id': 'a'}));
      expect(() => sm.handleAck(5), throwsA(isA<StreamManagementException>()));
    });

    test('resumed without h throws', () {
      final sm = enabled();
      expect(
          () => sm.onResumed(xml('resumed', attrs: {'xmlns': StreamManagement.ns})),
          throwsA(isA<StreamManagementException>()));
    });
  });
}
