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

Installs APT, Snap and Docker updates and reports by mail to `root` what was
installed. The mail is only sent when something actually happened or a reboot
is pending — a run without updates stays silent.

For Docker the script looks up to three levels below `DOCKER_DIR` for
`docker-compose.yml`, pulls the images and restarts the stacks. Only what was
really recreated is counted.

## Configure

To adjust in the script:

```
DOCKER_DIR="/srv/docker"      # path to the Docker projects
```

If `/var/run/reboot-required` exists, the mail also points out the pending
reboot. The reboot itself is not performed.

## Make script executable

In this repository the script is named `auto-update_debian.sh`; under
`/usr/local/bin` it is deployed as `auto-update.sh`.

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

Every output line is prefixed by the script itself with a timestamp in the
format `[YYYY-MM-DD HH:MM:SS]`, so the log file stays readable across runs.
Nothing further is needed in the crontab.

# disk_usage.sh

Checks the usage of all mount points and sends a mail as soon as one exceeds
the threshold. The mount points are determined via `df`; `tmpfs`, `udev`,
`overlay` and `loop` are left out.

Every run is logged, even when no mail was necessary — the log file is
therefore a continuous record of usage, not just an error log.

Mail is sent through `sendmail -t` and retried on failure.

## Configure

To adjust in the script:

```
THRESHOLD=90                         # threshold in percent
EMAIL="root"                         # recipient, forwarded via /etc/aliases
LOGFILE="/var/log/disk_usage.log"
MAX_RETRIES=3                        # send attempts
RETRY_INTERVAL=60                    # seconds between attempts

WHITELIST=("/" "/boot" "/var")       # always monitored, if present
BLACKLIST=("/snap" "/run" "/tmp" "/etc/pve" "/sys/firmware/efi/efivars")    # never monitored
```

The blacklist beats the whitelist: a mount point listed in both is not
monitored.

`/etc/pve` (the Proxmox VE cluster filesystem, a FUSE mount) and
`/sys/firmware/efi/efivars` (UEFI NVRAM, an efivarfs mount) are excluded by
default: neither reports a meaningful capacity, so their usage percentage is
not an actionable signal.

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

Scans the rsnapshot log for `ERROR` lines and sends a mail when it finds any.
Only what is new **since the last run** is reported, so a one-off error lands
in the mailbox exactly once instead of again on every following run.

The backup level (`ALPHA`, `BETA`, …) is taken from the last `started` line of
the log and appears in the subject; if it cannot be determined it reads
`UNKNOWN`. The mail also carries the last 20 log lines.

If the log does not exist, the script exits silently.

## Configure

To adjust in the script:

```
LOG_FILE="/var/log/rsnapshot.log"
STATEFILE="/var/tmp/rsnapshot_check.state"
EMAIL="root"                          # forwarded via /etc/aliases
```

## Make script executable

```
chmod +x /usr/local/bin/rsnapshot-error-mail.sh
```

## Implement cronjob

The job belongs **after** the rsnapshot run, otherwise it inspects the log
before the backup has written to it.

```
sudo crontab -e
```
```
MAILTO=""
#rsnapshot-Log auf Fehler prüfen
30 3 * * * /usr/local/bin/rsnapshot-error-mail.sh
```

Progress is tracked by position in the log: the state file records up to which
line the log was read, plus a checksum of exactly that line. If something else
is found there on the next run, the log was rotated and it is read from the
start. Every log line is therefore examined exactly once — there is no window
boundary an error could fall between.

The first run after the switch from the earlier timestamp-based state file
reports the errors currently in the log once.

The state file lives under `/var/tmp`. If the system cleans out `/var/tmp` the
marker is lost and the next run reports all errors in the log again. To avoid
that, move `STATEFILE` to `/var/lib`.

Not covered: errors written after the last check and rotated away before the
next one are no longer in the current log. The check job should therefore sit
closer in time to the backup than to the log rotation.

# smart-check.sh

Reads the SMART values of all disks and sends an HTML report to `root`. The
subject reflects the finding, so a failing disk does not look like an ordinary
daily report in the inbox.

## Install smartmontools

```
sudo apt install smartmontools -y
```

## Make script executable

```
chmod +x /usr/local/bin/smart-check.sh
```

## Implement cronjob

The script needs root privileges, otherwise `smartctl` reads nothing. The
cronjob therefore belongs in root's crontab.

```
sudo crontab -e
```
```
MAILTO=""
#SMART-Werte der Platten prüfen
0 6 * * * /usr/local/bin/smart-check.sh
```

A **daily** run is the assumption the assessment is built on: the history
window spans 7 runs, so one week, and the persistence rule takes effect after
3 runs, so three days. Checking less often stretches these periods
accordingly.

## Assessment

The status names below are the literal values the script writes into the mail.

| Attribute | WARNUNG | KRITISCH |
|---|---|---|
| SMART overall-health | – | `FAILED` |
| `Reallocated_Sector_Ct` (5) | from 1 | above 50, or growth of 10 or more within the window |
| `Current_Pending_Sector` (197) | from 1 | above 10, or above 0 in 3 consecutive runs |
| `Offline_Uncorrectable` (198) | from 1 | above 10, or above 0 in 3 consecutive runs |
| `Reported_Uncorrect` (187) | from 1 | above 10, or growth of 5 or more within the window |
| `Command_Timeout` (188) | from 1 | above 10, or growth of 5 or more within the window |
| `UDMA_CRC_Error_Count` (199) | growth since the last run | never |

`KRITISCH` means "replace the disk", `WARNUNG` means "keep an eye on it". A
single pending sector often disappears by itself once the sector is written to
again — it only becomes critical when it stays, or when many accumulate.

`UDMA_CRC_Error_Count` does not count media errors but transfer errors on the
SATA bus: cable, connector, backplane. The remedy is reseating, not replacing.
The counter is never reset, which is why only growth warns; an old, unchanged
value appears as a mere notice.

On a critical finding the mail additionally carries `X-Priority: 1` and
`Importance: High`.

## Critical latch

A finding that was once critical stays critical until it is demonstrably
resolved. Without that, a disk would become unremarkable again merely because
the triggering growth scrolled out of the history window.

The latch is lifted in three ways:

1. **Replacement.** History and latch are keyed by serial number, not by
   kernel name. A new disk therefore starts with a clean state.
2. **Values back to normal.** Once all triggering attributes read 0 for 3
   consecutive runs, the latch lifts itself. Monotonic counters such as
   `Reallocated_Sector_Ct` never reach 0 again — those latches deliberately do
   not expire on their own.
3. **Acknowledgement** after a repair, see below.

```
sudo /usr/local/bin/smart-check.sh --status            # show latches in place
sudo /usr/local/bin/smart-check.sh --clear /dev/sda    # after replacement or repair
sudo /usr/local/bin/smart-check.sh --clear-all
sudo /usr/local/bin/smart-check.sh --help
```

`--clear` also accepts the kernel name (`sda`) or the serial number, and finds
an already removed disk through the stored serial. It is not a mute switch: if
the values are still critical, the next run sets the latch again right away.

## Data directory

History and latches live under `/var/lib/smart-summary`, per disk as
`<serial>.history` and `<serial>.state`. The directory is created on the first
run. State files of removed disks stay behind and can be deleted by hand when
no longer wanted.
