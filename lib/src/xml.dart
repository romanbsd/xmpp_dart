import 'dart:async';
import 'dart:convert' show ChunkedConversionSink;

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

/// Builds an [XmlElement] concisely: `xml('message', attrs: {...}, text: 'hi')`.
XmlElement xml(
  String name, {
  Map<String, String>? attrs,
  List<XmlElement>? children,
  String? text,
}) {
  return XmlElement(
    XmlName.parts(name),
    [
      for (final e in (attrs ?? const {}).entries)
        XmlAttribute(XmlName.parts(e.key), e.value),
    ],
    [
      if (text != null) XmlText(text),
      ...?children,
    ],
  );
}

/// Incremental parser for an XMPP stream.
///
/// XMPP frames the whole session inside one never-closed `<stream:stream>`
/// element, with each stanza a direct child. Standard DOM parsing can't handle
/// the unclosed root, so this tracks element depth over a streaming event
/// decoder and emits:
///
/// - [streamOpen]: the opening `<stream:stream>` tag (its attributes only).
/// - [stanzas]: each top-level child element, once complete.
/// - [streamClose]: the closing `</stream:stream>` tag.
///
/// Call [feed] with decoded string chunks (any split point is fine). Call
/// [reset] to start a fresh stream after a restart (post-STARTTLS / post-SASL).
class XmlStreamParser {
  final _open = StreamController<XmlElement>.broadcast(sync: true);
  final _stanzas = StreamController<XmlElement>.broadcast(sync: true);
  final _close = StreamController<void>.broadcast(sync: true);

  Stream<XmlElement> get streamOpen => _open.stream;
  Stream<XmlElement> get stanzas => _stanzas.stream;
  Stream<void> get streamClose => _close.stream;

  late ChunkedConversionSink<String> _sink;
  int _depth = 0;
  final List<XmlEvent> _buffer = [];

  XmlStreamParser() {
    reset();
  }

  /// Discards parser state for a stream restart.
  void reset() {
    _depth = 0;
    _buffer.clear();
    _sink = XmlEventDecoder().startChunkedConversion(_EventSink(_onEvents));
  }

  void feed(String chunk) => _sink.add(chunk);

  void _onEvents(List<XmlEvent> events) {
    for (final e in events) {
      _handle(e);
    }
  }

  void _handle(XmlEvent e) {
    if (e is XmlStartElementEvent) {
      if (_depth == 0) {
        _open.add(_fromStart(e));
        if (!e.isSelfClosing) _depth = 1;
        return;
      }
      if (_depth == 1 && e.isSelfClosing) {
        _stanzas.add(_build([e]));
        return;
      }
      _buffer.add(e);
      if (!e.isSelfClosing) _depth++;
      return;
    }

    if (e is XmlEndElementEvent) {
      if (_depth == 1) {
        _depth = 0;
        _close.add(null);
        return;
      }
      _depth--;
      _buffer.add(e);
      if (_depth == 1) {
        _stanzas.add(_build(List.of(_buffer)));
        _buffer.clear();
      }
      return;
    }

    // text / cdata / comment — only meaningful inside a stanza.
    if (_depth >= 2) _buffer.add(e);
  }

  XmlElement _build(List<XmlEvent> events) =>
      const XmlNodeDecoder().convert(events).whereType<XmlElement>().first;

  XmlElement _fromStart(XmlStartElementEvent e) => XmlElement(
        XmlName.qualified(e.name),
        [for (final a in e.attributes) XmlAttribute(XmlName.qualified(a.name), a.value)],
      );

  void close() {
    _sink.close();
    unawaited(_open.close());
    unawaited(_stanzas.close());
    unawaited(_close.close());
  }
}

class _EventSink implements Sink<List<XmlEvent>> {
  final void Function(List<XmlEvent>) _onData;
  _EventSink(this._onData);

  @override
  void add(List<XmlEvent> data) => _onData(data);

  @override
  void close() {}
}
