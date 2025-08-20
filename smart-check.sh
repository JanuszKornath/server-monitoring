#!/bin/bash

# === Hostname für den Betreff ===
HOSTNAME=$(hostname)

# Verzeichnisse
DATA_DIR="/var/lib/smart-summary"
LOG_FILE="/var/log/smart-check.log"
mkdir -p "$DATA_DIR"

MAIL_BODY=$(mktemp)
WARN_BODY=$(mktemp)

# Nur physische Festplatten (ohne Partitions- oder Pseudo-Geräte)
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

echo "==== SMART Summary für $(hostname) - $(date) ====" | tee -a "$LOG_FILE" > "$MAIL_BODY"

CRITICAL_FOUND=0

for DISK in $DISKS; do
    DEVICE="/dev/$DISK"
    OLD_FILE="$DATA_DIR/$DISK.old"
    NEW_FILE="$DATA_DIR/$DISK.new"
    HISTORY_FILE="$DATA_DIR/$DISK.history"

    smartctl -A "$DEVICE" > "$NEW_FILE"

    REALLOC=$(awk '/Reallocated_Sector_Ct/ {print $10}' "$NEW_FILE")
    PENDING=$(awk '/Current_Pending_Sector/ {print $10}' "$NEW_FILE")
    OFFLINE=$(awk '/Offline_Uncorrectable/ {print $10}' "$NEW_FILE")
    CRC=$(awk '/UDMA_CRC_Error_Count/ {print $10}' "$NEW_FILE")

    REALLOC=${REALLOC:-0}
    PENDING=${PENDING:-0}
    OFFLINE=${OFFLINE:-0}
    CRC=${CRC:-0}

    echo -e "\nDisk: $DEVICE" | tee -a "$LOG_FILE" >> "$MAIL_BODY"
    echo -e "Reallocated_Sector_Ct: $REALLOC" >> "$MAIL_BODY"
    echo "  Erklärung: Anzahl der Sektoren, die verschoben wurden, da defekt. Frühzeitige Warnung vor Ausfall." >> "$MAIL_BODY"
    echo -e "Current_Pending_Sector: $PENDING" >> "$MAIL_BODY"
    echo "  Erklärung: Sektoren, die fehlerhaft, aber noch nicht neu zugeordnet sind. Kritisch." >> "$MAIL_BODY"
    echo -e "Offline_Uncorrectable: $OFFLINE" >> "$MAIL_BODY"
    echo "  Erklärung: Sektoren, die weder online noch offline repariert werden konnten. Kritisch." >> "$MAIL_BODY"
    echo -e "UDMA_CRC_Error_Count: $CRC" >> "$MAIL_BODY"
    echo "  Erklärung: Schnittstellen-/Kabel-/Controller-Fehler. Nicht direkt Platte." >> "$MAIL_BODY"

    echo -e "\nInterpretation:" >> "$MAIL_BODY"

    IS_CRITICAL=0
    for VAL in REALLOC PENDING OFFLINE; do
        VALUE=${!VAL}
        if [ "$VAL" == "REALLOC" ]; then NAME="Reallocated_Sector_Ct"; THRESHOLD=50
        elif [ "$VAL" == "PENDING" ]; then NAME="Current_Pending_Sector"; THRESHOLD=0
        else NAME="Offline_Uncorrectable"; THRESHOLD=0
        fi

        if [ "$VALUE" -eq 0 ]; then MSG="gut"
        elif [ "$VAL" == "REALLOC" ] && [ "$VALUE" -lt 50 ]; then MSG="beobachten"
        else MSG="kritisch"; IS_CRITICAL=1
        fi

        echo "- $NAME: $VALUE ($MSG)" >> "$MAIL_BODY"
    done

    if [ "$IS_CRITICAL" -eq 1 ]; then
        CRITICAL_FOUND=1
        echo -e "!!! WARNUNG: Festplatte $DEVICE zeigt kritische Werte!!!" >> "$MAIL_BODY"
        echo -e "Disk: $DEVICE\nReallocated_Sector_Ct: $REALLOC\nCurrent_Pending_Sector: $PENDING\nOffline_Uncorrectable: $OFFLINE\nUDMA_CRC_Error_Count: $CRC\n!!! Sofort prüfen!!!\n" >> "$WARN_BODY"
    else
        echo "Status: Alles in Ordnung." >> "$MAIL_BODY"
    fi

    echo "$(date +%F) $REALLOC $PENDING $OFFLINE" >> "$HISTORY_FILE"
    tail -n 7 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    # ASCII-Trenddiagramm
    echo -e "\nHistorie & Trend (letzte 7 Läufe, ASCII-Diagramm): Datum R P O" >> "$MAIL_BODY"
    echo "  Erklärung: R = Reallocated_Sector_Ct, P = Current_Pending_Sector, O = Offline_Uncorrectable" >> "$MAIL_BODY"

    MAX_REALLOC=$(awk '{if($2>max) max=$2} END{print max}' "$HISTORY_FILE")
    MAX_PENDING=$(awk '{if($3>max) max=$3} END{print max}' "$HISTORY_FILE")
    MAX_OFFLINE=$(awk '{if($4>max) max=$4} END{print max}' "$HISTORY_FILE")

    awk -v maxr="$MAX_REALLOC" -v maxp="$MAX_PENDING" -v maxo="$MAX_OFFLINE" '
    {
        date=$1; realloc=$2; pending=$3; offline=$4
        max_bar=20
        rbar=(maxr>0?int(realloc/maxr*max_bar+0.5):0)
        pbar=(maxp>0?int(pending/maxp*max_bar+0.5):0)
        obar=(maxo>0?int(offline/maxo*max_bar+0.5):0)
        printf "%s R:[%-*s] P:[%-*s] O:[%-*s]\n", date, max_bar, substr("####################",1,rbar) substr("--------------------",1,max_bar-rbar), max_bar, substr("####################",1,pbar) substr("--------------------",1,max_bar-pbar), max_bar, substr("####################",1,obar) substr("--------------------",1,max_bar-obar)
    }' "$HISTORY_FILE" >> "$MAIL_BODY"

    mv "$NEW_FILE" "$OLD_FILE"
    echo "-------------------------------------------------" >> "$MAIL_BODY"
done

# Zusammenfassung-Mail
mail -a "Content-Type: text/plain; charset=UTF-8" -s "[$HOSTNAME] SMART-Report" root < "$MAIL_BODY"

# Warn-Mail bei kritischen Werten
if [ "$CRITICAL_FOUND" -eq 1 ]; then
    mail -a "Content-Type: text/plain; charset=UTF-8" -s "[$HOSTNAME] !!! KRITISCHE SMART WARNUNG !!!" root < "$WARN_BODY"
fi

rm "$MAIL_BODY" "$WARN_BODY"
