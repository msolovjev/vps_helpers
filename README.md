# vps_helpers

Small helper scripts for setting up a VPS.

## change_default_ssh_port.sh

Moves the OpenSSH server on **Debian 13 (trixie)** from the default port 22 to a port you choose. It checks that port 22 is closed afterwards and rolls back automatically unless you confirm that a new connection works.

### Usage

Run as root on the VPS, replacing `2222` with your port:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/msolovjev/vps_helpers/main/change_default_ssh_port.sh)" _ 2222
```

As a non-root user with sudo:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/msolovjev/vps_helpers/main/change_default_ssh_port.sh)" _ 2222
```

The `_` is needed because `bash -c` takes the first word after the script as the script's name (`$0`). The script also accepts the port as `-2222` or `--port=2222`, and it works if you leave out the `_`.

Or download it first and read it before running:

```bash
curl -fsSLO https://raw.githubusercontent.com/msolovjev/vps_helpers/main/change_default_ssh_port.sh
less change_default_ssh_port.sh
sudo bash change_default_ssh_port.sh 2222
```

### What it does

1. Backs up `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/` to `/root/ssh-port-backup-<timestamp>/`.
2. Comments out every existing `Port` line (they add up, so a leftover `Port 22` would keep 22 open) and writes `Port <new>` to `/etc/ssh/sshd_config.d/00-ssh-port.conf`.
3. Validates the config with `sshd -t` and confirms sshd will use only the new port.
4. If they are present:
   - opens the new port in **ufw** or **firewalld**;
   - points the **fail2ban** `sshd` jail at the new port;
   - updates **ssh.socket** (socket activation).
5. Restarts SSH. Your current session stays connected.
6. Checks that the new port answers with an SSH banner and that **port 22 is closed**: nothing listens on it and connections are refused.
7. Shows a warning not to close the current session and prints the exact `ssh -p <port> user@ip` command to test in a **new** terminal.
8. Waits for you to type `yes`. If you type `no`, press Ctrl+C, lose the session, or don't answer within 300 seconds, it **rolls back** to the previous configuration on port 22.

### Before you run it

- If your VPS provider has its own firewall or security group in the control panel, allow the new TCP port there. The script can't do this for you.
- Change the confirmation time with `CONFIRM_TIMEOUT`, for example:

  ```bash
  CONFIRM_TIMEOUT=600 bash -c "$(curl -fsSL https://raw.githubusercontent.com/msolovjev/vps_helpers/main/change_default_ssh_port.sh)" _ 2222
  ```

### After it finishes

- Connect with `ssh -p 2222 user@your-server`, or add this to `~/.ssh/config` on your computer:

  ```
  Host myvps
      HostName your-server-ip
      Port 2222
  ```

- From your computer, check that 22 is closed from the outside: `nc -zv your-server-ip 22`.
- If ufw still has a rule for port 22, it is harmless because nothing listens there. Remove it with `ufw delete allow 22/tcp` (or `ufw delete allow OpenSSH`).

### Manual rollback

The backup folder is printed at the end. To restore it by hand:

```bash
B=/root/ssh-port-backup-YYYYMMDD-HHMMSS
cp -a $B/sshd_config /etc/ssh/sshd_config
rm -rf /etc/ssh/sshd_config.d && cp -a $B/sshd_config.d /etc/ssh/
rm -f /etc/systemd/system/ssh.socket.d/zz-ssh-port.conf /etc/fail2ban/jail.d/zz-sshd-port.local
systemctl daemon-reload && systemctl restart ssh   # or: systemctl restart ssh.socket
```
