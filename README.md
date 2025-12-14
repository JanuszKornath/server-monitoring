Install Midnight Commander

sudo apt install mc

Configure Postfix

sudo apt update
sudo apt install postfix mailutils libsasl2-modules -y
sudo nano /etc/postfix/main.cf
sudo nano /etc/postfix/sasl_passwd
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd

alis für root setzen
sudo nano /etc/aliases
sudo newaliases

cronjobs
sudo crontab -e
MAILTO=""
#Serverupdates machen
0 15 */4 * * /usr/local/bin/auto-update.sh >> /var/log/auto-update.log 2>&1

#Auslastung der Festplatten messen
30 4 * * * /usr/local/bin/disk_usage.sh 2>&1

Set logrotations for scripts

sudo nano /etc/logrotate.d/disk_usage
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
