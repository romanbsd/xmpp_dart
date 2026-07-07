import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmpp_dart/src/srv.dart';

void main() {
  group('buildDnsQuery', () {
    test('encodes header and question', () {
      final q = buildDnsQuery(0x1234, '_xmpp-client._tcp.example.com');
      // id
      expect(q[0], 0x12);
      expect(q[1], 0x34);
      // flags: recursion desired
      expect(q[2], 0x01);
      expect(q[3], 0x00);
      // qdcount = 1
      expect(q[4], 0x00);
      expect(q[5], 0x01);
      // first label: length 12 = "_xmpp-client"
      expect(q[12], 12);
      expect(String.fromCharCodes(q.sublist(13, 25)), '_xmpp-client');
      // trailer: qtype SRV (33) + qclass IN (1)
      expect(q[q.length - 4], 0x00);
      expect(q[q.length - 3], 33);
      expect(q[q.length - 2], 0x00);
      expect(q[q.length - 1], 1);
    });
  });

  group('parseSrvResponse', () {
    // Build a response for _xmpp-client._tcp.example.com with two answers,
    // one target spelled out and one using a compression pointer.
    Uint8List response() {
      final msg = BytesBuilder();
      // Reuse query encoder for header + question, then patch ancount.
      final head = buildDnsQuery(0x1234, '_xmpp-client._tcp.example.com');
      final q = Uint8List.fromList(head);
      q[6] = 0x00;
      q[7] = 0x02; // ancount = 2
      msg.add(q);

      // "example.com" begins at message offset 30 within the question.
      const exampleComPtrHi = 0xc0;
      const exampleComPtrLo = 30;

      void answer(
          int priority, int weight, int port, List<int> target) {
        msg.add([0xc0, 0x0c]); // name -> question at offset 12
        msg.add([0x00, 33]); // type SRV
        msg.add([0x00, 1]); // class IN
        msg.add([0x00, 0x00, 0x00, 0x78]); // ttl 120
        final rdlen = 6 + target.length;
        msg.add([(rdlen >> 8) & 0xff, rdlen & 0xff]);
        msg.add([(priority >> 8) & 0xff, priority & 0xff]);
        msg.add([(weight >> 8) & 0xff, weight & 0xff]);
        msg.add([(port >> 8) & 0xff, port & 0xff]);
        msg.add(target);
      }

      // Record A: target "xmpp1.example.com" fully spelled.
      answer(10, 5, 5222, [
        5, ...'xmpp1'.codeUnits,
        7, ...'example'.codeUnits,
        3, ...'com'.codeUnits,
        0,
      ]);
      // Record B: target "xmpp2" + pointer to "example.com".
      answer(5, 20, 5269, [
        5, ...'xmpp2'.codeUnits,
        exampleComPtrHi, exampleComPtrLo,
      ]);

      return msg.toBytes();
    }

    test('parses records including compressed target', () {
      final records = parseSrvResponse(response());
      expect(records, hasLength(2));
      expect(records[0].target, 'xmpp1.example.com');
      expect(records[0].port, 5222);
      expect(records[0].priority, 10);
      expect(records[1].target, 'xmpp2.example.com'); // pointer followed
      expect(records[1].port, 5269);
      expect(records[1].priority, 5);
    });

    test('empty on a too-short message', () {
      expect(() => parseSrvResponse(Uint8List(4)),
          throwsA(isA<FormatException>()));
    });
  });

  group('compareSrv', () {
    test('lower priority first, then higher weight', () {
      final records = [
        const SrvRecord(10, 5, 1, 'a'),
        const SrvRecord(5, 10, 1, 'b'),
        const SrvRecord(5, 30, 1, 'c'),
      ]..sort(compareSrv);
      expect(records.map((r) => r.target), ['c', 'b', 'a']);
    });
  });
}
