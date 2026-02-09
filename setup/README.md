# Splunk Training AMI Builder (Ubuntu 24.04)

This setup flow produces a training AMI where:
- Splunk runs as `root` (intentional for class labs)
- Splunk Web listens on HTTPS `443`
- Let's Encrypt certs are installed under `/etc/ssl/instantbrains`
- A sudo-enabled `student` user exists
- SSH password + keyboard-interactive auth are enabled

## Mac-side prerequisites
- SSH private key for the EC2 instance (default: `~/Downloads/cpl.pem`)
- Certbot environment on your Mac (`~/.certbot-env/bin/certbot`)
- Existing cert name in Let's Encrypt (default: `instantbrains.com`)
- Splunk Enterprise `.tgz` direct download URL

## 1) Renew and export certs on Mac

```bash
./setup/renew-ib-certs.sh
```

Optional flags:
- `--cert-name`
- `--aws-profile`
- `--certbot-bin`
- `--output-dir`

By default this writes:
- `~/ib-fullchain.pem`
- `~/ib-privkey.pem`

## 2) Copy to EC2 and run build in one command

```bash
./setup/copy-build-aws.sh \
  --host <ec2-ip-or-dns> \
  --splunk-url "https://download.splunk.com/..."
```

Useful optional flags:
- `--ssh-user ubuntu`
- `--ssh-key ~/Downloads/cpl.pem`
- `--server-name instantbrains.com`
- `--web-port 443`
- `--student-user student`
- `--student-password '<lab-password>'`
- `--admin-password '<splunk-admin-password>'`
- `--no-run` (copy only)

If `--admin-password` is omitted, the local wrapper prompts and confirms it before connecting.
If `--student-password` is omitted, the local wrapper prompts and confirms it before connecting.
The remote build script runs non-interactively once started.

## 3) What the remote build script does
- Updates Ubuntu packages
- Creates/updates the `student` sudo user
- Enables password SSH auth via `/etc/ssh/sshd_config.d/99-splunk-training.conf`
- Installs certs with mode `600`
- Downloads and installs Splunk
- Configures `web.conf` and `server.conf` idempotently
- Starts Splunk and enables boot-start

After it completes, install class apps/config as needed and then create the AMI.
