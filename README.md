# Useful beforehand
## Install Midnight Commander

```
sudo apt install mc
```

## Configure Postfix
### Install Postfix
```
sudo apt update
sudo apt install postfix mailutils libsasl2-modules -y
```
```
sudo nano /etc/postfix/main.cf
# gmail
relayhost = [smtp.gmail.com]:587

smtp_use_tls = yes
smtp_tls_security_level = encrypt
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
```
```
sudo nano /etc/postfix/sasl_passwd
[smtp.gmail.com]:587 smth@gmail.com:APP_PASSWORD
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo systemctl restart postfix
sudo systemctl status postfix
```

### Set alias for root
```
sudo nano /etc/aliases
sudo newaliases
```

# auto-update_debian.sh

Spielt APT-, Snap- und Docker-Updates ein und meldet per Mail an `root`, was
installiert wurde. Die Mail geht nur raus, wenn tatsächlich etwas passiert ist
oder ein Neustart aussteht — ein Lauf ohne Updates bleibt still.

Für Docker sucht das Skript bis drei Ebenen tief unterhalb von `DOCKER_DIR`
nach `docker-compose.yml`, zieht die Images und startet die Stacks neu. Gezählt
wird nur, was dabei wirklich neu erstellt wurde.

## Configure

Im Skript anzupassen:

```
DOCKER_DIR="/srv/docker"      # Pfad zu den Docker-Projekten
```

Steht `/var/run/reboot-required`, weist die Mail zusätzlich auf den nötigen
Neustart hin. Der Neustart selbst wird nicht ausgeführt.

## Make script executable

Im Repo heißt das Skript `auto-update_debian.sh`, unter `/usr/local/bin` wird
es hier als `auto-update.sh` abgelegt.

```
chmod +x /usr/local/bin/auto-update.sh
```
## Implement cronjob
```
sudo crontab -e
```
```
MAILTO=""
#Serverupdates machen
0 15 */4 * * /usr/local/bin/auto-update.sh >> /var/log/auto-update.log 2>&1
```

Jede Ausgabezeile wird vom Skript selbst mit einem Zeitstempel im Format
`[YYYY-MM-DD HH:MM:SS]` versehen, damit die Logdatei über mehrere Läufe hinweg
lesbar bleibt. Dafür ist in der Crontab nichts weiter nötig.
# disk_usage.sh

Prüft die Belegung aller Mountpoints und schickt eine Mail, sobald einer den
Schwellwert überschreitet. Die Mountpoints werden per `df` selbst ermittelt,
`tmpfs`, `udev`, `overlay` und `loop` bleiben außen vor.

Jeder Lauf wird protokolliert, auch wenn keine Mail nötig war — die Logdatei
ist damit ein durchgehender Verlauf der Belegung, nicht nur ein Fehlerlog.

Der Versand läuft über `sendmail -t` und wird bei Fehlschlag wiederholt.

## Configure

Im Skript anzupassen:

```
THRESHOLD=90                         # Schwellwert in Prozent
EMAIL="root"                         # Empfänger, Weiterleitung über /etc/aliases
LOGFILE="/var/log/disk_usage.log"
MAX_RETRIES=3                        # Sendeversuche
RETRY_INTERVAL=60                    # Sekunden zwischen den Versuchen

WHITELIST=("/" "/boot" "/var")       # wird immer überwacht, wenn vorhanden
BLACKLIST=("/snap" "/run" "/tmp")    # wird nie überwacht
```

Die Blacklist sticht die Whitelist: ein Mountpoint, der in beiden steht, wird
nicht überwacht.

## Make script executable
```
chmod +x /usr/local/bin/disk_usage.sh
```
## Implement cronjob
```
sudo crontab -e
```
```
MAILTO=""
#Auslastung der Festplatten messen
30 4 * * * /usr/local/bin/disk_usage.sh 2>&1
```

## Set logrotation

```
sudo nano /etc/logrotate.d/disk_usage
```
```
/var/log/disk_usage.log {
    weekly
    rotate 5
    size 1M
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
```

# rsnapshot-error-mail.sh

Durchsucht das rsnapshot-Log nach `ERROR`-Zeilen und schickt eine Mail, wenn
welche gefunden werden. Gemeldet wird nur, was **seit dem letzten Lauf** neu
hinzugekommen ist — dafür merkt sich das Skript in einer Zustandsdatei, bis
wann es zuletzt geschaut hat. Ein einmaliger Fehler landet dadurch genau einmal
im Postfach und nicht bei jedem weiteren Lauf erneut.

Das Backup-Level (`ALPHA`, `BETA`, …) wird aus der letzten `started`-Zeile des
Logs ermittelt und steht im Betreff. Ist es nicht ermittelbar, steht dort
`UNKNOWN`. Der Mail liegen zusätzlich die letzten 20 Logzeilen bei.

Existiert das Log nicht, endet das Skript kommentarlos.

## Configure

Im Skript anzupassen:

```
LOG_FILE="/var/log/rsnapshot.log"
STATEFILE="/var/tmp/rsnapshot_check.state"
EMAIL="root"                          # Weiterleitung über /etc/aliases
```

## Make script executable

```
chmod +x /usr/local/bin/rsnapshot-error-mail.sh
```

## Implement cronjob

