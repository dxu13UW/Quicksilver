#include "core/protocol_codec.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QJsonValue>
#include <QRandomGenerator>
#include <QRegularExpression>

namespace qs::protocol {

std::optional<ReadyInfo> parseReadyLine(const QByteArray &rawLine)
{
    QByteArray line = rawLine;
    while (line.endsWith('\n') || line.endsWith('\r'))
        line.chop(1);

    static const QRegularExpression re(
        QStringLiteral("^QUICKSILVER_READY \\{\"port\":(\\d{1,5}),\"protocol_version\":(\\d+)\\}$"));
    const auto m = re.match(QString::fromLatin1(line));
    if (!m.hasMatch())
        return std::nullopt;

    bool okPort = false;
    const uint port = m.captured(1).toUInt(&okPort);
    bool okVersion = false;
    const int version = m.captured(2).toInt(&okVersion);
    if (!okPort || port == 0 || port > 65535 || !okVersion)
        return std::nullopt;

    return ReadyInfo{static_cast<quint16>(port), version};
}

DecodeResult decodeEnvelope(const QByteArray &frame)
{
    DecodeResult result;
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(frame, &parseError);
    if (parseError.error != QJsonParseError::NoError) {
        result.error.reason = QStringLiteral("invalid JSON: %1").arg(parseError.errorString());
        return result;
    }
    if (!doc.isObject()) {
        result.error.reason = QStringLiteral("not a JSON object");
        return result;
    }
    const QJsonObject obj = doc.object();

    const QJsonValue type = obj.value(QStringLiteral("type"));
    if (!type.isString() || type.toString().isEmpty()) {
        result.error.reason = QStringLiteral("missing or non-string 'type'");
        return result;
    }
    const QJsonValue payload = obj.value(QStringLiteral("payload"));
    if (!payload.isObject()) {
        result.error.reason = QStringLiteral("missing or non-object 'payload'");
        return result;
    }
    const QJsonValue id = obj.value(QStringLiteral("id"));
    Envelope env;
    if (id.isString()) {
        env.id = id.toString();
        env.isNullId = false;
    } else if (id.isNull() || id.isUndefined()) {
        env.isNullId = true;
    } else {
        result.error.reason = QStringLiteral("'id' is neither a string nor null");
        return result;
    }
    env.type = type.toString();
    env.payload = payload.toObject();
    result.envelope = std::move(env);
    return result;
}

QString timestampNow()
{
    return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
}

QByteArray encodeEnvelope(const QString &type, const QString &id, const QJsonObject &payload)
{
    QJsonObject obj;
    obj.insert(QStringLiteral("type"), type);
    obj.insert(QStringLiteral("id"), id.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(id));
    obj.insert(QStringLiteral("ts"), timestampNow());
    obj.insert(QStringLiteral("payload"), payload);
    return QJsonDocument(obj).toJson(QJsonDocument::Compact);
}

QString generateToken()
{
    quint32 words[4];
    QRandomGenerator::system()->fillRange(words);
    const QByteArray bytes(reinterpret_cast<const char *>(words), sizeof(words));
    return QString::fromLatin1(bytes.toHex());
}

QJsonObject helloPayload(const QString &clientVersion, const QString &token)
{
    QJsonObject p;
    p.insert(QStringLiteral("client_version"), clientVersion);
    p.insert(QStringLiteral("protocol_version"), kProtocolVersion);
    p.insert(QStringLiteral("token"), token);
    return p;
}

} // namespace qs::protocol
