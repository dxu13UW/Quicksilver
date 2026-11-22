#include "ui/league_selector.h"

#include "core/league_controller.h"

#include <QComboBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QSignalBlocker>
#include <QTimer>
#include <QToolButton>

namespace qs {

namespace {
constexpr const char *kMuted = "#6b7280";
constexpr const char *kGood = "#2f9e62";
constexpr const char *kBad = "#c8433a";
constexpr const char *kBusy = "#b7791f";
} // namespace

LeagueSelector::LeagueSelector(LeagueController *controller, QWidget *parent)
    : QWidget(parent), m_controller(controller)
{
    auto *label = new QLabel(QStringLiteral("League"));
    QFont lf = label->font();
    lf.setBold(true);
    label->setFont(lf);

    m_combo = new QComboBox;
    m_combo->setObjectName(QStringLiteral("leagueCombo"));
    m_combo->setMinimumContentsLength(22);
    m_combo->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
    m_combo->setPlaceholderText(QStringLiteral("Choose a league"));
    m_combo->setToolTip(QStringLiteral("Prices and rates follow this league. Your choice is remembered."));
    m_combo->setAccessibleName(QStringLiteral("League"));

    m_reload = new QToolButton;
    m_reload->setText(QStringLiteral("Reload list"));
    m_reload->setToolTip(QStringLiteral("Ask the backend for the league list again"));
    m_reload->setAccessibleName(QStringLiteral("Reload league list"));

    m_note = new QLabel;
    m_note->setObjectName(QStringLiteral("leagueNote"));
    m_note->setTextInteractionFlags(Qt::TextSelectableByMouse);

    m_noteTimer = new QTimer(this);
    m_noteTimer->setSingleShot(true);
    connect(m_noteTimer, &QTimer::timeout, this, [this] {
        m_eventNote.clear();
        refresh();
    });

    auto *row = new QHBoxLayout(this);
    row->setContentsMargins(0, 0, 0, 0);
    row->addWidget(label);
    row->addWidget(m_combo);
    row->addWidget(m_reload);
    row->addWidget(m_note, 1);

    // activated() is user-only; currentIndexChanged would also fire on fills.
    connect(m_combo, &QComboBox::activated, this, &LeagueSelector::onActivated);
    connect(m_reload, &QToolButton::clicked, m_controller, &LeagueController::reload);
    connect(m_controller, &LeagueController::changed, this, &LeagueSelector::refresh);
    connect(m_controller, &LeagueController::currentChanged, this, &LeagueSelector::refresh);
    connect(m_controller, &LeagueController::changeStarted, this, [this] {
        m_eventNote.clear();
        m_noteTimer->stop();
    });
    connect(m_controller, &LeagueController::changeSucceeded, this, [this](const QString &league) {
        setNote(QStringLiteral("Switched to %1. Saved for next launch.").arg(m_controller->textFor(league)), kGood,
                5000);
    });
    connect(m_controller, &LeagueController::backendChanged, this, [this](const QString &league) {
        setNote(QStringLiteral("Backend switched to %1").arg(m_controller->textFor(league)), kMuted, 8000);
    });
    connect(m_controller, &LeagueController::changeFailed, this,
            [this](const QString &league, const QString &, const QString &message) {
                setNote(QStringLiteral("Couldn't switch to %1: %2").arg(m_controller->textFor(league), message), kBad);
            });
    refresh();
}

QString LeagueSelector::noteText() const
{
    return m_note->text();
}

void LeagueSelector::setNote(const QString &text, const char *color, int clearAfterMs)
{
    m_eventNote = text;
    m_eventColor = color;
    if (clearAfterMs > 0)
        m_noteTimer->start(clearAfterMs);
    else
        m_noteTimer->stop();
    refresh();
}

void LeagueSelector::refresh()
{
    const LeagueController *c = m_controller;
    const QString shown = c->isPending() ? c->pending() : c->current();

    {
        // Filling and selecting from code must never send league.set.
        const QSignalBlocker block(m_combo);
        m_combo->clear();
        for (const League &l : c->leagues())
            m_combo->addItem(l.text, l.id);
        int idx = m_combo->findData(shown);
        if (idx < 0 && !shown.isEmpty() && c->leagues().isEmpty()) {
            // No list (yet): still show the active league.
            m_combo->addItem(shown, shown);
            idx = 0;
        }
        m_combo->setCurrentIndex(idx);
    }

    // Stays enabled while a change is pending, so keyboard focus isn't pushed
    // elsewhere; choices made meanwhile are refused by the controller (one
    // change at a time) and the combo snaps back to the pending league.
    const bool canChoose = c->connected() && c->listState() == LeagueController::ListState::Loaded &&
                           !c->leagues().isEmpty();
    m_combo->setEnabled(canChoose);
    m_reload->setVisible(c->connected() && c->listState() == LeagueController::ListState::Unavailable);

    QString text;
    const char *color = kMuted;
    if (c->isPending()) {
        text = QStringLiteral("Switching to %1…").arg(c->textFor(c->pending()));
        color = kBusy;
    } else if (!m_eventNote.isEmpty()) {
        text = m_eventNote;
        color = m_eventColor ? m_eventColor : kMuted;
    } else if (!c->connected()) {
        text = QStringLiteral("Not connected");
    } else if (c->listState() == LeagueController::ListState::Loading) {
        text = QStringLiteral("Loading leagues…");
    } else if (c->listState() == LeagueController::ListState::Unavailable) {
        text = QStringLiteral("League list unavailable: %1").arg(c->listError());
        color = kBad;
    } else if (c->current().isEmpty()) {
        text = QStringLiteral("No league chosen yet");
    }
    m_note->setText(text);
    m_note->setStyleSheet(QStringLiteral("QLabel { color: %1; }").arg(QLatin1String(color)));
}

void LeagueSelector::onActivated(int index)
{
    const QString id = m_combo->itemData(index).toString();
    if (!m_controller->select(id))
        refresh(); // same league, busy or offline: put the combo back
}

} // namespace qs
