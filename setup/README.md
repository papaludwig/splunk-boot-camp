# Splunk Training AMI Builder (Ubuntu 24.04) — Root User + TLS on 443

This build flow produces a throwaway training AMI where:
- Splunk runs as **root** (intentional, for training only)
- Splunk Web listens on **HTTPS port 443**
- Wildcard Let’s Encrypt cert is installed
- A `student` user exists and is sudo-enabled
- SSH password and keyboard-interactive auth are enabled (applies on boot)

## Inputs (from your Mac)
You provide:
- `ib-fullchain.pem`
- `ib-privkey.pem`
- `build-splunk-training.sh` (this repo/script)
- A Splunk Enterprise `.tgz` download URL (paste into script)

You also have:
- `cpl.pem` (SSH private key used to access the instance)

---

## Preferred flow (root uploads into /root)

If your instance allows SSH as root:

```bash
scp -i cpl.pem ib-fullchain.pem ib-privkey.pem build-splunk-training.sh root@<vm-ip>:/root/
ssh -i cpl.pem root@<vm-ip>
cd /root
chmod +x build-splunk-training.sh
./build-splunk-training.sh
