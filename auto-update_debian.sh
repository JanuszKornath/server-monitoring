#!/bin/bash

HOSTNAME=$(hostname)

# === Prüfen, ob APT-Updates anstehen ===
SIM_LOG=$(mktemp)
apt-get -s dist-upgrade > "$SIM_LOG" 2>&1
APT_PENDING=$(grep -c '^Inst ' "$SIM_LOG")
rm -f "$SIM_LOG"

# === Snap-Updates prüfen (nur wenn snap vorhanden ist) ===
SNAP_PENDING=0
if command -v snap >/dev/null 2>&1; then
    SNAP_PENDING=$(snap refresh --list | tail -n +2 | wc -l)  # erste Zeile ist Header
fi

# === Updates ausführen (nur wenn nötig) ===
APT_UPDATED=0
SNAP_UPDATED=0

if [ "$APT_PENDING" -gt 0 ]; then
    APT_LOG=$(mktemp)
    apt update -qq
    apt -y dist-upgrade -qq > "$APT_LOG" 2>&1
    apt -y autoremove -qq >> "$APT_LOG" 2>&1
    APT_UPDATED=$APT_PENDING
    rm -f "$APT_LOG"
fi

if [ "$SNAP_PENDING" -gt 0 ]; then
    SNAP_LOG=$(mktemp)
    snap refresh >> "$SNAP_LOG" 2>&1
    SNAP_UPDATED=$SNAP_PENDING
    rm -f "$SNAP_LOG"
fi

# === Prüfen, ob ein Reboot erforderlich ist ===
if [ -f /var/run/reboot-required ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich nach Updates"
    REBOOT_MSG="Ein Neustart ist erforderlich, damit alle Änderungen wirksam werden."

elif [ "$APT_UPDATED" -gt 0 ] || [ "$SNAP_UPDATED" -gt 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
    REBOOT_MSG="Es wurden $APT_UPDATED APT-Pakete und $SNAP_UPDATED Snaps aktualisiert. Kein Neustart erforderlich."

else
    # Nichts passiert → keine Mail
    exit 0
fi

# === Mail erstellen ===
MAIL_BODY="Hallo,

auf dem Server ${HOSTNAME} wurden Updates überprüft.

$REBOOT_MSG

Viele Grüße
Dein automatisches Update-Skript"

echo -e "$MAIL_BODY" | mail -a "Content-Type: text/plain; charset=UTF-8" -s "$MAIL_SUBJECT" root