Der Job gehört zeitlich **hinter** den rsnapshot-Lauf, sonst prüft er das Log,
bevor das Backup hineingeschrieben hat.

```
sudo crontab -e
```
```
MAILTO=""
#rsnapshot-Log auf Fehler prüfen
30 3 * * * /usr/local/bin/rsnapshot-error-mail.sh
```

Die Zustandsdatei liegt unter `/var/tmp`. Räumt das System `/var/tmp` auf, geht
der Merker verloren und der nächste Lauf meldet alle Fehler aus dem Log erneut.
Wer das vermeiden will, legt `STATEFILE` nach `/var/lib`.

# smart-check.sh

Liest die SMART-Werte aller Platten aus und schickt einen HTML-Report an `root`.
Der Betreff richtet sich nach dem Befund, damit eine ausfallende Platte im
Posteingang nicht wie ein normaler Tagesreport aussieht.

## Install smartmontools

```
sudo apt install smartmontools -y
```

## Make script executable

```
chmod +x /usr/local/bin/smart-check.sh
```

## Implement cronjob

Das Skript braucht Root-Rechte, `smartctl` liest sonst nichts aus. Der Cronjob
gehört deshalb in die Root-Crontab.

```
sudo crontab -e
```
```
MAILTO=""
#SMART-Werte der Platten prüfen
0 6 * * * /usr/local/bin/smart-check.sh
```

Ein **täglicher** Lauf ist die Annahme, auf der die Bewertung aufbaut: das
Historien-Fenster umfasst 7 Läufe, entspricht also einer Woche, und die
Persistenz-Regel greift nach 3 Läufen, also nach 3 Tagen. Wer seltener prüft,
dehnt diese Zeiträume entsprechend.

## Bewertung

| Attribut | WARNUNG | KRITISCH |
|---|---|---|
| SMART overall-health | – | `FAILED` |
| `Reallocated_Sector_Ct` (5) | ab 1 | über 50 oder Zuwachs ab 10 im Fenster |
| `Current_Pending_Sector` (197) | ab 1 | über 10 oder 3 Läufe in Folge über 0 |
| `Offline_Uncorrectable` (198) | ab 1 | über 10 oder 3 Läufe in Folge über 0 |
| `Reported_Uncorrect` (187) | ab 1 | über 10 oder Zuwachs ab 5 im Fenster |
| `Command_Timeout` (188) | ab 1 | über 10 oder Zuwachs ab 5 im Fenster |
| `UDMA_CRC_Error_Count` (199) | Zuwachs seit letztem Lauf | nie |

`KRITISCH` bedeutet „Platte tauschen", `WARNUNG` bedeutet „beobachten". Ein
einzelner Pending Sector verschwindet oft von selbst wieder, sobald erneut auf
den Sektor geschrieben wird — kritisch wird er erst, wenn er bleibt oder viele
werden.

`UDMA_CRC_Error_Count` zählt keine Medienfehler, sondern Übertragungsfehler auf
dem SATA-Bus: Kabel, Stecker, Backplane. Die Abhilfe ist umstecken, nicht
tauschen. Der Zähler wird nie zurückgesetzt, deshalb warnt nur ein Zuwachs; ein
alter, unveränderter Stand erscheint als bloßer Hinweis.

Bei kritischem Befund bekommt die Mail zusätzlich `X-Priority: 1` und
`Importance: High`.

## Kritisch-Marker

Ein einmal kritischer Befund bleibt kritisch, bis er nachweislich erledigt ist.
Ohne das würde eine Platte allein dadurch wieder unauffällig, dass der
auslösende Zuwachs aus dem Historien-Fenster rutscht.

Aufgehoben wird der Marker auf drei Wegen:

1. **Tausch.** Historie und Marker hängen an der Seriennummer, nicht am
   Kernel-Namen. Eine neue Platte startet dadurch mit sauberem Zustand.
2. **Wert wieder in Ordnung.** Stehen alle auslösenden Attribute 3 Läufe in
   Folge wieder auf 0, hebt sich der Marker selbst auf. Monotone Zähler wie
   `Reallocated_Sector_Ct` erreichen die 0 nie wieder — solche Marker laufen
   bewusst nicht von allein aus.
3. **Quittierung** nach einer Reparatur, siehe unten.

```
sudo /usr/local/bin/smart-check.sh --status            # gesetzte Marker anzeigen
sudo /usr/local/bin/smart-check.sh --clear /dev/sda    # nach Tausch oder Reparatur
sudo /usr/local/bin/smart-check.sh --clear-all
sudo /usr/local/bin/smart-check.sh --help
```

`--clear` nimmt auch den Kernel-Namen (`sda`) oder die Seriennummer und findet
eine bereits ausgebaute Platte über die gespeicherte Seriennummer. Es ist keine
Stummschaltung: sind die Werte weiterhin kritisch, setzt der nächste Lauf den
Marker sofort neu.

## Datenverzeichnis

Historie und Marker liegen unter `/var/lib/smart-summary`, je Platte
`<seriennummer>.history` und `<seriennummer>.state`. Das Verzeichnis wird beim
ersten Lauf angelegt. Zustandsdateien ausgebauter Platten bleiben liegen und
können bei Bedarf von Hand entfernt werden.
