import 'dart:async';

import 'package:xml/xml.dart';

import 'jid.dart';
import 'xml.dart';

/// XEP-0198 Stream Management state and logic.
///
/// Holds the session counters and the unacked-stanza queue. Deliberately
/// decoupled from the connection (like [IqCaller]): the connection feeds it
/// incoming/outgoing elements and builds the wire elements it produces, so the
/// bookkeeping can be tested without a socket. A single instance is kept across
/// reconnects by the client so a session can be resumed.
class StreamManagement {
  static const ns = 'urn:xmpp:sm:3';

  /// Preferred `max` resume window (seconds) sent in `<enable/>`; null omits it.
  final int? preferredMax;

  /// Whether SM is currently active on the live stream.
  bool enabled = false;

  /// Resume id from `<enabled resume='true' id=.../>`. Non-null => resumable.
  String? id;

  /// Server's advertised max resume window (seconds), if any.
  int? max;

  /// `h`: count of inbound stanzas we have handled.
  int inbound = 0;

  /// Count of our outbound stanzas the server has acknowledged.
  int outbound = 0;

  /// Sent stanzas not yet acknowledged by the server.
  final List<XmlElement> outboundQueue = [];

  /// The bound full JID, preserved across a resume (no re-bind).
  Jid? jid;

  final _acks = StreamController<XmlElement>.broadcast();

  StreamManagement({this.preferredMax});

  /// Emits each stanza as the server acknowledges it.
  Stream<XmlElement> get acks => _acks.stream;

  bool get resumable => id != null;

  static bool isStanza(XmlElement el) {
    final n = el.name.local;
    return n == 'iq' || n == 'message' || n == 'presence';
  }

  // --- outbound ---

  /// Queues a just-sent stanza for later acknowledgement.
  void trackOutbound(XmlElement el) {
    if (enabled && isStanza(el)) outboundQueue.add(el);
  }

  // --- inbound ---

  /// Counts a received stanza toward the inbound `h`.
  void countInbound(XmlElement el) {
    if (enabled && isStanza(el)) inbound++;
  }

  /// Processes an `<a h=.../>`: acknowledges (and drops) that many queued
  /// stanzas from the front, emitting each on [acks].
  void handleAck(int h) {
    final n = h - outbound;
    for (var i = 0; i < n && outboundQueue.isNotEmpty; i++) {
      _acks.add(outboundQueue.removeAt(0));
    }
    outbound = h;
  }

  // --- negotiation results ---

  /// Applies an `<enabled/>`: a fresh session. Counters and queue reset.
  void onEnabled(XmlElement el) {
    enabled = true;
    final resume = el.getAttribute('resume');
    id = (resume == 'true' || resume == '1') ? el.getAttribute('id') : null;
    max = int.tryParse(el.getAttribute('max') ?? '');
    inbound = 0;
    outbound = 0;
    outboundQueue.clear();
  }

  /// Applies a `<resumed h=.../>`: acknowledges what the server received and
  /// returns the still-unacked stanzas for the connection to resend.
  List<XmlElement> onResumed(XmlElement el) {
    handleAck(int.parse(el.getAttribute('h')!));
    enabled = true;
    return List<XmlElement>.of(outboundQueue);
  }

  /// The server rejected resumption — the previous session is gone.
  void onFailedResume() {
    id = null;
    enabled = false;
    inbound = 0;
    outbound = 0;
    outboundQueue.clear();
  }

  /// The live stream dropped. Keeps id/counters/queue for a later resume.
  void onDisconnect() {
    enabled = false;
  }

  // --- wire elements ---

  XmlElement enableElement() => xml('enable', attrs: {
        'xmlns': ns,
        'resume': 'true',
        if (preferredMax != null) 'max': '$preferredMax',
      });

  XmlElement resumeElement() =>
      xml('resume', attrs: {'xmlns': ns, 'previd': id!, 'h': '$inbound'});

  XmlElement ackElement() => xml('a', attrs: {'xmlns': ns, 'h': '$inbound'});

  XmlElement requestElement() => xml('r', attrs: {'xmlns': ns});

  Future<void> dispose() => _acks.close();
}
