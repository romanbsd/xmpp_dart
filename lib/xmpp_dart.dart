/// A lightweight Dart port of xmpp.js — a TCP XMPP client.
library;

export 'src/client.dart' show XmppClient;
export 'src/connection.dart'
    show
        StreamErrorException,
        TlsMode,
        XmppConnection,
        XmppException,
        XmppState;
export 'src/iq.dart' show IqCaller, IqException;
export 'src/jid.dart' show Jid;
export 'src/reconnect.dart' show Reconnect;
export 'src/sasl.dart'
    show PlainMechanism, SaslException, SaslMechanism, ScramSha1Mechanism;
export 'src/transport.dart' show TcpTransport, Transport;
export 'src/xml.dart' show XmlStreamParser, xml;
