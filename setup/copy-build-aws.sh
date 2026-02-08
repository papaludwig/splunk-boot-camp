scp -i ~/Downloads/cpl.pem ~/ib-fullchain.pem ~/ib-privkey.pem build-splunk-training.sh ubuntu@<vm-ip>:/tmp/
ssh -i ~/Downloads/cpl.pem ubuntu@<vm-ip> "sudo mv /tmp/{ib-fullchain.pem,ib-privkey.pem,build-splunk-training.sh} /root/"
ssh -i ~/Downloads/cpl.pem ubuntu@<vm-ip>
sudo su -
cd /root
chmod +x build-splunk-training.sh
./build-splunk-training.sh
