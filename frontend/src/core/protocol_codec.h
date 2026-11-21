#pragma once
// Pure functions for PROTOCOL.md v1: the stdout READY line, the JSON envelope,
// and the per-launch token. No I/O, no QObject, so it is easy to unit test.

#include <QByteArray>
#include <QJsonObject>
#include <QString>

#include <optional>

namespace qs::protocol {

inline constexpr int kProtocolVersion = 1;

// QUICKSILVER_READY {"port":N,"protocol_version":1}
struct ReadyInfo {
    quint16 port = 0;
    int protocolVersion = 0;
};

// Matches one stdout line against
//   ^QUICKSILVER_READY \{"port":(\d+),"protocol_version":1\}$
// A trailing "\r" and/or "\n" is stripped first (Windows pipes). Anything else
// (compile output in dev, a different protocol version, port 0 or > 65535)
// returns nullopt.
std::optional<ReadyInfo> parseReadyLine(const QByteArray &line);

struct Envelope {
    QString type;
    QString id; // empty when isNullId
    bool isNullId = true;
    QJsonObject payload;
};

// Why a frame could not be decoded. Mirrors the server's bad_json rule.
struct DecodeError {
    QString reason;
};

struct DecodeResult {
    std::optional<Envelope> envelope;
    DecodeError error;
    bool ok() const { return envelope.has_value(); }
};

// Decodes one text frame. Requires a JSON object with a string `type`, an
// object `payload`, and an `id` that is a string or null (a missing id is read
// as null). `ts` and unknown fields are ignored.
DecodeResult decodeEnvelope(const QByteArray &frame);

// Encodes one message. An empty `id` is sent as JSON null (server pushes only;
// the client always sends an id). `ts` is the current UTC time with ms + "Z".
QByteArray encodeEnvelope(const QString &type, const QString &id, const QJsonObject &payload);

// UTC, ISO-8601, milliseconds, "Z" suffix: 2026-11-19T21:04:05.123Z
QString timestampNow();

// 32 lowercase hex chars from the OS cryptographic RNG.
QString generateToken();

// The `hello` payload.
QJsonObject helloPayload(const QString &clientVersion, const QString &token);

} // namespace qs::protocol
