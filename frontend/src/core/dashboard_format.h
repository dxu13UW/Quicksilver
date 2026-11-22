#pragma once
// Pure text helpers for the dashboard (no widgets, no state). Kept separate so
// the wording and number formats are unit-tested in one place.

#include <QDateTime>
#include <QJsonValue>
#include <QString>

#include <optional>

namespace qs::fmt {

// ISO-8601 UTC with milliseconds ("2026-11-19T21:00:00.000Z"), as PROTOCOL
// sends it. Invalid or null input gives an invalid QDateTime.
QDateTime parseTimestamp(const QJsonValue &value);

// A JSON number, or nullopt for null / missing / non-numbers.
std::optional<double> optionalNumber(const QJsonValue &value);

// "just now", "1 min ago", "14 min ago", "2 h 5 min ago", "3 days ago".
// Negative ages (clock skew) count as "just now".
QString ago(qint64 seconds);
// A bare duration: "45 s", "4 min", "2 h 5 min", "3 days".
QString duration(qint64 seconds);

// Prices. Chaos: 2 decimals under 10, 1 under 100, none above, with
// thousands separators. Divine: 4 significant digits, so cheap currency still
// shows a value ("0.0046"). Both return "–" for nullopt.
QString chaos(std::optional<double> value);
QString divine(std::optional<double> value);
// "+2.1%", "−0.4%" (true minus sign), "0.0%".
QString percentChange(std::optional<double> value);
// Compact chaos volume: "950 c", "12.3k c", "4.56M c".
QString volume(std::optional<double> value);

// Friendly names for the health source ids; unknown ids come back unchanged.
QString sourceName(const QString &id);

} // namespace qs::fmt
