#!/bin/bash
# OpenVPN Server Setup for Debian 12
# Port 1100/UDP + pfSense-compatible client config
# Safe to re-run only on a fresh system (will overwrite existing PKI)

set -euo pipefail

# ====================== CONFIG ======================
PORT=1100
PROTO=udp
VPN_SUBNET="10.8.0.0"
VPN_MASK="255.255.255.0"
VPN_CIDR="10.8.0.0/24"
CLIENT_NAME="pfsense-client"
SERVER_NAME="server"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
OPENVPN_DIR="/etc/openvpn/server"
CLIENT_DIR="/root/openvpn-clients"
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== OpenVPN Server Setup (port ${PORT}/${PROTO}) ===${NC}"

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo $0${NC}"
    exit 1
fi

# Detect public IP
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 icanhazip.com || true)
if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${YELLOW}Could not detect public IP automatically.${NC}"
    read -rp "Enter the public IP or hostname clients will connect to: " PUBLIC_IP
fi
echo -e "Using endpoint: ${GREEN}${PUBLIC_IP}${NC}"

# 1. Install packages
echo -e "\n${YELLOW}[1/8] Installing packages...${NC}"
apt update
apt install -y openvpn easy-rsa iptables iptables-persistent curl

# 2. Prepare directories
echo -e "\n${YELLOW}[2/8] Preparing directories...${NC}"
mkdir -p "$OPENVPN_DIR" "$CLIENT_DIR" /var/log/openvpn
rm -rf "$EASYRSA_DIR"
make-cadir "$EASYRSA_DIR"
cd "$EASYRSA_DIR"

# 3. Configure Easy-RSA
echo -e "\n${YELLOW}[3/8] Configuring Easy-RSA...${NC}"
cat > vars <<EOF
set_var EASYRSA_REQ_COUNTRY    "US"
set_var EASYRSA_REQ_PROVINCE   "CA"
set_var EASYRSA_REQ_CITY       "SanFrancisco"
set_var EASYRSA_REQ_ORG        "OpenVPN-Server"
set_var EASYRSA_REQ_EMAIL      "admin@example.com"
set_var EASYRSA_REQ_OU         "IT"
set_var EASYRSA_ALGO           "ec"
set_var EASYRSA_CURVE          "prime256v1"
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    3650
set_var EASYRSA_BATCH          "yes"
EOF

# 4. Build PKI
echo -e "\n${YELLOW}[4/8] Building PKI (this takes a moment)...${NC}"
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa build-server-full "$SERVER_NAME" nopass
./easyrsa build-client-full "$CLIENT_NAME" nopass
./easyrsa gen-crl

# Generate tls-crypt key (preferred over tls-auth)
openvpn --genkey secret "$OPENVPN_DIR/tc.key"

# Copy certificates
cp pki/ca.crt pki/issued/"$SERVER_NAME".crt pki/private/"$SERVER_NAME".key pki/crl.pem "$OPENVPN_DIR/"
cp pki/issued/"$CLIENT_NAME".crt pki/private/"$CLIENT_NAME".key "$CLIENT_DIR/"
chmod 600 "$OPENVPN_DIR"/*.key "$OPENVPN_DIR"/tc.key

# 5. Create server.conf
echo -e "\n${YELLOW}[5/8] Creating server configuration...${NC}"
cat > "$OPENVPN_DIR/server.conf" <<EOF
# OpenVPN Server - Port ${PORT}
port ${PORT}
proto ${PROTO}
dev tun
topology subnet
server ${VPN_SUBNET} ${VPN_MASK}

# Certificates
ca ca.crt
cert ${SERVER_NAME}.crt
key ${SERVER_NAME}.key
dh none                    # ECDH only (modern)
tls-crypt tc.key
crl-verify crl.pem

# Crypto (modern & pfSense friendly)
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA256
tls-version-min 1.2

# Network
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
push "block-outside-dns"
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup

# Logging
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
verb 3
explicit-exit-notify 1
EOF

# 6. Firewall + IP Forwarding
echo -e "\n${YELLOW}[6/8] Configuring firewall and IP forwarding...${NC}"

# Enable forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn-forward.conf

# Basic iptables rules
iptables -t nat -A POSTROUTING -s ${VPN_CIDR} -o $(ip route | grep default | awk '{print $5}' | head -1) -j MASQUERADE
iptables -A INPUT -p ${PROTO} --dport ${PORT} -j ACCEPT
iptables -A FORWARD -i tun+ -j ACCEPT
iptables -A FORWARD -o tun+ -j ACCEPT

# Save rules
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4

# 7. Enable and start service
echo -e "\n${YELLOW}[7/8] Starting OpenVPN service...${NC}"
systemctl enable openvpn-server@server
systemctl restart openvpn-server@server

# Wait a moment and check status
sleep 2
if systemctl is-active --quiet openvpn-server@server; then
    echo -e "${GREEN}OpenVPN server is running!${NC}"
else
    echo -e "${RED}Service failed to start. Check: journalctl -u openvpn-server@server${NC}"
    exit 1
fi

# 8. Generate pfSense-compatible client .ovpn
echo -e "\n${YELLOW}[8/8] Generating client configuration for pfSense...${NC}"

cat > "$CLIENT_DIR/${CLIENT_NAME}.ovpn" <<EOF
# OpenVPN Client Config for pfSense
# Generated for server ${PUBLIC_IP}:${PORT}
client
dev tun
proto ${PROTO}
remote ${PUBLIC_IP} ${PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
tls-client
tls-version-min 1.2
verb 3
explicit-exit-notify

<ca>
$(cat "$OPENVPN_DIR/ca.crt")
</ca>

<cert>
$(cat "$CLIENT_DIR/${CLIENT_NAME}.crt")
</cert>

<key>
$(cat "$CLIENT_DIR/${CLIENT_NAME}.key")
</key>

<tls-crypt>
$(cat "$OPENVPN_DIR/tc.key")
</tls-crypt>
EOF

chmod 600 "$CLIENT_DIR/${CLIENT_NAME}.ovpn"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  OpenVPN Server setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Server listening on: ${GREEN}${PUBLIC_IP}:${PORT}/${PROTO}${NC}"
echo -e "VPN subnet:          ${GREEN}${VPN_CIDR}${NC}"
echo
echo -e "Client config (import this into pfSense):"
echo -e "  ${YELLOW}${CLIENT_DIR}/${CLIENT_NAME}.ovpn${NC}"
echo
echo -e "How to import into pfSense:"
echo -e "  1. Go to VPN → OpenVPN → Clients → Add"
echo -e "  2. Or use 'Import' if available, or paste the contents"
echo -e "  3. Set Server Mode to 'Peer to Peer (SSL/TLS)' or 'Remote Access'"
echo -e "  4. Make sure the interface and firewall rules allow the tunnel"
echo
echo -e "Useful commands:"
echo -e "  systemctl status openvpn-server@server"
echo -e "  journalctl -u openvpn-server@server -f"
echo -e "  tail -f /var/log/openvpn/openvpn.log"
echo
echo -e "${YELLOW}Note: Make sure your cloud firewall / security group allows UDP ${PORT}${NC}"
