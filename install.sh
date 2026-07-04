#!/usr/bin/env bash

set -Eeuo pipefail

# 固定稳定版本，不走 latest
VERSION="v3.4.2"

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
        echo -e "${RED}[ERROR] Please run this script as root.${NC}"
        exit 1
    fi
}

random_password() {
    echo "QyZ@$(openssl rand -hex 10)#"
}

random_path() {
    echo "panel-$(openssl rand -hex 5)"
}

get_server_ip() {
    local ip=""
    ip="$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi

    echo "${ip:-YOUR_SERVER_IP}"
}

get_ssh_port() {
    local ssh_port="22"

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ _ ssh_port_from_conn <<< "$SSH_CONNECTION"
        if [[ "$ssh_port_from_conn" =~ ^[0-9]+$ ]]; then
            ssh_port="$ssh_port_from_conn"
        fi
    fi

    echo "$ssh_port"
}

is_port_in_use() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}'
        return
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
        return
    fi

    return 1
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect operating system."
    fi

    . /etc/os-release
    OS_ID="${ID}"

    case "$OS_ID" in
        ubuntu|debian)
            PKG_UPDATE=(apt-get update -y)
            PKG_INSTALL=(apt-get install -y)
            BASE_PACKAGES=(curl wget socat tar jq ca-certificates unzip lsof openssl iproute2 cron)
            FIREWALL_TYPE="ufw"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                PKG_UPDATE=(dnf makecache -y)
                PKG_INSTALL=(dnf install -y)
            else
                PKG_UPDATE=(yum makecache -y)
                PKG_INSTALL=(yum install -y)
            fi
            BASE_PACKAGES=(curl wget socat tar jq ca-certificates unzip lsof openssl iproute cronie)
            FIREWALL_TYPE="firewalld"
            ;;
        *)
            error "Unsupported system: $OS_ID"
            ;;
    esac

    SSH_PORT="$(get_ssh_port)"

    log "Detected system: $OS_ID"
    log "Detected SSH port: $SSH_PORT"
}

install_dependencies() {
    log "Installing basic dependencies..."

    if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
    fi

    "${PKG_UPDATE[@]}"
    "${PKG_INSTALL[@]}" "${BASE_PACKAGES[@]}"

    log "Dependencies installed."
}

enable_bbr_and_network_tuning() {
    log "Applying high-speed and low-latency network tuning..."

    cat > /etc/sysctl.d/99-secure-server-panel-network.conf <<EOF
# BBR acceleration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Connection queue optimization
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=65535

# TCP optimization
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# Port range
net.ipv4.ip_local_port_range=1024 65535

# Reuse TIME_WAIT sockets
net.ipv4.tcp_tw_reuse=1

# Basic network security hardening
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
        "${PKG_INSTALL[@]}" ufw

        ufw allow "${SSH_PORT}/tcp" || true
        ufw allow 22/tcp || true

        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable

        log "UFW firewall enabled."
        log "SSH port allowed: ${SSH_PORT}"

    elif [[ "$FIREWALL_TYPE" == "firewalld" ]]; then
        "${PKG_INSTALL[@]}" firewalld

        systemctl enable firewalld
        systemctl start firewalld

        firewall-cmd --permanent --add-service=ssh || true
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" || true
        firewall-cmd --reload || true

        log "firewalld enabled."
        log "SSH port allowed: ${SSH_PORT}"
    fi
}

setup_fail2ban() {
    log "Installing fail2ban SSH brute-force protection..."

    if ! "${PKG_INSTALL[@]}" fail2ban; then
        warn "fail2ban install failed, trying EPEL repository..."

        if [[ "$FIREWALL_TYPE" == "firewalld" ]]; then
            "${PKG_INSTALL[@]}" epel-release || true
            "${PKG_UPDATE[@]}" || true
            "${PKG_INSTALL[@]}" fail2ban || {
                warn "fail2ban installation failed. Skipping fail2ban."
                return 0
            }
        else
            warn "fail2ban installation failed. Skipping fail2ban."
            return 0
        fi
    fi

    mkdir -p /etc/fail2ban/jail.d

    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable fail2ban || true
    systemctl restart fail2ban || true

    log "fail2ban enabled."
}

save_install_info_base() {
    SERVER_IP="$(get_server_ip)"

    cat > "$INFO_FILE" <<EOF
Secure Server Panel Installer

Server IP:
${SERVER_IP}

Panel Core:
3x-ui

Fixed Version:
${VERSION}

Enabled Features:
- BBR network acceleration
- TCP low-latency tuning
- High connection limit optimization
- Basic firewall protection
- Fail2ban SSH protection
- Fixed stable 3x-ui installation
- Custom panel port
- Custom panel username
- Custom panel password
- Random secure panel access path

Useful Commands:
x-ui

Installation Log:
${LOG_FILE}

EOF

    chmod 600 "$INFO_FILE"

    log "Base installation information saved to: $INFO_FILE"
}

