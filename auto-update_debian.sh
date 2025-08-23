#!/bin/bash

# === Hostname für den Betreff ===
HOSTNAME=$(hostname)

# === Prüfen, ob Updates verfügbar sind ===
apt update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v Listing | wc -l)

# === Snap-Updates prüfen ===
SNAP_UPGRADABLE=$(snap refresh --list 2>/dev/null | wc -l)

if [ "$UPGRADABLE" -eq 0 ] && [ "$SNAP_UPGRADABLE" -eq 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Keine Updates verfügbar"
    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} waren keine Updates verfügbar.\n\nViele Grüße\nDein automatisches Update-Skript"
else
    # Anzahl der Sicherheits- und Kernel-Updates vor Upgrade
    SECURITY_UPGRADES=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
    KERNEL_UPGRADES=$(apt list --upgradable 2>/dev/null | grep -E 'linux-image|linux-headers' | wc -l)

    # === Update & Upgrade ===
    apt -y dist-upgrade -qq
    apt -y autoremove -qq

    # === Snap-Pakete aktualisieren ===
    if [ "$SNAP_UPGRADABLE" -gt 0 ]; then
        snap refresh --quiet
    fi

    # === Prüfen, ob ein Reboot nötig ist ===
    if [ -f /var/run/reboot-required ]; then
        MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich nach Updates"
        REBOOT_MSG="Ein Neustart ist erforderlich, damit alle Änderungen wirksam werden."
    else
        MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
        REBOOT_MSG="Kein Neustart erforderlich."
    fi

    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} wurden Updates durchgeführt.\n\n$REBOOT_MSG\n\nUpdate-Übersicht:\n- Gesamtanzahl APT-Upgrades: $UPGRADABLE\n- Sicherheitsupdates: $SECURITY_UPGRADES\n- Kernel-Updates: $KERNEL_UPGRADES\n- Snap-Updates: $SNAP_UPGRADABLE\n\nInstallierte/aktualisierte Pakete (falls Reboot erforderlich):\n$(cat /var/run/reboot-required.pkgs 2>/dev/null)\n\nViele Grüße\nDein automatisches Update-Skript"
fi

# === Mail verschicken ===
echo -e "Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n$MAIL_BODY" \
    | mail -a "Content-Type: text/plain; charset=UTF-8" -s "$MAIL_SUBJECT" root
