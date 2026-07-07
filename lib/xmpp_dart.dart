/// A lightweight Dart port of xmpp.js — a TCP XMPP client.
library;

export 'src/client.dart' show TransportFactory, XmppClient;
export 'src/connection.dart' show TlsMode, XmppConnection, XmppState;
export 'src/errors.dart'
    show
        NegotiationException,
        ReconnectException,
        SaslException,
        StreamErrorException,
        StreamManagementException,
        TlsException,
        XmlParseException,
        XmppException,
        isPermanentError;
export 'src/iq.dart' show IqCaller, IqException;
export 'src/iq_responder.dart' show IqError, IqHandler, IqResponder;
export 'src/jid.dart' show Jid;
export 'src/reconnect.dart' show Reconnect;
export 'src/sasl.dart'
    show PlainMechanism, SaslMechanism, ScramSha1Mechanism;
export 'src/stream_management.dart' show StreamManagement;
export 'src/transport.dart' show TcpTransport, Transport;
export 'src/xml.dart' show XmlStreamParser, xml;
