#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VPS Manager Installer
# OpenVPN TCP 443 + UDP 1194
# Certificate + Linux PAM username/password authentication
# NAT + BBR + VPN-only Squid
# ============================================================

export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR="/opt/vps-manager"
CLIENT_DIR="$INSTALL_DIR/clients"
OPENVPN_DIR="/etc/openvpn/server"
EASYRSA_DIR="/etc/openvpn/easy-rsa"

VPN_GROUP="vpsvpn"

TCP_PORT="443"
UDP_PORT="1194"

TCP_NET="10.8.0.0/24"
UDP_NET="10.9.0.0/24"

LOG_FILE="/var/log/vps-manager-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "============================================================"
echo " VPS Manager Installer"
echo " OpenVPN TCP : $TCP_PORT"
echo " OpenVPN UDP : $UDP_PORT"
echo "============================================================"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run this script as root."
    echo
    echo "Example:"
    echo "sudo bash install.sh"
    exit 1
fi

# ------------------------------------------------------------
# OS check
# ------------------------------------------------------------

if [ ! -f /etc/os-release ]; then
    echo "[ERROR] Cannot detect operating system."
    exit 1
fi

. /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        echo "[ERROR] Supported OS: Ubuntu/Debian"
        echo "[INFO] Detected: ${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac

echo "[+] OS: ${PRETTY_NAME:-unknown}"

# ------------------------------------------------------------
# Package installation
# ------------------------------------------------------------

echo
echo "[+] Updating package lists..."

apt-get update

echo
echo "[+] Installing packages..."

apt-get install -y \
    ca-certificates \
    curl \
    openssl \
    iproute2 \
    iptables \
    iptables-persistent \
    openvpn \
    easy-rsa \
    squid \
    procps \
    passwd \
    util-linux \
    systemd

# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------

mkdir -p "$INSTALL_DIR"
mkdir -p "$CLIENT_DIR"
mkdir -p "$OPENVPN_DIR"

chmod 700 "$INSTALL_DIR"
chmod 700 "$CLIENT_DIR"
chmod 700 "$OPENVPN_DIR"

# ------------------------------------------------------------
# Stop old OpenVPN configs/services if present
# ------------------------------------------------------------

echo
echo "[+] Checking old OpenVPN services..."

systemctl disable --now openvpn-server@server.service 2>/dev/null || true
systemctl disable --now openvpn@server.service 2>/dev/null || true
systemctl disable --now openvpn@server2.service 2>/dev/null || true

# ------------------------------------------------------------
# VPN Linux group
# ------------------------------------------------------------

echo
echo "[+] Creating VPN user group..."

if ! getent group "$VPN_GROUP" >/dev/null 2>&1; then
    groupadd --system "$VPN_GROUP"
fi

# ------------------------------------------------------------
# PAM configuration
# ------------------------------------------------------------

echo
echo "[+] Configuring PAM authentication..."

cat > /etc/pam.d/openvpn <<'EOF'
auth required pam_unix.so
account required pam_unix.so
EOF

chmod 644 /etc/pam.d/openvpn

# ------------------------------------------------------------
# Find OpenVPN PAM plugin
# ------------------------------------------------------------

echo
echo "[+] Locating OpenVPN PAM plugin..."

PAM_PLUGIN=""

for p in \
    /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
    /usr/lib/aarch64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
    /usr/lib/arm-linux-gnueabihf/openvpn/plugins/openvpn-plugin-auth-pam.so \
    /usr/lib/openvpn/openvpn-plugin-auth-pam.so
do
    if [ -f "$p" ]; then
        PAM_PLUGIN="$p"
        break
    fi
done

if [ -z "$PAM_PLUGIN" ]; then
    PAM_PLUGIN="$(find /usr/lib /lib \
        -type f \
        -name 'openvpn-plugin-auth-pam.so' \
        -print -quit 2>/dev/null || true)"
fi

if [ -z "$PAM_PLUGIN" ]; then
    echo "[ERROR] OpenVPN PAM plugin was not found."
    echo "[INFO] Check your OpenVPN package."
    exit 1
fi

echo "[+] PAM plugin:"
echo "    $PAM_PLUGIN"

# ------------------------------------------------------------
# Easy-RSA
# ------------------------------------------------------------

echo
echo "[+] Preparing Easy-RSA..."

