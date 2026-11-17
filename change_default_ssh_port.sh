#!/usr/bin/env bash
#
# change_default_ssh_port.sh - move OpenSSH on Debian 13 (trixie) from port 22 to a new port.
#
# Usage (as root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/msolovjev/vps_helpers/main/change_default_ssh_port.sh)" _ 2222
#   bash change_default_ssh_port.sh 2222
#
#   With `bash -c` the first word after the script becomes $0, hence the "_".
#   The script also accepts the port as $0, "-2222" or "--port=2222".
#
# What it does:
#   1. backs up /etc/ssh/sshd_config and /etc/ssh/sshd_config.d
#   2. disables every existing "Port" line and writes Port <new> to sshd_config.d
#   3. validates the config (sshd -t), opens the port in ufw / firewalld if active,
#      updates fail2ban's sshd jail, handles ssh.socket (socket activation)
#   4. restarts SSH, checks that the new port answers and that port 22 is CLOSED
#   5. asks you to test a NEW connection; without a "yes" within CONFIRM_TIMEOUT
#      seconds (default 300) everything is rolled back to the previous state.
#
# Env: CONFIRM_TIMEOUT=<seconds>   time to confirm the new port before auto-rollback

set -Eeuo pipefail

CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-300}"
SSHD=/usr/sbin/sshd
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DIR=/etc/ssh/sshd_config.d
PORT_CONF="$SSHD_DIR/00-ssh-port.conf"
SOCKET_DROPIN_DIR=/etc/systemd/system/ssh.socket.d
SOCKET_DROPIN="$SOCKET_DROPIN_DIR/zz-ssh-port.conf"
F2B_CONF=/etc/fail2ban/jail.d/zz-sshd-port.local

if [[ -t 1 ]]; then
    R=$'\e[1;31m' G=$'\e[1;32m' Y=$'\e[1;33m' B=$'\e[1m' N=$'\e[0m'
else
    R='' G='' Y='' B='' N=''
fi
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*" >&2; }
die()  { echo "${R}[x]${N} $*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
Usage (as root):
  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/msolovjev/vps_helpers/main/change_default_ssh_port.sh)" _ <port>
  bash change_default_ssh_port.sh <port>
EOF
    exit 1
}

# ---------------------------------------------------------------- arguments
norm() {
    local a="$1"
    a="${a#--port=}"
    while [[ $a == -* ]]; do a="${a#-}"; done
    printf '%s' "$a"
}
PORT="$(norm "${1:-}")"
if [[ -z $PORT ]]; then PORT="$(norm "${0:-}")"; fi   # `bash -c "..." 2222` puts 2222 into $0
[[ $PORT =~ ^[0-9]{1,5}$ ]] || usage
PORT=$((10#$PORT))
(( PORT >= 1 && PORT <= 65535 )) || die "Port must be between 1 and 65535 (got $PORT)."
(( PORT != 22 ))                 || die "Target port is 22 - nothing to do."
(( PORT >= 1024 ))               || warn "Port $PORT is below 1024; ports 1024-65535 are the usual choice."
[[ $CONFIRM_TIMEOUT =~ ^[0-9]+$ ]] || die "CONFIRM_TIMEOUT must be a number of seconds."

# ---------------------------------------------------------------- pre-checks
(( EUID == 0 )) || die "Run as root (e.g. prefix the command with sudo)."
[[ -x $SSHD ]]  || die "$SSHD not found - is openssh-server installed?"
command -v ss >/dev/null        || die "'ss' (iproute2) not found."
command -v systemctl >/dev/null || die "systemd is required."

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian ]] || warn "Written for Debian 13, detected '${PRETTY_NAME:-unknown}'. Continuing."
    [[ ${ID:-} == debian && ${VERSION_ID:-} != 13 ]] && warn "Written for Debian 13, detected '${PRETTY_NAME:-}'. Continuing."
fi

"$SSHD" -t || die "Current sshd configuration is already invalid - fix it first."

listeners() { ss -Htlnp "sport = :$1" 2>/dev/null || true; }
listening() { [[ -n "$(listeners "$1")" ]]; }
sshd_ports() { "$SSHD" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u; }

CUR_PORTS="$(sshd_ports | paste -sd' ')"
info "Current sshd port(s): ${CUR_PORTS:-unknown}"

if [[ $CUR_PORTS == "$PORT" ]] && ! listening 22; then
    info "sshd already uses port $PORT only and port 22 is closed - nothing to do."
    exit 0
fi

if listening "$PORT"; then
    who="$(listeners "$PORT")"
    if ! grep -qE '"(sshd|systemd)"' <<<"$who"; then
        die "Port $PORT is already used by another program:
$who"
    fi
fi

SOCKET_MODE=0
if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    SOCKET_MODE=1
    info "ssh.socket (socket activation) is in use - will update it too."
