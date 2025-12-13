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
