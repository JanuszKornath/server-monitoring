#!/bin/bash

# === Hostname für den Betreff ===
HOSTNAME=$(hostname)

# === Prüfen, ob Updates verfügbar sind ===
apt update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v Listing | wc -l)

if [ "$UPGRADABLE" -eq 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Keine Updates verfügbar"
    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} waren keine Updates verfügbar.\n\nViele Grüße\nDein automatisches Update-Skript"
else
    # Anzahl der Sicherheits- und Kernel-Updates vor Upgrade
    SECURITY_UPGRADES=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
    KERNEL_UPGRADES=$(apt list --upgradable 2>/dev/null | grep -E 'linux-image|linux-headers' | wc -l)

    # === Update & Upgrade ===
    apt -y dist-upgrade -qq
    apt -y autoremove -qq

    # === Prüfen, ob ein Reboot nötig ist ===
    if [ -f /var/run/reboot-required ]; then
        MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich nach Updates"
        REBOOT_MSG="Ein Neustart ist erforderlich, damit alle Änderungen wirksam werden."
    else
        MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
        REBOOT_MSG="Kein Neustart erforderlich."
    fi

    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} wurden Updates durchgeführt.\n\n$REBOOT_MSG\n\nUpdate-Übersicht:\n- Gesamtanzahl Upgrades: $UPGRADABLE\n- Sicherheitsupdates: $SECURITY_UPGRADES\n- Kernel-Updates: $KERNEL_UPGRADES\n\nInstallierte/aktualisierte Pakete (falls Reboot erforderlich):\n$(cat /var/run/reboot-required.pkgs 2>/dev/null)\n\nViele Grüße\nDein automatisches Update-Skript"
fi

# === Mail verschicken ===
echo -e "$MAIL_BODY" | mail -s "$MAIL_SUBJECT" root