fi

restart_ssh() {
    systemctl daemon-reload
    if (( SOCKET_MODE )); then
        systemctl restart ssh.socket
    else
        systemctl restart ssh.service
    fi
}

# ---------------------------------------------------------------- backup + rollback
BACKUP="/root/ssh-port-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -a "$SSHD_CONFIG" "$BACKUP/sshd_config"
HAD_DIR=0
if [[ -d $SSHD_DIR ]]; then cp -a "$SSHD_DIR" "$BACKUP/sshd_config.d"; HAD_DIR=1; fi
info "Backup saved to $BACKUP"

CHANGED=0 UFW_ADDED=0 FWD_ADDED=0 F2B_ADDED=0 F2B_BACKUP=0 SOCKET_ADDED=0

rollback() {
    trap - ERR HUP INT TERM
    set +e
    warn "Rolling back to the previous SSH configuration..."
    cp -a "$BACKUP/sshd_config" "$SSHD_CONFIG"
    rm -rf "$SSHD_DIR"
    (( HAD_DIR )) && cp -a "$BACKUP/sshd_config.d" "$SSHD_DIR"
    if (( SOCKET_ADDED )); then
        rm -f "$SOCKET_DROPIN"
        rmdir "$SOCKET_DROPIN_DIR" 2>/dev/null
    fi
    if (( F2B_ADDED )); then
        if (( F2B_BACKUP )); then cp -a "$BACKUP/$(basename "$F2B_CONF")" "$F2B_CONF"; else rm -f "$F2B_CONF"; fi
        systemctl try-reload-or-restart fail2ban.service 2>/dev/null
    fi
    restart_ssh
    (( UFW_ADDED )) && ufw delete allow "$PORT/tcp" >/dev/null
    if (( FWD_ADDED )); then
        firewall-cmd -q --permanent --remove-port="$PORT/tcp"
        firewall-cmd -q --reload
    fi
    sleep 2
    if listening 22; then
        info "Rollback done - SSH listens on port 22 again."
    else
        warn "Rollback done, but nothing listens on port 22 yet. Check: systemctl status ssh ssh.socket"
    fi
}

fail() {
    echo "${R}[x]${N} $*" >&2
    (( CHANGED )) && rollback
    exit 1
}
trap 'fail "Unexpected error on line $LINENO."' ERR
trap 'echo; fail "Interrupted."' HUP INT TERM

# ---------------------------------------------------------------- change sshd config
CHANGED=1

