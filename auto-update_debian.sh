#!/bin/bash

# === Hostname für den Betreff ===
HOSTNAME=$(hostname)

# === Prüfen, ob Updates verfügbar sind ===
apt update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v Listing | wc -l)

# === Snap-Updates prüfen ===
SNAP_LIST=$(snap refresh --list 2>/dev/null)
SNAP_UPGRADABLE=$(echo "$SNAP_LIST" | wc -l)

if [ "$UPGRADABLE" -eq 0 ] && [ "$SNAP_UPGRADABLE" -eq 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Keine Updates verfügbar"
    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} waren keine Updates verfügbar.\n\nViele Grüße\nDein automatisches Update-Skript"
else
    # === Update & Upgrade ===
    apt -y dist-upgrade -qq > /tmp/apt-upgrade.log 2>&1
    apt -y autoremove -qq > /tmp/apt-autoremove.log 2>&1

    # Paketnamen aus den Logs extrahieren
    UPGRADE_PKGS=$(grep -E "^Setting up|^Preparing to unpack|^Unpacking|^Installing" /tmp/apt-upgrade.log \
        | awk '{print $3}' | sort -u)
    AUTOREMOVE_PKGS=$(grep -E "^Removing" /tmp/apt-autoremove.log | awk '{print $2}' | sort -u)

    # === Snap-Pakete aktualisieren ===
    if [ "$SNAP_UPGRADABLE" -gt 0 ]; then
        SNAP_UPGRADE_LOG=$(snap refresh 2>&1)
    else
        SNAP_UPGRADE_LOG=""
    fi

    # === Prüfen, ob ein Reboot nötig ist ===
    if [ -f /var/run/reboot-required ]; then
        MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich nach Updates"
        REBOOT_MSG="Ein Neustart ist erforderlich, damit alle Änderungen wirksam werden."
    else
        MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
        REBOOT_MSG="Kein Neustart erforderlich."
    fi

    # === Zähler für die Zusammenfassung ===
    NUM_UPGRADE=$(echo "$UPGRADE_PKGS" | grep -cve '^\s*$')
    NUM_AUTOREMOVE=$(echo "$AUTOREMOVE_PKGS" | grep -cve '^\s*$')
    NUM_SNAP=$(echo "$SNAP_UPGRADE_LOG" | grep -cve '^\s*$')

    # === Mail-Body dynamisch zusammenbauen ===
    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} wurden Updates durchgeführt.\n\n$REBOOT_MSG\n\n"
    MAIL_BODY+="Update-Zusammenfassung:\n- APT aktualisierte Pakete: $NUM_UPGRADE\n- APT entfernte Pakete: $NUM_AUTOREMOVE\n- Snap aktualisierte Pakete: $NUM_SNAP\n\n"

    [ -n "$UPGRADE_PKGS" ] && MAIL_BODY+="=== APT: Installierte / aktualisierte Pakete ===\n$UPGRADE_PKGS\n\n"
    [ -n "$AUTOREMOVE_PKGS" ] && MAIL_BODY+="=== APT: Entfernte Pakete (autoremove) ===\n$AUTOREMOVE_PKGS\n\n"
    [ -n "$SNAP_UPGRADE_LOG" ] && MAIL_BODY+="=== Snap: Aktualisierte Pakete ===\n$SNAP_UPGRADE_LOG\n\n"
    [ -f /var/run/reboot-required.pkgs ] && MAIL_BODY+="=== Pakete, die Reboot erfordern ===\n$(cat /var/run/reboot-required.pkgs)\n\n"

    MAIL_BODY+="Viele Grüße\nDein automatisches Update-Skript"
fi

# === Mail verschicken ===
echo -e "$MAIL_BODY" \
    | mail -a "Content-Type: text/plain; charset=UTF-8" \
           -a "Content-Transfer-Encoding: 8bit" \
           -s "$MAIL_SUBJECT" root
