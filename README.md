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
## Make script executable
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
# disk_usage.sh
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