# Disable every active "Port" directive (they add up, so 22 would stay open otherwise).
for f in "$SSHD_CONFIG" "$SSHD_DIR"/*.conf; do
    [[ -f $f ]] || continue
    sed -i -E 's/^([[:space:]]*)(Port([[:space:]]|=).*)$/\1# \2  # disabled by change_default_ssh_port.sh/I' "$f"
done

if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; then
    mkdir -p "$SSHD_DIR"
    printf '# Managed by change_default_ssh_port.sh (%s)\nPort %s\n' "$(date -Is)" "$PORT" >"$PORT_CONF"
    info "Wrote $PORT_CONF"
else
    sed -i "1i # Managed by change_default_ssh_port.sh\nPort $PORT" "$SSHD_CONFIG"
    info "Added 'Port $PORT' to $SSHD_CONFIG"
fi

"$SSHD" -t || fail "New sshd configuration is invalid."

NEW_PORTS="$(sshd_ports | paste -sd' ')"
[[ $NEW_PORTS == "$PORT" ]] || fail "sshd would listen on '$NEW_PORTS' instead of only $PORT."

# ListenAddress lines with an explicit ":port" override Port - make sure none points elsewhere.
while read -r addr; do
    [[ -z $addr ]] && continue
    [[ ${addr##*:} == "$PORT" ]] || fail "A ListenAddress line forces another port ($addr). Edit it and rerun."
done < <("$SSHD" -T 2>/dev/null | awk '$1=="listenaddress"{print $2}')

# ---------------------------------------------------------------- firewall
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$PORT/tcp" comment 'SSH' >/dev/null
    UFW_ADDED=1
    info "ufw: allowed $PORT/tcp"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port="$PORT/tcp"
    firewall-cmd -q --reload
    FWD_ADDED=1
    info "firewalld: allowed $PORT/tcp"
fi
if (( ! UFW_ADDED && ! FWD_ADDED )) && command -v nft >/dev/null \
        && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    warn "Custom nftables input rules found - make sure they allow TCP port $PORT."
fi

# ---------------------------------------------------------------- fail2ban
if [[ -d /etc/fail2ban/jail.d ]]; then
    if [[ -f $F2B_CONF ]]; then cp -a "$F2B_CONF" "$BACKUP/"; F2B_BACKUP=1; fi
    printf '# Managed by change_default_ssh_port.sh\n[sshd]\nport = %s\n' "$PORT" >"$F2B_CONF"
    F2B_ADDED=1
    systemctl try-reload-or-restart fail2ban.service 2>/dev/null || true
    info "fail2ban: sshd jail now watches port $PORT"
fi

# ---------------------------------------------------------------- socket activation
if (( SOCKET_MODE )); then
    mkdir -p "$SOCKET_DROPIN_DIR"
    printf '# Managed by change_default_ssh_port.sh\n[Socket]\nListenStream=\nListenStream=%s\n' "$PORT" >"$SOCKET_DROPIN"
    SOCKET_ADDED=1
    info "Wrote $SOCKET_DROPIN"
fi

# ---------------------------------------------------------------- restart + verify
info "Restarting SSH (your current session stays connected)..."
restart_ssh

for _ in 1 2 3 4 5 6 7 8 9 10; do
    listening "$PORT" && break
    sleep 1
done
listening "$PORT" || fail "Nothing listens on port $PORT after restart."
info "Port $PORT is listening."

banner=""
for host in 127.0.0.1 ::1; do
    banner="$(timeout 5 bash -c "exec 3<>/dev/tcp/$host/$PORT && head -c 7 <&3" 2>/dev/null || true)"
    [[ $banner == SSH-2.0 ]] && break
done
if [[ $banner == SSH-2.0 ]]; then
    info "SSH answers on port $PORT (banner: SSH-2.0)."
else
    warn "Could not read the SSH banner on localhost:$PORT (fine if sshd only listens on a public IP)."
fi

# Port 22 must be closed now.
sleep 1
if listening 22; then
    who22="$(listeners 22)"
    if grep -qE '"(sshd|systemd)"' <<<"$who22"; then
        fail "Port 22 is STILL open by SSH:
$who22"
    fi
    warn "Port 22 is used by a non-SSH program:
$who22"
elif timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null; then
    warn "Something still accepts connections on 127.0.0.1:22 - check it."
else
    info "Port 22 is CLOSED (nothing listens, connection refused)."
fi

# ---------------------------------------------------------------- confirm in a NEW connection
SERVER_IP="$(awk '{print $3}' <<<"${SSH_CONNECTION:-}")"
[[ -n $SERVER_IP ]] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
LOGIN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

cat <<EOF

${R}=====================================================================${N}
${R}  WARNING: DO NOT CLOSE THIS SESSION YET!${N}
${R}=====================================================================${N}
  SSH now listens on port ${B}$PORT${N}; port 22 is closed.

  1. Open a ${B}NEW${N} terminal on your computer and connect:

       ${B}ssh -p $PORT $LOGIN_USER@${SERVER_IP:-<server-ip>}${N}

  2. If your VPS provider has its own firewall / security group in the
     control panel, allow TCP $PORT there first.
  3. Only when the new connection works, come back here and type ${B}yes${N}.

  No "yes" within ${CONFIRM_TIMEOUT}s (or "no", Ctrl+C, lost session)
  => automatic rollback to the previous configuration (port 22).
${R}=====================================================================${N}

EOF

answer=""
if { : </dev/tty; } 2>/dev/null; then
    end=$((SECONDS + CONFIRM_TIMEOUT))
    while :; do
        left=$((end - SECONDS))
        (( left > 0 )) || { answer=""; echo; break; }
        if read -r -t "$left" -p "Type 'yes' to keep port $PORT or 'no' to roll back [${left}s left]: " answer </dev/tty; then
            answer="${answer,,}"
            [[ $answer == yes || $answer == no ]] && break
            echo "Please type yes or no."
        else
            answer=""; echo; break
        fi
    done
else
    warn "No terminal available to confirm - keeping port $PORT. Test it before closing this session!"
    answer="yes"
fi

if [[ $answer != yes ]]; then
    rollback
    exit 1
fi

trap - ERR HUP INT TERM

cat <<EOF

${G}[+] Done. SSH is on port $PORT, port 22 is closed.${N}
    Backup of the old config: $BACKUP
    Connect from now on with:  ssh -p $PORT $LOGIN_USER@${SERVER_IP:-<server-ip>}
    Tip: add to ~/.ssh/config on your computer:
        Host myvps
            HostName ${SERVER_IP:-<server-ip>}
            Port $PORT
    Check from your computer that 22 is closed from outside:  nc -zv ${SERVER_IP:-<server-ip>} 22
EOF
if (( UFW_ADDED )) && ufw status 2>/dev/null | grep -qE '^(22(/tcp)?|OpenSSH)[[:space:]]'; then
    echo "    ufw still has a rule for port 22 (harmless, nothing listens). Remove it with:"
    echo "        ufw delete allow 22/tcp    # or: ufw delete allow OpenSSH"
fi