if [ ! -f "$EASYRSA_DIR/pki/ca.crt" ]; then

    rm -rf "$EASYRSA_DIR"
    mkdir -p "$EASYRSA_DIR"

    cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"

    cd "$EASYRSA_DIR"

    ./easyrsa init-pki

    EASYRSA_BATCH=1 \
    EASYRSA_REQ_CN="VPS-Manager-CA" \
    ./easyrsa build-ca nopass

    EASYRSA_BATCH=1 \
    ./easyrsa gen-req server nopass

    EASYRSA_BATCH=1 \
    ./easyrsa sign-req server server

    EASYRSA_BATCH=1 \
    ./easyrsa gen-dh

    EASYRSA_BATCH=1 \
    ./easyrsa gen-req client1 nopass

    EASYRSA_BATCH=1 \
    ./easyrsa sign-req client client1

else
    echo "[+] Existing PKI found. Keeping existing certificates."
fi

# ------------------------------------------------------------
# Copy certificates
# ------------------------------------------------------------

echo
echo "[+] Installing OpenVPN certificates..."

cp "$EASYRSA_DIR/pki/ca.crt" \
   "$OPENVPN_DIR/ca.crt"

cp "$EASYRSA_DIR/pki/issued/server.crt" \
   "$OPENVPN_DIR/server.crt"

cp "$EASYRSA_DIR/pki/private/server.key" \
   "$OPENVPN_DIR/server.key"

# DH may exist depending on Easy-RSA/OpenSSL version.
if [ -f "$EASYRSA_DIR/pki/dh.pem" ]; then
    cp "$EASYRSA_DIR/pki/dh.pem" \
       "$OPENVPN_DIR/dh.pem"
fi

# ------------------------------------------------------------
# tls-crypt
# ------------------------------------------------------------

if [ ! -f "$OPENVPN_DIR/ta.key" ]; then
    echo
    echo "[+] Generating tls-crypt key..."

    openvpn --genkey secret "$OPENVPN_DIR/ta.key"
fi

chmod 600 \
    "$OPENVPN_DIR/server.key" \
    "$OPENVPN_DIR/ta.key"

chmod 644 \
    "$OPENVPN_DIR/ca.crt" \
    "$OPENVPN_DIR/server.crt"

# ------------------------------------------------------------
# Detect network interface
# ------------------------------------------------------------

echo
echo "[+] Detecting network interface..."

DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"

if [ -z "$DEFAULT_IFACE" ]; then
    echo "[ERROR] Could not detect default network interface."
    exit 1
fi

echo "[+] Network interface: $DEFAULT_IFACE"

# ------------------------------------------------------------
# Detect public IP
# ------------------------------------------------------------

echo
echo "[+] Detecting VPS public IPv4..."

SERVER_IP=""

SERVER_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(ip -4 addr show "$DEFAULT_IFACE" \
        | awk '/inet / {print $2}' \
        | cut -d/ -f1 \
        | head -n1)"
fi

if [ -z "$SERVER_IP" ]; then
    echo "[ERROR] Could not determine server IPv4."
    exit 1
fi

echo "[+] Server IP: $SERVER_IP"

# ------------------------------------------------------------
# TCP OpenVPN config
# ------------------------------------------------------------

echo
echo "[+] Creating TCP OpenVPN configuration..."

cat > "$OPENVPN_DIR/server-tcp.conf" <<EOF
port $TCP_PORT
proto tcp-server

dev tun-tcp
topology subnet

server 10.8.0.0 255.255.255.0

ca $OPENVPN_DIR/ca.crt
cert $OPENVPN_DIR/server.crt
key $OPENVPN_DIR/server.key

tls-crypt $OPENVPN_DIR/ta.key

verify-client-cert require

plugin $PAM_PLUGIN openvpn
username-as-common-name

keepalive 10 120

persist-key
persist-tun

user nobody
group nogroup

push "redirect-gateway def1"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

auth-nocache

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM

tls-version-min 1.2

status /var/log/openvpn-server-tcp-status.log

verb 3
EOF

# ------------------------------------------------------------
# UDP OpenVPN config
# ------------------------------------------------------------

echo
echo "[+] Creating UDP OpenVPN configuration..."

cat > "$OPENVPN_DIR/server-udp.conf" <<EOF
port $UDP_PORT
proto udp

dev tun-udp
topology subnet

server 10.9.0.0 255.255.255.0

ca $OPENVPN_DIR/ca.crt
cert $OPENVPN_DIR/server.crt
key $OPENVPN_DIR/server.key