install_xui_panel() {
    log "Installing fixed stable 3x-ui server panel..."
    warn "Panel version: $VERSION"

    echo
    echo "======================================================"
    echo "Panel Security Setup"
    echo "======================================================"

    read -rp "请设置面板端口 [默认: 31876，建议 20000-60000]: " PANEL_PORT
    PANEL_PORT="${PANEL_PORT:-31876}"

    if ! [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || [[ "$PANEL_PORT" -lt 20000 ]] || [[ "$PANEL_PORT" -gt 60000 ]]; then
        error "Invalid panel port. Please use a port between 20000 and 60000."
    fi

    if is_port_in_use "$PANEL_PORT"; then
        error "Port ${PANEL_PORT} is already in use. Please choose another port."
    fi

    read -rp "请设置面板账号 [默认: qyonzpanel]: " PANEL_USER
    PANEL_USER="${PANEL_USER:-qyonzpanel}"

    if ! [[ "$PANEL_USER" =~ ^[A-Za-z0-9_.@-]{3,64}$ ]]; then
        error "Invalid username. Use 3-64 characters: letters, numbers, dot, underscore, @ or hyphen."
    fi

    read -rsp "请设置面板密码 [留空则自动生成强密码]: " PANEL_PASS
    echo

    if [[ -z "$PANEL_PASS" ]]; then
        PANEL_PASS="$(random_password)"
        warn "Random password generated: $PANEL_PASS"
    fi

    if [[ "${#PANEL_PASS}" -lt 8 ]]; then
        error "Password is too short. Please use at least 8 characters."
    fi

    PANEL_PATH="$(random_path)"
    SERVER_IP="$(get_server_ip)"

    echo
    echo "======================================================"
    echo "Your Panel Settings"
    echo "======================================================"
    echo "Panel Version: $VERSION"
    echo "Panel Port: $PANEL_PORT"
    echo "Panel Username: $PANEL_USER"
    echo "Panel Password: $PANEL_PASS"
    echo "Panel Access Path: $PANEL_PATH"
    echo "Panel URL: http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}"
    echo "======================================================"
    echo

    log "Starting 3x-ui installation..."

    XUI_NONINTERACTIVE=1 \
    XUI_USERNAME="$PANEL_USER" \
    XUI_PASSWORD="$PANEL_PASS" \
    XUI_PANEL_PORT="$PANEL_PORT" \
    XUI_WEB_BASE_PATH="$PANEL_PATH" \
    XUI_DB_TYPE="sqlite" \
    XUI_SSL_MODE="none" \
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) "$VERSION"

    log "3x-ui installation command completed."

    log "Forcing panel settings..."

    if [[ -x /usr/local/x-ui/x-ui ]]; then
        /usr/local/x-ui/x-ui setting \
            -username "$PANEL_USER" \
            -password "$PANEL_PASS" \
            -port "$PANEL_PORT" \
            -webBasePath "$PANEL_PATH" || warn "Could not force panel settings, please check with x-ui command."

        systemctl enable x-ui || true
        systemctl restart x-ui || true
    else
        warn "/usr/local/x-ui/x-ui not found. Please check installation manually."
    fi

    log "Opening panel port in firewall: $PANEL_PORT"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${PANEL_PORT}/tcp" || true
        ufw reload || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" || true
        firewall-cmd --reload || true
    fi

    cat >> "$INFO_FILE" <<EOF

3x-ui Panel Login Info

Panel Version:
${VERSION}

Panel URL:
http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}

Panel Port:
${PANEL_PORT}

Panel Username:
${PANEL_USER}

Panel Password:
${PANEL_PASS}

Panel Access Path:
${PANEL_PATH}

Important:
If the panel cannot be opened, please also check your cloud provider firewall/security group and allow TCP port ${PANEL_PORT}.

EOF

    chmod 600 "$INFO_FILE"

    echo
    echo "======================================================"
    echo "3x-ui Panel Installation Completed"
    echo "======================================================"
    echo "Panel URL: http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}"
    echo "Username: ${PANEL_USER}"
    echo "Password: ${PANEL_PASS}"
    echo "Port: ${PANEL_PORT}"
    echo "Info file: ${INFO_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo "======================================================"
    echo
}

show_result() {
    SERVER_IP="$(get_server_ip)"

    echo
    echo "======================================================"
    echo -e "${GREEN}Installation completed.${NC}"
    echo "======================================================"
    echo "Server IP: ${SERVER_IP}"
    echo "Panel URL: http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}"
    echo "Username: ${PANEL_USER}"
    echo "Password: ${PANEL_PASS}"
    echo "Panel Port: ${PANEL_PORT}"
    echo
    echo "Useful command:"
    echo "x-ui"
    echo
    echo "Info file:"
    echo "${INFO_FILE}"
    echo
    echo "Log file:"
    echo "${LOG_FILE}"
    echo "======================================================"
    echo
}

main() {
    check_root
    touch "$LOG_FILE"

    detect_os
    install_dependencies
    enable_bbr_and_network_tuning
    optimize_system_limits
    setup_firewall_basic
    setup_fail2ban
    save_install_info_base
    install_xui_panel
    show_result
}

main "$@"
