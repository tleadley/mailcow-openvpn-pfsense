#!/bin/bash
# Debian 12 – Prepare system for OpenVPN + Disable IPv6
# Safe to re-run

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Debian 12 OpenVPN Prep + Disable IPv6 ===${NC}"

# Must be root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# 1. Update system
echo -e "\n${YELLOW}[1/6] Updating package lists and upgrading...${NC}"
apt update
apt upgrade -y

# 2. Install OpenVPN and related packages
echo -e "\n${YELLOW}[2/6] Installing OpenVPN, Easy-RSA and helpers...${NC}"
apt install -y \
    openvpn \
    easy-rsa \
    iptables \
    iptables-persistent \
    netfilter-persistent \
    curl \
    wget \
    ca-certificates

# Optional: NetworkManager plugins (uncomment if you use a desktop)
# apt install -y network-manager-openvpn network-manager-openvpn-gnome

# 3. Create OpenVPN log directory
echo -e "\n${YELLOW}[3/6] Creating OpenVPN directories...${NC}"
mkdir -p /var/log/openvpn
mkdir -p /etc/openvpn/client
mkdir -p /etc/openvpn/server
chmod 755 /var/log/openvpn

# 4. Disable IPv6 permanently (recommended method)
echo -e "\n${YELLOW}[4/6] Disabling IPv6...${NC}"

cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
# Disable IPv6 completely
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# Apply immediately
sysctl --system

# 5. Enable IP forwarding (required for OpenVPN server)
echo -e "\n${YELLOW}[5/6] Enabling IP forwarding...${NC}"

cat > /etc/sysctl.d/99-ip-forward.conf << 'EOF'
# Enable IP forwarding for OpenVPN
net.ipv4.ip_forward = 1
# Optional: also enable for IPv6 if you ever re-enable it
# net.ipv6.conf.all.forwarding = 1
EOF

sysctl --system

# 6. Final verification
echo -e "\n${YELLOW}[6/6] Verification...${NC}"

echo -e "\nOpenVPN version:"
openvpn --version | head -n1

echo -e "\nIPv6 status (should be 1 = disabled):"
sysctl net.ipv6.conf.all.disable_ipv6
sysctl net.ipv6.conf.default.disable_ipv6

echo -e "\nIP forwarding status (should be 1 = enabled):"
sysctl net.ipv4.ip_forward

echo -e "\n${GREEN}=== Done! ===${NC}"
echo -e "IPv6 is now disabled system-wide."
echo -e "OpenVPN is installed and ready."
echo -e "You can now place your .ovpn client configs in /etc/openvpn/client/"
echo -e "or set up a server in /etc/openvpn/server/"
echo -e "\nRecommended next steps:"
echo -e "  • For a full server setup: use the popular angristan/openvpn-install script"
echo -e "  • Or generate your own PKI with easy-rsa"
echo -e "  • Reboot is optional but recommended after major network changes"