tls-crypt $OPENVPN_DIR/ta.key

verify-client-cert require

plugin $PAM_PLUGIN openvpn
username-as-common-name

keepalive 10 120

persist-key
persist-tun

user nobody
group nogroup

push "redirect-gateway def1"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

auth-nocache

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM

tls-version-min 1.2

explicit-exit-notify 1

status /var/log/openvpn-server-udp-status.log

verb 3
EOF

chmod 644 \
    "$OPENVPN_DIR/server-tcp.conf" \
    "$OPENVPN_DIR/server-udp.conf"

# ------------------------------------------------------------
# Client certificate files
# ------------------------------------------------------------

CLIENT_CA="$EASYRSA_DIR/pki/ca.crt"
CLIENT_CERT="$EASYRSA_DIR/pki/issued/client1.crt"
CLIENT_KEY="$EASYRSA_DIR/pki/private/client1.key"
TA_KEY="$OPENVPN_DIR/ta.key"

if [ ! -f "$CLIENT_CERT" ] || [ ! -f "$CLIENT_KEY" ]; then
    echo "[ERROR] Client certificate files are missing."
    exit 1
fi

# ------------------------------------------------------------
# Generate TCP client profile
# ------------------------------------------------------------

echo
echo "[+] Creating TCP client profile..."

{
    echo "client"
    echo "dev tun"
    echo "proto tcp-client"
    echo
    echo "remote $SERVER_IP $TCP_PORT"
    echo
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo
    echo "remote-cert-tls server"
    echo
    echo "auth-user-pass"
    echo "auth-retry interact"
    echo "auth-nocache"
    echo
    echo "tls-version-min 1.2"
    echo "tls-crypt ta.key"
    echo
    echo "data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"
    echo "data-ciphers-fallback AES-256-GCM"
    echo
    echo "verb 3"
    echo
    echo "<ca>"
    cat "$CLIENT_CA"
    echo "</ca>"
    echo
    echo "<cert>"
    cat "$CLIENT_CERT"
    echo "</cert>"
    echo
    echo "<key>"
    cat "$CLIENT_KEY"
    echo "</key>"
    echo
    echo "<tls-crypt>"
    cat "$TA_KEY"
    echo "</tls-crypt>"
} > "$CLIENT_DIR/client1-tcp.ovpn"

# ------------------------------------------------------------
# Generate UDP client profile
# ------------------------------------------------------------

echo
echo "[+] Creating UDP client profile..."

{
    echo "client"
    echo "dev tun"
    echo "proto udp"
    echo
    echo "remote $SERVER_IP $UDP_PORT"
    echo
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo
    echo "remote-cert-tls server"
    echo
    echo "auth-user-pass"
    echo "auth-retry interact"
    echo "auth-nocache"
    echo
    echo "tls-version-min 1.2"
    echo "tls-crypt ta.key"
    echo
    echo "data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305"
    echo "data-ciphers-fallback AES-256-GCM"
    echo
    echo "verb 3"
    echo
    echo "<ca>"
    cat "$CLIENT_CA"
    echo "</ca>"
    echo
    echo "<cert>"
    cat "$CLIENT_CERT"
    echo "</cert>"
    echo
    echo "<key>"
    cat "$CLIENT_KEY"
    echo "</key>"
    echo
    echo "<tls-crypt>"
    cat "$TA_KEY"
    echo "</tls-crypt>"
} > "$CLIENT_DIR/client1-udp.ovpn"

chmod 600 \
    "$CLIENT_DIR/client1-tcp.ovpn" \
    "$CLIENT_DIR/client1-udp.ovpn"

# ------------------------------------------------------------
# IPv4 forwarding
# ------------------------------------------------------------

echo
echo "[+] Enabling IPv4 forwarding..."

cat > /etc/sysctl.d/99-vps-manager.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

sysctl -p /etc/sysctl.d/99-vps-manager.conf >/dev/null 2>&1 || true

# ------------------------------------------------------------
# BBR
# ------------------------------------------------------------

echo
echo "[+] Configuring BBR..."

cat > /etc/sysctl.d/99-vps-manager-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p /etc/sysctl.d/99-vps-manager-bbr.conf >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Firewall/NAT
# ------------------------------------------------------------

echo
echo "[+] Configuring NAT..."

cat > /usr/local/sbin/vps-manager-firewall <<EOF
#!/usr/bin/env bash
set -e

IFACE="$DEFAULT_IFACE"

