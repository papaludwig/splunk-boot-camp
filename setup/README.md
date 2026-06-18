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
- `--start-step 6` (resume a failed build at the Splunk download step)
- `--no-run` (copy only)

The remote build script runs non-interactively once started.

## 3) What the remote build script does
- Updates Ubuntu packages
- Creates/updates the `student` sudo user
- Enables password SSH auth via `/etc/ssh/sshd_config.d/50-splunk-training.conf`
- Installs certs with mode `600`
- Downloads and installs Splunk
- Configures `web.conf` and `server.conf` idempotently
- Starts Splunk and enables boot-start

## 4) Install Destinations samples

After SA-Eventgen is installed and the `destinations` app exists on the Splunk
instance, package the repo-owned sample files, copy them to the instance, install
the samples, and move `eventgen.conf` into `local/`:

```bash
./setup/install-destinations-samples-aws.sh --host <ec2-ip-or-dns>
```

The editable source files live under
`setup/assets/destinations-samples/samples/`. The default
`destinations-codes.sample` intentionally repeats `200` six times to weight
generated logs toward successful responses.

After it completes, install class apps/config as needed and then create the AMI.
