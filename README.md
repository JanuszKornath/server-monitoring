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
sudo nano /etc/postfix/main.cf
```
```
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
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
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
