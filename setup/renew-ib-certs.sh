sudo env AWS_PROFILE=default .certbot-env/bin/certbot renew --cert-name instantbrains.com
sudo cp /etc/letsencrypt/live/instantbrains.com/fullchain.pem  ~/ib-fullchain.pem
sudo cp /etc/letsencrypt/live/instantbrains.com/privkey.pem     ~/ib-privkey.pem
sudo chmod 600 ~/ib-*.pem