iptables -C INPUT -p tcp --dport $TCP_PORT -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p tcp --dport $TCP_PORT -j ACCEPT

iptables -C INPUT -p udp --dport $UDP_PORT -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p udp --dport $UDP_PORT -j ACCEPT

iptables -C FORWARD -s 10.8.0.0/24 -o "\$IFACE" -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -s 10.8.0.0/24 -o "\$IFACE" -j ACCEPT

iptables -C FORWARD -s 10.9.0.0/24 -o "\$IFACE" -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -s 10.9.0.0/24 -o "\$IFACE" -j ACCEPT

iptables -C FORWARD -d 10.8.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -d 10.8.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -C FORWARD -d 10.9.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -d 10.9.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "\$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "\$IFACE" -j MASQUERADE

iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o "\$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "\$IFACE" -j MASQUERADE
EOF

chmod 700 /usr/local/sbin/vps-manager-firewall

/usr/local/sbin/vps-manager-firewall

# ------------------------------------------------------------
# Persistent firewall service
# ------------------------------------------------------------

cat > /etc/systemd/system/vps-manager-firewall.service <<'EOF'
[Unit]
Description=VPS Manager Firewall Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-manager-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vps-manager-firewall.service

# ------------------------------------------------------------
# Squid
# ------------------------------------------------------------

echo
echo "[+] Configuring VPN-only Squid..."

cp /etc/squid/squid.conf \
   /etc/squid/squid.conf.vps-manager-backup 2>/dev/null || true

cat > /etc/squid/squid.conf <<'EOF'
acl localhost src 127.0.0.1/32
acl vpn src 10.8.0.0/24
acl vpn src 10.9.0.0/24

http_port 8080

http_access allow localhost
http_access allow vpn
http_access deny all

cache deny all

via off
forwarded_for delete
request_header_access Via deny all
request_header_access X-Forwarded-For deny all
EOF

systemctl enable squid
systemctl restart squid

# ------------------------------------------------------------
# OpenVPN services
# ------------------------------------------------------------

echo
echo "[+] Starting OpenVPN TCP..."

systemctl daemon-reload

systemctl enable --now openvpn-server@server-tcp.service

echo
echo "[+] Starting OpenVPN UDP..."

systemctl enable --now openvpn-server@server-udp.service

# ------------------------------------------------------------
# Installation information
# ------------------------------------------------------------

cat > "$INSTALL_DIR/info.txt" <<EOF
VPS Manager
===========

Server IP:
$SERVER_IP

OpenVPN TCP:
$SERVER_IP:$TCP_PORT

OpenVPN UDP:
$SERVER_IP:$UDP_PORT

TCP Profile:
$CLIENT_DIR/client1-tcp.ovpn

UDP Profile:
$CLIENT_DIR/client1-udp.ovpn

VPN User Group:
$VPN_GROUP

Squid:
$SERVER_IP:8080

TCP Network:
$TCP_NET

UDP Network:
$UDP_NET

Installed:
$(date)
EOF

# ------------------------------------------------------------
# Marker
# ------------------------------------------------------------

cat > "$INSTALL_DIR/.installed" <<EOF
installed=$(date -Is)
server_ip=$SERVER_IP
tcp_port=$TCP_PORT
udp_port=$UDP_PORT
EOF

chmod 600 "$INSTALL_DIR/info.txt"
chmod 600 "$INSTALL_DIR/.installed"

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------

echo
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "Server IP : $SERVER_IP"
echo
echo "OpenVPN TCP : $SERVER_IP:$TCP_PORT"
echo "OpenVPN UDP : $SERVER_IP:$UDP_PORT"
echo "Squid       : $SERVER_IP:8080"
echo

echo "TCP OVPN:"
echo "$CLIENT_DIR/client1-tcp.ovpn"
echo

echo "UDP OVPN:"
echo "$CLIENT_DIR/client1-udp.ovpn"
echo

echo "VPN users are Linux users in group:"
echo "$VPN_GROUP"
echo

echo "Create VPN user:"
echo "  useradd -M -g $VPN_GROUP -s /usr/sbin/nologin USERNAME"
echo "  passwd USERNAME"
echo

echo "Service status:"
systemctl --no-pager --full status openvpn-server@server-tcp.service \
    | tail -n 8 || true

echo

systemctl --no-pager --full status openvpn-server@server-udp.service \
    | tail -n 8 || true

echo
echo "============================================================"
echo " Done."
echo "============================================================"
