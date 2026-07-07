import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:xmpp_dart/src/xml.dart';

void main() {
  group('xml() builder', () {
    test('attrs and text', () {
      final e = xml('body', attrs: {'lang': 'en'}, text: 'hi');
      expect(e.toXmlString(), '<body lang="en">hi</body>');
    });

    test('nested children', () {
      final e = xml('message', attrs: {'to': 'a@b'}, children: [
        xml('body', text: 'yo'),
      ]);
      expect(e.getAttribute('to'), 'a@b');
      expect(e.getElement('body')!.innerText, 'yo');
    });
  });

  group('XmlStreamParser', () {
    late XmlStreamParser p;
    late List<String> stanzas;
    late List<String> opens;
    var closed = 0;

    setUp(() {
      p = XmlStreamParser();
      stanzas = [];
      opens = [];
      closed = 0;
      p.streamOpen.listen((e) => opens.add(e.getAttribute('id') ?? ''));
      p.stanzas.listen((e) => stanzas.add(e.toXmlString()));
      p.streamClose.listen((_) => closed++);
    });

    test('emits stream open header then a stanza', () {
      p.feed("<?xml version='1.0'?>"
          "<stream:stream xmlns='jabber:client' id='c1' version='1.0'>");
      p.feed('<message><body>hi</body></message>');
      expect(opens, ['c1']);
      expect(stanzas, ['<message><body>hi</body></message>']);
    });

    test('reassembles a stanza split across chunks', () {
      p.feed("<stream:stream id='c1'>");
      p.feed('<message><bod');
      p.feed('y>split</body></mess');
      p.feed('age>');
      expect(stanzas, ['<message><body>split</body></message>']);
    });

    test('multiple stanzas in one chunk', () {
      p.feed("<stream:stream id='c1'>");
      p.feed('<presence/><iq id="1"/>');
      expect(stanzas, ['<presence/>', '<iq id="1"/>']);
    });

    test('ignores whitespace keepalives between stanzas', () {
      p.feed("<stream:stream id='c1'>");
      p.feed('\n  \n');
      p.feed('<presence/>');
      expect(stanzas, ['<presence/>']);
    });

    test('reset() starts a fresh stream', () {
      p.feed("<stream:stream id='c1'><presence/>");
      p.reset();
      p.feed('<stream:stream id="c2"><iq id="9"/>');
      expect(opens, ['c1', 'c2']);
      expect(stanzas, ['<presence/>', '<iq id="9"/>']);
    });

    test('emits stream close', () {
      p.feed("<stream:stream id='c1'>");
      p.feed('</stream:stream>');
      expect(closed, 1);
    });
  });
}
