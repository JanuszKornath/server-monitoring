#!/bin/bash

HOSTNAME=$(hostname)
DATA_DIR="/var/lib/smart-summary"
LOG_FILE="/var/log/smart-check.log"
mkdir -p "$DATA_DIR"

MAIL_BODY=$(mktemp)
WARN_BODY=$(mktemp)

DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

CRITICAL_FOUND=0

# Header für HTML-Mail
echo "<html><body style='font-family: Arial, sans-serif;'>" > "$MAIL_BODY"
echo "<h2 style='color:blue;'>SMART Summary für $HOSTNAME – $(date)</h2>" >> "$MAIL_BODY"

echo "<html><body style='font-family: Arial, sans-serif;'>" > "$WARN_BODY"

for DISK in $DISKS; do
    DEVICE="/dev/$DISK"
    OLD_FILE="$DATA_DIR/$DISK.old"
    NEW_FILE="$DATA_DIR/$DISK.new"
    HISTORY_FILE="$DATA_DIR/$DISK.history"

    smartctl -A "$DEVICE" > "$NEW_FILE"

    MANUFACTURER=$(smartctl -i "$DEVICE" | awk -F': +' '/Model Family/ {print $2}')
    MODEL=$(smartctl -i "$DEVICE" | awk -F': +' '/Device Model/ {print $2}')
    POWER_ON_HOURS=$(awk '/Power_On_Hours/ {print $10}' "$NEW_FILE")

    MANUFACTURER=${MANUFACTURER:-"Unbekannt"}
    MODEL=${MODEL:-"Unbekannt"}
    POWER_ON_HOURS=${POWER_ON_HOURS:-0}

    REALLOC=$(awk '/Reallocated_Sector_Ct/ {print $10}' "$NEW_FILE")
    PENDING=$(awk '/Current_Pending_Sector/ {print $10}' "$NEW_FILE")
    OFFLINE=$(awk '/Offline_Uncorrectable/ {print $10}' "$NEW_FILE")
    CRC=$(awk '/UDMA_CRC_Error_Count/ {print $10}' "$NEW_FILE")

    REALLOC=${REALLOC:-0}
    PENDING=${PENDING:-0}
    OFFLINE=${OFFLINE:-0}
    CRC=${CRC:-0}

    echo "<h3>Disk: $DEVICE</h3>" >> "$MAIL_BODY"
    echo "<p><b>Hersteller:</b> $MANUFACTURER<br><b>Modell:</b> $MODEL<br><b>Laufzeit (Stunden):</b> $POWER_ON_HOURS</p>" >> "$MAIL_BODY"

    echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse;'>" >> "$MAIL_BODY"
    echo "<tr><th>Attribut</th><th>Wert</th><th>Bewertung</th></tr>" >> "$MAIL_BODY"

    IS_CRITICAL=0
    for VAL in REALLOC PENDING OFFLINE CRC; do
        VALUE=${!VAL}
        if [ "$VAL" == "REALLOC" ]; then NAME="Reallocated_Sector_Ct"; THRESHOLD=50
        elif [ "$VAL" == "PENDING" ]; then NAME="Current_Pending_Sector"; THRESHOLD=0
        elif [ "$VAL" == "OFFLINE" ]; then NAME="Offline_Uncorrectable"; THRESHOLD=0
        else NAME="UDMA_CRC_Error_Count"; THRESHOLD=100
        fi

        if [ "$VALUE" -eq 0 ]; then MSG="gut"; COLOR="green"
        elif [ "$VAL" == "REALLOC" ] && [ "$VALUE" -lt 50 ]; then MSG="beobachten"; COLOR="orange"
        elif [ "$VAL" == "CRC" ] && [ "$VALUE" -lt 100 ]; then MSG="beobachten"; COLOR="orange"
        else MSG="kritisch"; COLOR="red"; IS_CRITICAL=1
        fi

        echo "<tr><td>$NAME</td><td>$VALUE</td><td style='color:$COLOR;font-weight:bold;'>$MSG</td></tr>" >> "$MAIL_BODY"

        if [ "$IS_CRITICAL" -eq 1 ]; then
            # Auch für Warn-Mail
            echo "<h3 style='color:red;'>Kritische SMART-Warnung: $DEVICE</h3>" >> "$WARN_BODY"
            echo "<p><b>Hersteller:</b> $MANUFACTURER<br><b>Modell:</b> $MODEL<br><b>Laufzeit (Stunden):</b> $POWER_ON_HOURS</p>" >> "$WARN_BODY"
            echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse;'>" >> "$WARN_BODY"
            echo "<tr><th>Attribut</th><th>Wert</th></tr>" >> "$WARN_BODY"
            echo "<tr><td>Reallocated_Sector_Ct</td><td>$REALLOC</td></tr>" >> "$WARN_BODY"
            echo "<tr><td>Current_Pending_Sector</td><td>$PENDING</td></tr>" >> "$WARN_BODY"
            echo "<tr><td>Offline_Uncorrectable</td><td>$OFFLINE</td></tr>" >> "$WARN_BODY"
            echo "<tr><td>UDMA_CRC_Error_Count</td><td>$CRC</td></tr>" >> "$WARN_BODY"
            echo "</table>" >> "$WARN_BODY"
            echo "<p style='color:red;font-weight:bold;'>!!! Sofort prüfen !!!</p><hr>" >> "$WARN_BODY"
        fi
    done

    echo "</table>" >> "$MAIL_BODY"

    # Verlauf
    echo "<pre style='background:#f4f4f4; padding:6px;'>" >> "$MAIL_BODY"
    echo "Historie & Trend (letzte 7 Läufe):" >> "$MAIL_BODY"
    awk '{printf "%s  R:%s  P:%s  O:%s\n",$1,$2,$3,$4}' "$HISTORY_FILE" >> "$MAIL_BODY"
    echo "</pre><hr>" >> "$MAIL_BODY"

    mv "$NEW_FILE" "$OLD_FILE"
done

# HTML-Footer
echo "</body></html>" >> "$MAIL_BODY"
echo "</body></html>" >> "$WARN_BODY"

# Versand
mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" \
     -s "[$HOSTNAME] SMART-Report" root < "$MAIL_BODY"

if [ "$CRITICAL_FOUND" -eq 1 ]; then
    mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" \
         -s "[$HOSTNAME] !!! KRITISCHE SMART WARNUNG !!!" root < "$WARN_BODY"
fi

rm "$MAIL_BODY" "$WARN_BODY"
