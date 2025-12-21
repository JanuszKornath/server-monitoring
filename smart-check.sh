#!/bin/bash

HOSTNAME=$(hostname)
DATA_DIR="/var/lib/smart-summary"
mkdir -p "$DATA_DIR"

MAIL_BODY=$(mktemp)
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

# Header für HTML-Mail
echo "<html><body style='font-family: Arial, sans-serif;'>" > "$MAIL_BODY"
echo "<h2 style='color:#2c3e50;'>SMART Summary für $HOSTNAME – $(date)</h2>" >> "$MAIL_BODY"

for DISK in $DISKS; do
    DEVICE="/dev/$DISK"
    
    # Vollständige Info und Attribute in Variablen laden
    SMART_INFO=$(smartctl -i "$DEVICE")
    SMART_ATTRS=$(smartctl -A "$DEVICE")

    # Hersteller und Modell zuverlässiger extrahieren
    MANUFACTURER=$(echo "$SMART_INFO" | grep -Ei "Model Family|Vendor" | awk -F': +' '{print $2}')
    MODEL=$(echo "$SMART_INFO" | grep -Ei "Device Model|Product" | awk -F': +' '{print $2}')
    [ -z "$MODEL" ] && MODEL=$(echo "$SMART_INFO" | grep "Model Number" | awk -F': +' '{print $2}')

    # Power On Hours extrahieren (SATA & NVMe Support)
    POWER_ON_HOURS=$(echo "$SMART_ATTRS" | grep -Ei "Power_On_Hours|Power On Hours" | awk '{print $NF}')

    # Standardwerte setzen
    MANUFACTURER=${MANUFACTURER:-"Unbekannt"}
    MODEL=${MODEL:-"Unbekannt"}
    POWER_ON_HOURS=${POWER_ON_HOURS:-0}

    # Attribute extrahieren (wir suchen gezielt nach der ID oder dem Namen und nehmen die letzte Spalte)
    get_val() {
        echo "$SMART_ATTRS" | grep -i "$1" | awk '{print $NF}' | head -n1
    }

    REALLOC=$(get_val "Reallocated_Sector_Ct")
    PENDING=$(get_val "Current_Pending_Sector")
    OFFLINE=$(get_val "Offline_Uncorrectable")
    CRC=$(get_val "UDMA_CRC_Error_Count")

    # Falls leer (z.B. bei NVMe), auf 0 setzen
    REALLOC=${REALLOC:-0}
    PENDING=${PENDING:-0}
    OFFLINE=${OFFLINE:-0}
    CRC=${CRC:-0}

    # HTML Output für diese Disk
    echo "<div style='margin-bottom: 20px; border: 1px solid #ccc; padding: 10px;'>" >> "$MAIL_BODY"
    echo "<h3 style='margin-top:0;'>Disk: $DEVICE</h3>" >> "$MAIL_BODY"
    echo "<p><b>Modell:</b> $MANUFACTURER $MODEL<br><b>Laufzeit:</b> $POWER_ON_HOURS Stunden</p>" >> "$MAIL_BODY"

    echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse; width:100%;'>" >> "$MAIL_BODY"
    echo "<tr style='background:#eee;'><th>Attribut</th><th>Wert</th><th>Status</th></tr>" >> "$MAIL_BODY"

    # Logik-Check und Tabellenzeilen
    for ITEM in "Reallocated_Sectors:$REALLOC:50" "Pending_Sectors:$PENDING:0" "Offline_Uncorrectable:$OFFLINE:0" "UDMA_CRC_Errors:$CRC:100"; do
        IFS=":" read -r NAME VALUE THRESH <<< "$ITEM"
        COLOR="green"; MSG="OK"
        
        if [ "$VALUE" -gt "$THRESH" ]; then
            COLOR="red"; MSG="KRITISCH"
        elif [ "$VALUE" -gt 0 ]; then
            COLOR="orange"; MSG="WARNUNG"
        fi

        echo "<tr><td>$NAME</td><td>$VALUE</td><td style='color:$COLOR; font-weight:bold;'>$MSG</td></tr>" >> "$MAIL_BODY"
    done

    echo "</table></div>" >> "$MAIL_BODY"
done

echo "</body></html>" >> "$MAIL_BODY"

# Versand
mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" \
     -s "[$HOSTNAME] SMART-Report" root < "$MAIL_BODY"

rm "$MAIL_BODY"
