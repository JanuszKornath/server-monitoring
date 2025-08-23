#!/bin/bash

HOSTNAME=$(hostname)

# === Update & Upgrade ===
apt update -qq
apt -y dist-upgrade -qq
APT_LOG=$(mktemp)
apt -y dist-upgrade -qq > "$APT_LOG" 2>&1
apt -y autoremove -qq >> "$APT_LOG" 2>&1

# === Snap-Updates durchführen ===
SNAP_LOG=$(mktemp)
snap refresh >> "$SNAP_LOG" 2>&1

# === Prüfen, ob Pakete installiert wurden ===
APT_UPDATED=$(grep -E '^(Inst|Setting up|Unpacking|Removing)' "$APT_LOG" | wc -l)
SNAP_UPDATED=$(grep -v 'All snaps up to date' "$SNAP_LOG" | wc -l)

# === Prüfen, ob ein Reboot erforderlich ist ===
if [ -f /var/run/reboot-required ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich nach Updates"
    REBOOT_MSG="Ein Neustart ist erforderlich, damit alle Änderungen wirksam werden."
elif [ $APT_UPDATED -gt 0 ] || [ $SNAP_UPDATED -gt 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
    REBOOT_MSG="Updates wurden installiert. Kein Neustart erforderlich."
else
    MAIL_SUBJECT="[${HOSTNAME}] Keine Updates verfügbar"
    REBOOT_MSG="Keine Updates verfügbar."
fi

# === Mail erstellen ===
MAIL_BODY="Hallo,

auf dem Server ${HOSTNAME} wurden Updates überprüft.

$REBOOT_MSG

Viele Grüße
Dein automatisches Update-Skript"

echo -e "$MAIL_BODY" | mail -a "Content-Type: text/plain; charset=UTF-8" -s "$MAIL_SUBJECT" root

# === Tempfiles löschen ===
rm -f "$APT_LOG" "$SNAP_LOG"
