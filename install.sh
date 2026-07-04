#!/usr/bin/env bash

set -Eeuo pipefail

VERSION="${1:-latest}"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m"

APP_NAME="secure-server-panel"
LOG_FILE="/var/log/${APP_NAME}-install.log"
INFO_FILE="/root/${APP_NAME}-info.txt"

log() {
    echo -e "${GREEN}[OK] $1${NC}" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Please run this script as root."
    fi
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect operating system."
    fi

    . /etc/os-release
    OS_ID="${ID}"

    case "$OS_ID" in
        ubuntu|debian)
            PKG_UPDATE="apt update -y"
            PKG_INSTALL="apt install -y"
            FIREWALL_TYPE="ufw"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_UPDATE="yum update -y"
            PKG_INSTALL="yum install -y"
            FIREWALL_TYPE="firewalld"
            ;;
        *)
            error "Unsupported system: $OS_ID"
            ;;
    esac

    log "Detected system: $OS_ID"
}

install_dependencies() {
    log "Installing basic dependencies..."

    $PKG_UPDATE
    $PKG_INSTALL curl wget socat tar jq ca-certificates unzip lsof

    log "Dependencies installed."
}

enable_bbr_and_network_tuning() {
    log "Applying high-speed and low-latency network tuning..."

    cat > /etc/sysctl.d/99-secure-server-panel-network.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=65535

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
EOF

    sysctl --system >/dev/null 2>&1 || true

    CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    CURRENT_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"

    log "Current TCP congestion control: $CURRENT_CC"
    log "Current queue discipline: $CURRENT_QDISC"
}

optimize_system_limits() {
    log "Optimizing system connection limits..."

    cat > /etc/security/limits.d/99-secure-server-panel.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF

    if [[ -f /etc/systemd/system.conf ]]; then
        sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
        sed -i '/DefaultLimitNPROC/d' /etc/systemd/system.conf

        cat >> /etc/systemd/system.conf <<EOF
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

        systemctl daemon-reexec || true
    fi

    log "System limits optimized."
}

setup_firewall_basic() {
    log "Setting up firewall basic protection..."

    if [[ "$FIREWALL_TYPE" == "ufw" ]]; then
        $PKG_INSTALL ufw

        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp
        ufw --force enable

        log "UFW firewall enabled. SSH port 22 is allowed."

    elif [[ "$FIREWALL_TYPE" == "firewalld" ]]; then
        $PKG_INSTALL firewalld

        systemctl enable firewalld
        systemctl start firewalld

        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --reload

        log "firewalld enabled. SSH service is allowed."
    fi
}

setup_fail2ban() {
    log "Installing fail2ban SSH brute-force protection..."

    $PKG_INSTALL fail2ban

    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    log "fail2ban enabled."
}

install_xui_panel() {
    log "Installing x-ui server panel..."
    warn "Panel version: $VERSION"

    if [[ "$VERSION" == "latest" ]]; then
        bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/956bf85bbac978d56c0e319c5fac2d6db7df9564/install.sh)
    else
        bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/956bf85bbac978d56c0e319c5fac2d6db7df9564/install.sh) "$VERSION"
    fi

    log "x-ui installation command completed."
}

save_install_info() {
    SERVER_IP="$(curl -s4 https://api.ipify.org || echo "YOUR_SERVER_IP")"

    cat > "$INFO_FILE" <<EOF
Secure Server Panel Installer

Server IP:
${SERVER_IP}

x-ui Version:
${VERSION}

Enabled Features:
- BBR network acceleration
- TCP low-latency tuning
- High connection limit optimization
- Firewall basic protection
- Fail2ban SSH protection
- x-ui panel installation

Useful Commands:
x-ui

Installation Log:
${LOG_FILE}

Important:
Please run "x-ui" after installation to check or modify:
- panel port
- username
- password
- SSL settings
- inbound protocol settings

EOF

    chmod 600 "$INFO_FILE"

    log "Installation information saved to: $INFO_FILE"
}

show_result() {
    SERVER_IP="$(curl -s4 https://api.ipify.org || echo "YOUR_SERVER_IP")"

    echo
    echo "======================================================"
    echo -e "${GREEN}Installation completed.${NC}"
    echo "======================================================"
    echo "Server IP: ${SERVER_IP}"
    echo "x-ui command: x-ui"
    echo "Info file: ${INFO_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo
    echo "Next step:"
    echo "Run this command to manage your panel:"
    echo "x-ui"
    echo "======================================================"
    echo
}

main() {
    touch "$LOG_FILE"

    check_root
    detect_os
    install_dependencies
    enable_bbr_and_network_tuning
    optimize_system_limits
    setup_firewall_basic
    setup_fail2ban
    install_xui_panel
    save_install_info
    show_result
}

main "$@"
