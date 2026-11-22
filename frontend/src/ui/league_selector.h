#pragma once
// League picker bound to a LeagueController (DASH-2).
//
// Only a USER choice sends `league.set`: the combo's activated() signal (which
// Qt emits for user interaction only) calls controller->select(), and every
// programmatic fill/selection also runs under a QSignalBlocker. While a change
// is pending the note says so and further choices are refused (the combo
// stays enabled so it keeps keyboard focus); on failure it reverts to the
// controller's current league and shows the reason.

#include <QWidget>

class QComboBox;
class QLabel;
class QToolButton;
class QTimer;

namespace qs {

class LeagueController;

class LeagueSelector : public QWidget {
    Q_OBJECT
public:
    explicit LeagueSelector(LeagueController *controller, QWidget *parent = nullptr);

    QComboBox *combo() const { return m_combo; }
    QString noteText() const;

private:
    void refresh();
    void onActivated(int index);
    void setNote(const QString &text, const char *color, int clearAfterMs = 0);

    LeagueController *m_controller;
    QComboBox *m_combo;
    QToolButton *m_reload;
    QLabel *m_note;
    QTimer *m_noteTimer;
    QString m_eventNote;      // the last success/failure message
    const char *m_eventColor = nullptr;
};

} // namespace qs
